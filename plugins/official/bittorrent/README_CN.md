# Hanabi BitTorrent 官方插件

> 当前插件无法可靠完成磁力链接和 `.torrent` 下载，暂不建议安装或用于正式任务。代码保留用于排查和修复。

`hanabi.official.bittorrent` 为 Hanabi Download Manager X 提供独立的磁力链接和 `.torrent` 文件下载能力。插件通过 Hanabi API v1 接收任务，使用隔离的 aria2 后端执行 BT 协议，并把进度、速度和控制操作映射回 Hanabi。

## 功能

- 磁力链接和本地 `.torrent` 文件；
- 暂停、继续、移除与应用重启后的未完成任务恢复；
- 磁力元数据任务到实际下载任务的 GID 跟踪；
- 默认开启 DHT、LPD、PEX 并附带一组公共 Tracker，磁力链接不必等 DHT 冷启动；
- 解除 aria2 默认的 `bt-request-peer-speed-limit=50K`：超过该速度后 aria2 会停止索取新 peer，
  这是 aria2 下 BT 速度远低于桌面 BT 客户端的主要原因；
- 元数据阶段单独上报，不会把几十 KB 的种子体积当成文件大小；
- 单文件与多文件 Torrent 的路径、总大小、进度和速度回传；
- 插件私有 aria2 RPC，仅监听 `127.0.0.1` 并使用随机密钥；
- Windows x64/x86 上按固定 URL 与 SHA-256 校验首次安装 aria2 1.37.0；
- 包内 aria2、系统 aria2 和外部 aria2 RPC 三种运行模式。

插件只应用于你有权下载或分发的内容。

## 安装

如需排查，可从仓库根目录独立校验并打包：

```powershell
dart run tool/validate_plugin.dart .\plugins\official\bittorrent

powershell -ExecutionPolicy Bypass -File .\scripts\package-plugin.ps1 `
  -PluginDir .\plugins\official\bittorrent
```

宿主当前通过 `python` 启动 Python 插件，因此系统需要 Python 3.10 或更高版本。插件业务代码不需要安装第三方 Python 包。

## aria2 后端

插件按以下顺序选择后端：

1. `ARIA2_RPC_URL` 或 `config.json` 中配置的外部 RPC；
2. `ARIA2C_PATH` 指定的程序；
3. 插件包内 `bin/aria2c.exe`；
4. 插件根目录下的 `aria2c.exe`；
5. 系统 `PATH` 中的 `aria2c`；
6. Windows x64/x86 上下载经过 SHA-256 固定校验的官方 aria2 1.37.0。

自动下载的程序、会话和运行配置只写入：

```text
<Hanabi 数据目录>/plugins/data/hanabi.official.bittorrent/
```

aria2 运行日志位于：

```text
<Hanabi 数据目录>/plugins/logs/hanabi.official.bittorrent/aria2.log
```

## 设置

插件在「插件」页注册了设置面板（`ui_extensions.settings`）：

| 设置 | 说明 |
| --- | --- |
| 使用内置公共 Tracker 列表 | 对应 `useDefaultTrackers`，私有种子可关闭。 |
| 额外 Tracker | 逗号或换行分隔，追加在内置列表之后。 |
| 同时下载的种子数 | 1–10，对应 aria2 的 `max-concurrent-downloads`。 |
| 缺少 aria2 时自动安装 | 对应 `autoInstallEngine`。 |
| 重启 aria2 后端以应用改动 | 调用 `bittorrent.engine.restart`。 |

改动通过 `onSettingsChanged` 合并写入 `config.json`，只覆盖插件声明过的键。
`aria2.conf` 在后端启动时生成，因此改完 Tracker 或并发数后需要点一次「重启 aria2 后端」；
aria2 退出前会保存会话，未完成的种子会带着新配置继续。

## 配置

默认无需配置。高级配置文件路径为：

```text
<插件数据目录>/config.json
```

完整示例：

```json
{
  "autoInstallEngine": true,
  "aria2cPath": "C:\\Tools\\aria2c.exe",
  "startupTimeoutSeconds": 12,
  "rpcUrl": "",
  "rpcSecret": ""
}
```

环境变量优先于 `config.json`：

| 环境变量 | 说明 |
| --- | --- |
| `ARIA2_RPC_URL` | 使用已有 aria2 JSON-RPC，例如 `http://127.0.0.1:6800/jsonrpc`。 |
| `ARIA2_RPC_SECRET` | 外部 RPC 密钥，不会写入 Hanabi 任务数据。 |
| `ARIA2C_PATH` | 本地 aria2c 可执行文件路径。 |
| `ARIA2C_AUTO_INSTALL` | `true`/`false`，控制缺少 aria2c 时是否自动安装固定版本。 |
| `ARIA2_BT_TRACKERS` | 追加的 Tracker，逗号或空白分隔。 |
| `ARIA2_DEFAULT_TRACKERS` | `true`/`false`，控制是否使用内置公共 Tracker 列表，默认 `true`。 |

`config.json` 中还可以用 `trackers`（字符串或数组）追加 Tracker，用 `useDefaultTrackers: false`
完全替换内置列表。私有 Tracker 的种子不需要公共 Tracker，可按需关闭。

使用外部 RPC 时，由外部服务负责会话恢复、访问控制和进程生命周期。不要把无鉴权的 aria2 RPC 暴露到公网。

## 任务行为

- 新任务保存在 Hanabi 选择的下载目录；Torrent 自带的文件名和目录结构优先。
- `startPaused` 会通过 aria2 的 `pause` 选项创建暂停任务。
- 下载完成后 `seed-time=0`，插件不会持续做种。
- 从 Hanabi 移除任务时只清理 aria2 任务记录，不删除已下载文件。
- 插件在 `pluginData` 中只保存 GID 和数据结构版本，不保存 RPC 密钥。

## 已知限制

- 当前没有逐文件选择、Tracker 编辑、限速和做种比例 UI；
- Windows ARM64 不提供自动下载的 aria2 构建，需要包内程序、系统安装或外部 RPC；
- aria2 后端被手动删除且任务记录无法恢复时，Hanabi 会把该任务标记为失败；
- 外部 RPC 地址或密钥改变后，已有任务需要恢复原连接配置才能继续管理。

## 开发与测试

```powershell
python -m unittest discover `
  -s .\plugins\official\bittorrent\tests `
  -p "test_*.py" -v
```

插件目录内的 `hanabi_plugin.py` 是 API v1 单文件 SDK 的随包副本，使该目录可以脱离主仓库独立打包。

## 许可证与第三方组件

插件源码采用 MIT License。自动安装的 aria2 来自 [aria2 官方 GitHub Release](https://github.com/aria2/aria2/releases/tag/release-1.37.0)，其 `COPYING` 与 OpenSSL 许可文件会随引擎一起保存在插件数据目录。
