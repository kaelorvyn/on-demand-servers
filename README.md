# 按需开服

目标：代理和登入服常驻，大厅与指定子服按需启动；空服连续 180 秒后自动执行 `stop`。

## 组成

- `controller/ondemand_controller.py`：本机控制器，只监听 `127.0.0.1:8791`。
- `plugin/`：Paper 插件源码，通过 `config.yml` 切换 `login`、`lobby`、`lifecycle` 三种角色。
- `controller/config.json`：服务白名单、端口、MSL 实例 ID，以及旧核心的 RCON 配置。
- `tools/start-msl-ui-instance.ps1`：MSL 原位启动 helper，通过 UIA `InvokePattern` 触发常驻 MSL 服务器卡片的“开启服务器”，不截图、不置前台、不模拟鼠标、不重启 MSL。
- `tools/start-msl-instance-restart.ps1`：冷启动专用旧版 helper，仅当 MSL 下没有任何在线子服时使用。

## 停机分工

- 新版 Paper（登入服常驻；大厅、Survival、Exorcism 按需）：插件每秒检查在线人数，空置 `idle-seconds` 后执行 `stop`。`lifecycle` 默认开启，大厅需在 `config.yml` 里显式加 `auto-stop: true`。
- 旧核心 1.8.8/1.12.2（Bedwar、PracticeCourt、PVP、CanyonBattle）：Java 版本无法加载 Java 21 编译的插件 class v65，由控制器每 5 秒通过 RCON `list` 检查空服，空置 180 秒后发送 `stop`。
- RCON 配置只写在旧核心服务上；lobby 和新核心不要配 `rcon`，避免插件和控制器同时执行 `stop`。

## 当前边界

控制器不再直接运行 `start.bat`。MSL 需要保持常驻（代理端、登入服、FRP 都挂在它下面）；启动某个服务时，helper 用 Win32 `EnumWindows` 找到已停服残留管理窗口（`controlServer1` 按钮为“开服”），先 `PostMessage(WM_CLOSE)` 收掉，再定位 MSL 的服务器页对应实例卡片，用 UIA `InvokePattern` 触发“开启服务器”，不重启 MSL、不杀任何在线进程。

大厅模式会读取现有 Citizens `saves.yml` 的 NPC ID 和 `commandtrait`，不需要配置实体 UUID。
