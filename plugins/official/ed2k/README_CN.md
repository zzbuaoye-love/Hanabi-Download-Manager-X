# Hanabi ED2K 官方插件

`hanabi.official.ed2k` 为 Hanabi Download Manager X 提供独立的 ED2K 文件下载能力。插件通过 Hanabi API v1 接收任务，使用隔离的 aMule 后端执行下载，并把进度与控制操作映射回 Hanabi。

> [!IMPORTANT]
> 插件只接受 `ed2k://|file|...|/` 文件链接，不处理服务器、服务器列表或搜索链接。请只下载你有权获取或分发的内容。

## 功能

- 解析 ED2K 文件名、字节大小和 128 位文件哈希；
- 以 ED2K 哈希生成稳定任务 ID，宿主重试不会重复添加任务；
- 支持创建、查询、暂停、继续和移除任务；
- 首次启动前预置 `server.met` 与 `nodes.dat`，避免守护进程因为没有服务器和 Kad 节点而永远停在「等待中」；
- 默认开启 UPnP 端口映射，尽量拿到 HighID；处于 LowID 时只能连接非防火墙用户，来源会大幅减少；
- 上报来源数量与等待原因（`statusDetail`），并按进度采样估算速度；
- 使用 aMule 的临时文件恢复未完成下载；
- 下载完成后安全移动到 Hanabi 指定的 `saveDir`；
- 私有 aMule External Connections 仅绑定 `127.0.0.1`，并使用随机密码；
- Windows x64/ARM64 首次运行时可自动下载并校验 aMule 3.0.0；
- 支持包内 aMule、本机 aMule 和外部 aMule EC 三种运行方式。

## 安装

推荐从 Hanabi 官方插件市场安装“Hanabi ED2K”。也可以在仓库根目录独立校验和打包：

```powershell
dart run tool/validate_plugin.dart .\plugins\official\ed2k

powershell -ExecutionPolicy Bypass -File .\scripts\package-plugin.ps1 `
  -PluginDir .\plugins\official\ed2k
```

宿主当前通过 `python` 启动 Python 插件，因此系统需要 Python 3.10 或更高版本。插件业务代码不依赖第三方 Python 包。

## aMule 后端

未配置外部 EC 时，插件按以下顺序寻找后端：

1. `AMULED_PATH` 与 `AMULECMD_PATH` 指定的程序；
2. `AMULE_HOME` 或 `config.json` 中的 `amuleHome`；
3. 插件包内的 `bin/` 或 `amule/`；
4. 插件数据目录中已校验安装的引擎；
5. 系统 `PATH` 中的 `amuled` 与 `amulecmd`；
6. Windows x64/ARM64 上从 aMule 官方 GitHub Release 下载固定版本。

自动安装资产固定为 aMule 3.0.0，并同时校验归档大小和 SHA-256。中断的归档下载会从已有字节继续。引擎、运行配置、临时文件和完成前的下载内容位于：

```text
<Hanabi 数据目录>/plugins/data/hanabi.official.ed2k/
```

aMule 运行日志位于：

```text
<Hanabi 数据目录>/plugins/logs/hanabi.official.ed2k/amule.log
```

## 设置

插件在「插件」页注册了设置面板（`ui_extensions.settings`），可以直接调整：

| 设置 | 说明 |
| --- | --- |
| UPnP 端口映射 | 关闭后处于 LowID，只能连接非防火墙用户。 |
| 监听端口 | 留空则随机分配。填固定端口（1024-65535）才能在路由器上做转发，UDP 自动取 +10。 |
| 启动时自动连接 ED2K 与 Kad | 对应 `autoConnect`。 |
| 自动补齐服务器列表与 Kad 节点 | 对应 `bootstrapNetwork`。 |
| 服务器列表地址 | 多个用空格或换行分隔，按顺序尝试，排在内置列表之前。 |
| 同时使用内置服务器列表 | 关闭后只使用自填地址，对应 `useDefaultServerLists`。 |
| Kad 节点表地址 | 同上，对应 `kadNodesUrl`。 |
| 同时使用内置 Kad 节点源 | 对应 `useDefaultKadNodes`。 |
| 每个文件的最大来源数 | 100–1000。 |
| 立即更新服务器列表与 Kad 节点 | 调用 `ed2k.network.refresh`，忽略 7 天的新鲜度判断强制重新下载。 |

内置列表包含官方源 `upd.emule-security.org` 与两个实测可用的第三方镜像
（`ed2k.2x4u.de`、`gruk.org`）。写入前会校验格式，返回 HTML 提示页的失效镜像会被跳过。

改动通过 `onSettingsChanged` 合并写入下面的 `config.json`，只覆盖插件声明过的键，
手工写入的其他键不受影响。aMule 只在启动时读取配置，因此设置在 ED2K 后端下次启动时生效。

## 配置

默认无需配置。高级配置文件路径为：

```text
<插件数据目录>/config.json
```

私有后端示例：

```json
{
  "autoInstallEngine": true,
  "amuleHome": "C:\\Tools\\aMule",
  "autoConnect": true,
  "startupTimeoutSeconds": 20
}
```

列表来源示例。Hanabi 设置页的「ED2K 网络列表」写的就是这几个键，也可以手工编辑：

```json
{
  "serverMetUrls": [
    "http://my-mirror.example/server.met",
    "https://upd.emule-security.org/server.met"
  ],
  "kadNodesUrls": ["https://upd.emule-security.org/nodes.dat"],
  "useDefaultServerLists": false,
  "useDefaultKadNodes": true
}
```

| 键 | 说明 |
| --- | --- |
| `serverMetUrls` | 服务器列表来源，按顺序尝试，第一个返回合法二进制列表的地址生效。也接受单个字符串。 |
| `kadNodesUrls` | Kad 节点表来源，规则同上。 |
| `useDefaultServerLists` | 是否在自定义地址之后追加内置列表，默认 `true`。 |
| `useDefaultKadNodes` | 是否追加内置 Kad 节点源，默认 `true`。 |

写入前会校验文件格式：`server.met` 必须以版本字节和合理的服务器数量开头。
镜像站失效后经常改成返回 HTML 提示页，直接写进去会让 aMule 无法解析整份列表。

外部 aMule EC 示例：

```json
{
  "amuleHost": "127.0.0.1",
  "amulePort": 4712,
  "amulePassword": "replace-with-your-ec-password",
  "amulecmdPath": "C:\\Tools\\aMule\\bin\\amulecmd.exe",
  "externalIncomingDir": "D:\\aMule\\Incoming"
}
```

环境变量优先于 `config.json`：

| 环境变量 | 说明 |
| --- | --- |
| `AMULE_HOME` | 包含 `amuled` 与 `amulecmd` 的目录或其上级目录。 |
| `AMULED_PATH` | `amuled` 可执行文件路径。 |
| `AMULECMD_PATH` | `amulecmd` 可执行文件路径。 |
| `AMULE_AUTO_INSTALL` | `true`/`false`，控制缺少后端时是否自动安装固定版本。 |
| `AMULE_AUTO_CONNECT` | `true`/`false`，控制私有后端是否自动连接 ED2K/Kad 网络。 |
| `AMULE_BOOTSTRAP_NETWORK` | `true`/`false`，控制启动前是否补齐 `server.met` 与 `nodes.dat`，默认 `true`。 |
| `AMULE_SERVER_MET_URL` | 服务器列表地址，多个用空白或换行分隔，留空使用配置与内置镜像。 |
| `AMULE_KAD_NODES_URL` | Kad 节点表地址，规则同上。 |
| `AMULE_DEFAULT_SERVER_LISTS` | `true`/`false`，是否追加内置服务器列表，默认 `true`。 |
| `AMULE_DEFAULT_KAD_NODES` | `true`/`false`，是否追加内置 Kad 节点源，默认 `true`。 |
| `AMULE_UPNP` | `true`/`false`，控制是否尝试 UPnP 端口映射，默认 `true`。 |
| `AMULE_HOST` | 启用外部 EC 模式并指定主机。 |
| `AMULE_PORT` | 外部 EC 端口，默认 `4712`。 |
| `AMULE_PASSWORD` | 外部 EC 明文密码。 |
| `AMULE_INCOMING_DIR` | 外部 aMule 的完成目录，用于发现并移动文件。 |

外部模式由用户负责 aMule 的访问控制、进程生命周期和下载目录配置。不要把未受保护的 EC 端口暴露到公网。

## 任务行为

- `startPaused` 会在添加任务后立即调用 aMule 暂停命令；
- 队列短暂不可见时保留 30 秒宽限期，避免守护进程恢复期间误报失败；
- aMule 队列只提供一位小数的百分比，`speed` 由相邻两次采样的字节差推算：进度未变时保持上一次的速度，
  连续 45 秒没有变化才归零，因此数值是平均值而非瞬时值；
- ED2K 任务长时间停在「等待中」通常不是故障：服务器满员、来源在排队、或者本机是 LowID。
  `statusDetail` 会写明具体原因，例如 `searching for sources · not connected to ed2k or Kad`；
- 完成文件与目标目录中的同名文件冲突时，会保留既有文件，并在新文件名后附加 ED2K 哈希前缀；
- 从 Hanabi 移除未完成任务会取消 aMule 任务并清理对应的 part 文件；
- 已完成并移动到目标目录的文件不会因移除 Hanabi 任务而删除；
- `pluginData` 只保存哈希、文件信息和恢复所需路径，不保存 EC 密码。

## 关于 LowID 与「找不到来源」

这是两件不同的事，排查时不要混淆：

- **LowID** 表示本机的监听端口不可从外部访问，只能连接 HighID 用户，无法被其他
  LowID 用户连接。它影响的是「能用哪些来源」，不影响来源的**发现**。
  成因通常是 UPnP 映射失败（Windows 上 aMule 的 UPnP 常报
  `UPNP_E_SOCKET_BIND`）、路由器未转发端口，或系统防火墙未放行 `amuled.exe`。
  拿 HighID 需要三件事同时成立：固定监听端口、路由器转发该端口、防火墙放行。
- **Total sources: 0** 表示已连接的服务器和 Kad 里没有任何人在共享这个文件。
  这与 LowID 无关，调任何参数都不会有来源。冷门文件、体积大的新文件在
  ED2K 上经常是这个状态；`statusDetail` 会显示 `searching for sources`。

用 `amulecmd --command=Status` 可以直接区分：`eD2k:` 行给出连接与 ID 状态，
`Total sources:` 给出全局来源数。

## 已知限制

- 当前仅支持单文件 ED2K 文件链接，不支持服务器链接、搜索、集合或逐文件选择；
- ED2K 网络的可用性、来源数量和速度由 aMule、服务器与 Kad 网络决定；
- 非 Windows 平台不自动安装 aMule，需要提供本机程序或外部 EC；
- 外部模式若不配置 `externalIncomingDir`，插件无法自动确认和移动已完成文件；
- 当前插件不提供服务器列表、Kad 状态、限速和连接参数 UI。

## 开发与测试

```powershell
$env:PYTHONDONTWRITEBYTECODE = '1'
python -m unittest discover `
  -s .\plugins\official\ed2k\tests `
  -p "test_*.py" -v
```

插件目录中的 `hanabi_plugin.py` 是 API v1 单文件 Python SDK 的随包副本，使该目录可以脱离主仓库独立打包。

## 许可证与第三方组件

插件自身源码使用 MIT License。自动安装的 aMule 来自 [aMule 3.0.0 官方 GitHub Release](https://github.com/amule-project/amule/releases/tag/3.0.0)，aMule 及其随包组件适用其各自许可证；上游归档中的许可证文件会随引擎保存在插件数据目录。
