from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import re
import struct
import subprocess
import threading
import time
import socket
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent
CONFIG = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
LOCK = threading.RLock()
MSL_START_LOCK = threading.Lock()
HEARTBEATS = {}
STARTING = {}
LAST_ERRORS = {}
START_TIMEOUT = int(CONFIG.get("start_timeout_seconds", 300))
IDLE_SECONDS = int(CONFIG.get("idle_seconds", 180))
MSL = CONFIG.get("msl", {})
HELPER = (ROOT.parent / "tools" / "start-msl-ui-instance.ps1").resolve()
EMPTY_SINCE = {}


def service(name):
    value = CONFIG["servers"].get(name)
    if not value:
        raise KeyError(name)
    return value


def state(name):
    with LOCK:
        cfg = service(name)
        heartbeat = HEARTBEATS.get(name, {})
        launch = STARTING.get(name)
        if launch and launch.get("done"):
            if port_open(cfg["port"]):
                if heartbeat.get("ready"):
                    STARTING.pop(name, None)
                    LAST_ERRORS.pop(name, None)
                    return {"service": name, "state": "ONLINE", "players": heartbeat.get("players", 0)}
                if heartbeat:
                    return {"service": name, "state": "STARTING", "players": heartbeat.get("players", 0)}
                STARTING.pop(name, None)
                return {"service": name, "state": "ONLINE", "players": 0}
            STARTING.pop(name, None)
            launch = None
        elif launch and not launch["thread"].is_alive() and time.monotonic() - launch["since"] > START_TIMEOUT:
            STARTING.pop(name, None)
            launch = None
        online = bool(heartbeat.get("ready"))
        if port_open(cfg["port"]):
            if online:
                STARTING.pop(name, None)
                LAST_ERRORS.pop(name, None)
                return {"service": name, "state": "ONLINE", "players": heartbeat.get("players", 0)}
            if launch or heartbeat:
                return {"service": name, "state": "STARTING", "players": heartbeat.get("players", 0)}
            return {"service": name, "state": "ONLINE", "players": 0}
        if launch:
            return {"service": name, "state": "STARTING", "players": 0}
        HEARTBEATS.pop(name, None)
        result = {"service": name, "state": "OFFLINE", "players": 0}
        if name in LAST_ERRORS:
            result["error"] = LAST_ERRORS[name]
        return result


def port_open(port):
    with socket.socket() as sock:
        sock.settimeout(0.2)
        return sock.connect_ex(("127.0.0.1", int(port))) == 0


def rcon_read_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("RCON connection closed")
        data += chunk
    return data


def rcon_packet(packet_id, packet_type, body=b""):
    return (struct.pack("<ii", len(body) + 10, packet_id)
            + struct.pack("<i", packet_type) + body + b"\x00\x00")


def rcon_command(name, command):
    cfg = service(name)
    rcon = cfg.get("rcon")
    if not rcon:
        raise ValueError(f"service {name} has no rcon config")
    with socket.create_connection((rcon.get("host", "127.0.0.1"), int(rcon["port"])), timeout=3) as sock:
        sock.settimeout(5)
        sock.sendall(rcon_packet(1, 3, rcon["password"].encode("utf-8")))
        length, packet_id, packet_type = struct.unpack("<iii", rcon_read_exact(sock, 12))
        if length < 10 or packet_id != 1 or packet_type != 2:
            raise RuntimeError(f"RCON login failed (id={packet_id} type={packet_type})")
        rcon_read_exact(sock, length - 8)
        sock.sendall(rcon_packet(2, 2, command.encode("utf-8")))
        output = []
        while True:
            length, packet_id, packet_type = struct.unpack("<iii", rcon_read_exact(sock, 12))
            body = rcon_read_exact(sock, length - 8).rstrip(b"\x00")
            if packet_id == 2 and body:
                output.append(body.decode("utf-8", errors="replace"))
            if packet_id == 2 and packet_type == 0:
                break
        return "\n".join(output)


def rcon_players(name):
    text = rcon_command(name, "list")
    match = re.search(r"(\d+)\s*/\s*\d+", text)
    if match:
        return int(match.group(1))
    # 老核心 list 输出中英文差异大，例如：当前有 0 位玩家在线 / 当前有§c0§6位玩家在线 / There are 0 of a max of 20
    match = re.search(r"(?:当前有|当前在线|在线玩家|There are)\D*?(\d+)", text, re.IGNORECASE)
    return int(match.group(1)) if match else -1


def rcon_idle_loop():
    while True:
        time.sleep(5)
        stop_now = []
        with LOCK:
            for name, cfg in list(CONFIG["servers"].items()):
                if not cfg.get("rcon") or HEARTBEATS.get(name):
                    EMPTY_SINCE.pop(name, None)
                    continue
                current = state(name)
                if current["state"] != "ONLINE":
                    EMPTY_SINCE.pop(name, None)
                    continue
                try:
                    players = rcon_players(name)
                except Exception:
                    EMPTY_SINCE.pop(name, None)
                    continue
                if players > 0:
                    EMPTY_SINCE.pop(name, None)
                    continue
                if players < 0:
                    continue
                now = time.monotonic()
                since = EMPTY_SINCE.get(name)
                if since is None:
                    EMPTY_SINCE[name] = now
                elif now - since >= IDLE_SECONDS:
                    EMPTY_SINCE.pop(name, None)
                    stop_now.append(name)
        for name in stop_now:
            try:
                rcon_command(name, "stop")
            except Exception:
                pass


def start(name):
    cfg = service(name)
    with LOCK:
        current = state(name)
        if current["state"] != "OFFLINE":
            return current
        instance = str(cfg.get("instance", ""))
        if not instance:
            raise ValueError(f"service {name} has no MSL instance id")
        if not HELPER.is_file():
            raise FileNotFoundError(str(HELPER))
        worker = threading.Thread(target=_launch_msl, args=(name, cfg, instance), daemon=True)
        STARTING[name] = {"since": time.monotonic(), "thread": worker, "done": False}
        LAST_ERRORS.pop(name, None)
        worker.start()
        return state(name)


def _launch_msl(name, cfg, instance):
    instance_name = ""
    server_list_path = MSL.get("server_list")
    if server_list_path:
        server_list = json.loads(Path(server_list_path).read_text(encoding="utf-8-sig"))
        entry = server_list.get(instance)
        if entry:
            instance_name = entry.get("Name", "")
    if not instance_name:
        raise RuntimeError(f"MSL ServerList.json has no name for instance {instance}")
    args = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", str(HELPER), "-InstanceName", instance_name,
            "-InstanceTag", f"#{instance}", "-ServerPort", str(cfg["port"]),
            "-WaitSeconds", str(START_TIMEOUT)]
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        with MSL_START_LOCK:
            if port_open(cfg["port"]):
                with LOCK:
                    launch = STARTING.get(name)
                    if launch:
                        launch["done"] = True
                return
            result = subprocess.run(args, capture_output=True, text=True, encoding="utf-8",
                                    errors="replace", timeout=START_TIMEOUT + 120,
                                    creationflags=creationflags)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "unknown error").strip()
            raise RuntimeError(detail[-800:])
        with LOCK:
            LAST_ERRORS.pop(name, None)
            launch = STARTING.get(name)
            if launch:
                launch["done"] = True
    except Exception as exc:
        with LOCK:
            STARTING.pop(name, None)
            LAST_ERRORS[name] = f"MSL launch failed: {exc}"


class Handler(BaseHTTPRequestHandler):
    def send_json(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        query = parse_qs(urlparse(self.path).query)
        name = query.get("service", [""])[0]
        if urlparse(self.path).path != "/v1/status" or name not in CONFIG["servers"]:
            self.send_json(404, {"error": "unknown service"})
            return
        self.send_json(200, state(name))

    def do_POST(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
            name = body.get("service", "")
            if name not in CONFIG["servers"]:
                raise KeyError(name)
            if parsed.path == "/v1/start":
                result = start(name)
            elif parsed.path == "/v1/heartbeat":
                with LOCK:
                    HEARTBEATS[name] = {"ready": bool(body.get("ready")), "players": int(body.get("players", 0))}
                result = state(name)
            else:
                self.send_json(404, {"error": "unknown endpoint"})
                return
            self.send_json(200, result)
        except (KeyError, FileNotFoundError, ValueError, json.JSONDecodeError) as exc:
            self.send_json(400, {"error": str(exc)})

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    threading.Thread(target=rcon_idle_loop, daemon=True).start()
    server = ThreadingHTTPServer((CONFIG["host"], CONFIG["port"]), Handler)
    print(f"OnDemand controller listening on http://{CONFIG['host']}:{CONFIG['port']}")
    server.serve_forever()
