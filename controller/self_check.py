import json
import tempfile
from pathlib import Path


def check_config():
    config = json.loads((Path(__file__).parent / "config.json").read_text(encoding="utf-8"))
    assert config["host"] == "127.0.0.1"
    assert config["port"] > 1024
    assert config["servers"]
    msl = config["msl"]
    server_list = json.loads(Path(msl["server_list"]).read_text(encoding="utf-8-sig"))
    helper = Path(__file__).resolve().parent.parent / "tools" / "start-msl-ui-instance.ps1"
    assert helper.is_file()
    for name, server in config["servers"].items():
        assert name and server["directory"] and server["instance"]
        assert 1 <= int(server["port"]) <= 65535
        instance = str(server["instance"])
        assert instance in server_list, f"MSL instance {instance} missing for {name}"
        assert server_list[instance].get("Name"), f"MSL instance {instance} has no Name for {name}"
    print(f"controller config: OK ({len(config['servers'])} services mapped into MSL)")


if __name__ == "__main__":
    check_config()
