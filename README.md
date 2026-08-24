# JMComic-iOS

面向 iPhone 与 iPad 的非官方 JMComic 原生 SwiftUI 客户端。

[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS-0A84FF)](https://developer.apple.com/ios/)
[![Minimum OS](https://img.shields.io/badge/minimum-iOS%2018-555555)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.0-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)

> [!WARNING]
> 本项目仅供具备完全民事行为能力的成年人学习、研究和自用。项目不提供、存储或分发任何漫画资源，也不是 JMComic 官方产品。

## 项目预览

截图均已人工筛选，不包含账号信息、Cookie、下载内容或明显成人画面。发现首页和漫画详情使用正常内容状态，其余页面来自全新、未登录的模拟器。

| 发现首页 | 漫画详情 |
| --- | --- |
| ![发现首页](docs/screenshots/discover-iphone.png) | ![漫画详情](docs/screenshots/detail-iphone.png) |

| iPhone | iPhone | iPhone |
| --- | --- | --- |
| ![搜索](docs/screenshots/search-iphone.png) | ![收藏](docs/screenshots/favorites-iphone.png) | ![下载](docs/screenshots/downloads-iphone.png) |
| 搜索 | 多收藏夹 | 离线书库 |
| ![我的](docs/screenshots/account-iphone.png) | ![设置](docs/screenshots/settings-iphone.png) | ![登录](docs/screenshots/login-iphone.png) |
| 我的 | 设置 | 登录 |

| iPad 搜索 | iPad 收藏 | iPad 我的 |
| --- | --- | --- |
| ![iPad 搜索](docs/screenshots/search-ipad.png) | ![iPad 收藏](docs/screenshots/favorites-ipad.png) | ![iPad 我的](docs/screenshots/account-ipad.png) |

## 功能

- 账号：登录、启动时刷新凭证、Keychain/Data Protection 存储、每日签到与月度签到日历。
- 浏览：发现栏目、搜索与搜索历史、JM 号直达、详情、作者/标签检索、相关推荐。
- 阅读：连续和分页模式、阅读进度、图片解扰、预取、触屏与妙控触控板缩放、在线及离线阅读。
- 收藏：多收藏夹、创建/删除/移动、SQLite 本地优先缓存、增量与手动全量同步、收藏时间或漫画更新时间排序。
- 评论：评论列表、嵌套回复、发表与回复、“我的评论”，并清理服务端 HTML 片段。
- 下载：章节下载、暂停/恢复/重试、并发限制、SQLite 索引，以及“文件”App 可见的漫画、封面缓存和数据库。
- iPad：分栏收藏夹、横竖屏与自由窗口布局、键盘/触控板交互、沉浸式全屏阅读。
- 个性化：浅色/深色模式、六种页面底色、API/CDN 线路选择、说明文字开关。

更完整的模块、协议、SQLite 表、收藏同步、下载和阅读流程见 [IMPLEMENTATION.md](IMPLEMENTATION.md)。

## 系统要求

- iOS / iPadOS 18.0 或更高版本
- macOS 与 Xcode（工程当前使用 iOS 26.5 SDK 验证）
- 真机安装需要自己的 Apple Developer Team 或个人签名工具

## 下载

最新 IPA 可从 [GitHub Releases](https://github.com/othbradar/JMComic-iOS/releases/latest) 下载。公开产物为不包含个人证书或 Provisioning Profile 的 arm64 未签名 IPA，需要使用 AltStore、Sideloadly 或其他可靠工具以自己的证书重签后安装。

## 构建

```bash
git clone https://github.com/othbradar/JMComic-iOS.git
cd JMComic-iOS
open JMComic.xcodeproj
```

在 Xcode 的 **Signing & Capabilities** 中选择自己的 Team，然后运行 `JMComic` scheme。命令行无签名构建示例：

```bash
xcodebuild \
  -project JMComic.xcodeproj \
  -scheme JMComic \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

工程已提交生成后的 `JMComic.xcodeproj`。修改 `project.yml` 后可通过 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 重新生成：

```bash
brew install xcodegen
xcodegen generate
```

## 本地数据

开启文件共享后，可在“文件”App 的“我的 iPhone / iPad → JMComic”中看到：

```text
JMComic/
├── download/     # 漫画/章节/图片
├── cache/        # 下载、收藏和最近观看封面
└── database/     # SQLite 数据库及 WAL/SHM
```

数据库只保存容器内相对路径，不写入会随安装变化的绝对路径。账号凭证不会写入可见数据库或公开文件夹。请勿在 Issue、日志或截图中提交账号、Cookie、数据库和下载内容。

## 项目结构

```text
JMComic/
├── Core/         # 模型、外观、线路和本地安全存储
├── JMService/    # 服务地址、请求字段、签名与响应协议
├── Networking/  # API、解密、图片处理与故障转移
├── Services/     # SQLite、下载、阅读进度等服务
├── Components/   # 通用 SwiftUI 组件
└── Features/     # 发现、搜索、详情、阅读、收藏、下载、账号
```

服务地址和 wire protocol 集中在 `JMComic/JMService/`。上游协议发生变化时，应优先修改这一层及相关协议测试，避免在界面和下载器中散落兼容代码。

## 隐私与内容

- 仓库不包含漫画、封面、账号、数据库、签名证书或 IPA。
- 应用不内置第三方统计或广告 SDK。
- 搜索、收藏、签到、评论和图片请求会直接访问用户选择的 JMComic 服务线路。
- 下载内容的合法性与使用范围由使用者自行确认。

## 已知限制

- 第三方服务的地址、签名或响应结构变化可能导致部分功能暂时不可用。
- 当前下载使用普通 `URLSession`；系统挂起或终止应用后不保证继续传输，重新进入后可恢复未完成任务。
- 免费 Personal Team 签名通常需要定期续签。

## 贡献

提交代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请按 [SECURITY.md](SECURITY.md) 说明报告。提交截图和日志时必须移除成人内容及账号数据。

## 参考与致谢

- [tonquer/JMComic-qt](https://github.com/tonquer/JMComic-qt) — 桌面客户端和协议行为参考
- [Dedicatus546/jm-mobile](https://github.com/Dedicatus546/jm-mobile) — 移动端交互与签到行为参考
- [heihaolin/jmcomic](https://github.com/hect0x7/JMComic-Crawler-Python) — JMComic Python 生态与协议兼容性参考

本仓库的 Swift 源码为独立实现。第三方项目的版权及许可证归各自权利人所有，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 免责声明

本项目与 JMComic 及上述第三方项目均无隶属或授权关系，仅用于 SwiftUI、网络协议兼容和本地数据管理的技术研究。维护者不提供内容服务，不对第三方服务的可用性、内容或使用后果作保证。使用者应遵守所在地法律、服务条款与内容授权要求。

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE) 开源。
