<div align="left">

# Hanabi Download Manager X
[![Release](https://img.shields.io/github/v/release/buaoyezz/Hanabi-Download-Manager-X?label=Release&style=flat-square&color=orange)](https://github.com/buaoyezz/Hanabi-Download-Manager-X/releases)
![Downloads](https://img.shields.io/github/downloads/buaoyezz/Hanabi-Download-Manager-X/total?label=Downloads&style=flat-square&color=gold)
[![Website](https://img.shields.io/badge/Website-x.zzbuaoye.net-2ea44f?style=for-the-badge)](https://x.zzbuaoye.net)
[![Notice](https://img.shields.io/badge/Notice-Web%20Notices-0ea5e9?style=for-the-badge)](https://x.zzbuaoye.net/web-notices.html)
[![Releases](https://img.shields.io/badge/Releases-GitHub-orange?style=for-the-badge&logo=github)](https://github.com/buaoyezz/Hanabi-Download-Manager-X/releases)
[![Docs](https://img.shields.io/badge/Docs-Menu-7c3aed?style=for-the-badge)](https://x.zzbuaoye.net/docs)
[![Homepage](https://img.shields.io/badge/Homepage-zzbuaoye.net-blue?style=for-the-badge)](https://zzbuaoye.net)

中文 | [English](README.md)

</div>

![Preview](readme_assets/image1.png)

使用 Flutter 构建的 Windows 桌面下载管理器。双内核（NSFX + NeoNSF）、多线程分段、断点续传，以及进程隔离的插件系统。

> [!NOTE]
> 仅面向 Windows 10/11，其他系统暂无适配预期。Win10 与 Win11 存在 API 差异，遇到异常直接提 [Issue](https://github.com/buaoyezz/Hanabi-Download-Manager-X/issues)

> [!IMPORTANT]
> 本项目有大量 AI 参与开发，相当一部分代码由 AI 协助完成，如果遇到比较好笑的质量问题请直接提 Issue，`无法接受的请勿使用`。个人时间有限，不建议直接提交 PR，更推荐通过 Issue 反馈

## 快速开始

```bash
git clone https://github.com/buaoyezz/hanabi-download-manager-x.git
cd hanabi-download-manager-x
flutter pub get
flutter run
```

需要 Flutter SDK 3.0.0+ 与 Windows 10/11 x64。发布构建用 `build_release.bat`，完整环境要求和分组件构建见[构建与开发](https://x.zzbuaoye.net/docs/?page=build)。

## 文档

**[x.zzbuaoye.net/docs](https://x.zzbuaoye.net/docs)** — 项目概览、构建指南、下载内核架构、插件开发与发布（仓库内镜像：[docs/Menu.md](docs/Menu.md)）

- [项目概览](https://x.zzbuaoye.net/docs/?page=introduction) — 特性总览、平台支持、数据目录
- [下载内核](https://x.zzbuaoye.net/docs/?page=kernel) — NSFX 与 NeoNSF 的模式、路由与持久化
- [插件开发](https://x.zzbuaoye.net/docs/?page=overview) — JSON-RPC 插件模型、API 与市场发布

## 许可证

核心应用 [GPLv3](LICENSE)，插件与 SDK（`plugins/`）[MIT](plugins/LICENSE)。

> [!IMPORTANT]
> 只要使用提供的 MIT 协议插件 API，你可以自由开发开源或闭源插件，`不会受` GPLv3 传染性要求影响

[隐私政策](https://x.zzbuaoye.net/privacy) · [服务条款](https://x.zzbuaoye.net/terms) · Copyright © 2026 [ZZBuAoYe](https://zzbuaoye.net)
