# 构建与开发

## 环境要求

| 用途 | 要求 |
| --- | --- |
| 主程序 | Flutter SDK 3.0.0+ / Windows 10/11 x64 / Git |
| NeoNSF 内核（可选） | [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) |
| 更新器（可选） | [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) |

> [!NOTE]
> 只跑主程序不需要安装 .NET SDK。缺少 `HanabiNeoNSF.exe` 时 NeoNSF 内核不可用，NSFX 仍然正常工作。

## 运行项目

```bash
git clone https://github.com/buaoyezz/hanabi-download-manager-x.git
cd hanabi-download-manager-x
flutter pub get
flutter run
```

## 同步本地化

```bash
dart run tool/sync_l10n.dart
```

`app_en.arb` 可以从 `app_zh.arb` 自动同步，Windows 运行和构建脚本也会在启动前自动执行这一步。

> [!WARNING]
> 极度不推荐依赖这个机翻结果，准确度很低，参考性有限。正式翻译请参考[添加新语言](i18n/ADD_NEW_LANGUAGE_CN.md)。

## 发布构建

推荐使用发布脚本：

```bat
build_release.bat
```

脚本按顺序执行：

| 阶段 | 内容 |
| --- | --- |
| 0 | 应用本地 rhttp Windows 补丁（`scripts/apply-rhttp-windows-fix.ps1`） |
| 0.5 | 同步 l10n |
| 0.65 | 构建 NativeAOT NeoNSF 引擎 |
| 0.75 | 质量门禁：`flutter test` + `flutter analyze --no-fatal-infos` |
| 1 | `flutter build windows --release` |
| 1.5 | 构建 NativeAOT 更新器 |
| 1.7 | 无窗口探测 NeoNSF 协议 |
| 1.75 | 无窗口测试更新器 bundle |
| 2 | 复制资源到 `data/zzbuaoye_assets` |
| 3 | 打包 zip 并生成 `SHA256SUMS.txt` |

先构建 NeoNSF 再跑 Flutter 测试，是为了让集成测试跑在实际会被打包的 NativeAOT 侧车上。

### 脚本参数

| 参数 | 作用 |
| --- | --- |
| `--copy-only` | 跳过 Flutter 构建，只做资源复制与打包 |
| `--no-pause` | 结束后不等待按键，适合 CI |

### 产物

```text
build/release/
├── HanabiDownloadManagerX/                              # 展开目录
├── HanabiDownloadManagerX_Release_Latest.zip
├── HanabiDownloadManagerX_<version>_windows_x64.zip
└── SHA256SUMS.txt
```

## 单独构建各组件

```bash
# 仅 Flutter 主程序
flutter build windows --release
```

```powershell
# 仅 NeoNSF 内核侧车 -> build/neonsf/win-x64/HanabiNeoNSF.exe
powershell -ExecutionPolicy Bypass -File neonsf/build_dotnet.ps1
```

```bat
:: 仅更新器 -> updater/dist/ 与 updater/standalone/
updater\build.bat
```

`neonsf/build_dotnet.ps1` 在发布后会执行 `HanabiNeoNSF.exe --probe`，协议版本不匹配时直接失败。更新器构建细节见[更新器构建](UPDATER_BUILD_CN.md)。

### 其他脚本

| 脚本 | 用途 |
| --- | --- |
| `quick_build.bat` | 只同步 l10n 并跑 `flutter build windows --release`，不打包 |
| `build_popup.bat` | 已废弃占位。下载弹窗已迁移到 Flutter Windows runner 的原生次级窗口 |

## 本地下载测试服务器

```powershell
scripts/start-download-test-server.ps1
scripts/smoke-test-download-server.ps1
```

用于在不打公网流量的情况下验证分段、限速和续传行为。详见[本地下载测试服务器](DOWNLOAD_TEST_SERVER_CN.md)。

## 项目结构

```text
lib/
├── services/kernel/          # 内核路由与实现
│   ├── kernel_manager.dart   # 双内核路由器
│   ├── next/                 # NSFX：Dart 引擎、HTTP 服务器、任务存储
│   └── neonsf/               # NeoNSF：进程桥、任务存储
├── services/                 # 下载调度、插件、托盘、窗口特效、更新等
├── screens/ · widgets/       # UI 与设置页
├── platform/windows/         # Win32 桥接：窗口特效、窗口状态
├── popup/                    # 浏览器下载弹窗
└── l10n/                     # 本地化 arb 与生成代码
neonsf/dotnet/                # NeoNSF .NET 8 NativeAOT 侧车
updater/dotnet/               # 更新器 .NET 10 + Avalonia
plugins/                      # 插件 SDK、Schema、官方插件
plugins-list/                 # 插件市场条目
browser_extension/            # Chrome / Firefox 扩展
tool/                         # Dart 命令行工具
scripts/                      # 构建与测试脚本
docs/ · test/                 # 文档与测试
```

## 测试

```bash
flutter test
flutter analyze --no-fatal-infos
```

测试覆盖内核稳定性（`test/services/kernel/`）、插件清单与运行器、窗口特效、弹窗配置和 UI 组件。更新器有独立的 .NET 测试工程 `updater/dotnet/Hanabi.Updater.Core.Tests/`。
