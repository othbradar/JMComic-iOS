# AI 阶段记录

## 2026-09-30：阅读图片保真与无损下载

- 基线：`5aa3a29743cc37466960b0ef0ed567dfc5474b27`，分支 `codex/root-tab-resident-pages-v6`；开始时 `git status --short --branch` 干净。已读 README、CONTRIBUTING、project.yml，并执行 `git rev-parse HEAD`、`xcodebuild -list -project JMComic.xcodeproj`、`xcrun simctl list devices available`。没有 pull、切分支、重建工程、提交或推送。
- 实际调用：`OnlinePageView → APIClient.decodedPageImage → performDecodedPageLoad → ImageScrambler.decodeImage`；`DownloadManager.enqueue → descriptor → 普通 dataTask → decodeAndStore → ImageScrambler.decode → 文件/SQLite → localPageURLs → LocalPageView.rasterImage`。`decodedPageData` 没有产品调用方，也同步改为保真语义。
- 确认：原来 JPEG/有损 WebP 在条带高度 ≥6 时自动改接缝四行；需要解扰的下载再编码 JPEG 0.96。在线/下载原本共用同一色缝处理，差异是下载的额外有损编码。无需解扰时原实现返回原字节，因此“所有图片都重编码”为失效线索；但旧统一 `.jpg` 命名并不能保证与原字节格式相符。
- 改动：默认只精确还原条带；旧色缝插值改为明确可选项，文字说明可能损伤细线/文字。保留全尺寸逐行还原及方向约定，保留源 RGB 色彩空间；透明页采用带 alpha 的位图，修复跳过透明像素邻域。
- 新下载默认保存无需处理的 JPEG/PNG/WebP 原字节，处理后无损 PNG；省空间选项为有损 JPEG 0.96，含 alpha 时仍 PNG。仅作用于完整阅读图片，封面不变。解码结果携带真实扩展名，先预留真实路径、原子写入，再完成索引；路径修复保留格式，不覆盖另一种格式的既存目标。旧完成文件直接复用，不转换、重下或声称恢复旧损失。
- 设置位于“我的 → 设置 → 阅读图片与下载画质”。在线请求/预取捕获处理策略，派生缓存使用 `page-pixels-v2|策略`；旧请求只能写回自己的策略缓存。下载在 enqueue 首次 await 前捕获两项设置，描述符在排队、暂停、恢复和 CDN 重试时保留它们。失败后重新加入属于新任务；已完成页仍复用。原共享请求、后台解码、预加载及进度合并机制保留。

### 验证与命令

- 环境：Xcode 26.6 (`17F113`)，Simulator runtime/SDK iOS 26.5；保持 `io.github.jmcomic.mobile`，签名及发布配置未改。
- 16 个不同的相关 XCTest 最终通过：条带整数/余数高度、单行/单列及条带数大于行数；跨接缝彩色细线/文字状图案；JPEG、PNG、904 字节合成 WebP；P3/alpha；无损在线/下载归一到相同 sRGB RGBA 后逐像素比较；原字节保留、显式 JPEG；不同策略请求并发和缓存；旧 JPEG/新 PNG 混合索引；描述符兼容、旧路径迁移/回滚、任务去重与全局暂停控制。
- 首轮 15 项中 14 项通过，1 项 API 测试因夹具未隔离 bootstrap 而超时。补齐可注入 transport/configuration/bootstrap 边界后，4 项定向补测通过；最后对修改涉及的 7 项再测全部通过。夹具只含合成像素，无账号凭据或实际漫画。完整 argv 和结果保存在以下日志开头的 `Command line invocation` 及对应 `.xcresult`，未执行全量测试。
  - `Artifacts/image-fidelity/regressions.log` / `regressions.xcresult`
  - `Artifacts/image-fidelity/regressions-fixed.log` / `regressions-fixed.xcresult`
  - `Artifacts/image-fidelity/regressions-final.log` / `regressions-final.xcresult`

最终定向复测实际命令：

```sh
xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug \
  -destination 'platform=iOS Simulator,id=88E155ED-2CC4-4266-8137-148FD7FBB757' \
  -derivedDataPath build/image-fidelity \
  -resultBundlePath Artifacts/image-fidelity/regressions-final.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:JMComicTests/JMComicTests/testFaithfulPagesKeepColourDetailsAndAllStripRows \
  -only-testing:JMComicTests/JMComicTests/testOnlineInFlightPoliciesStaySeparateAndMatchLosslessDownload \
  -only-testing:JMComicTests/JMComicTests/testSyntheticWebPDefaultIsExactAndStorageUsesRealFormat \
  -only-testing:JMComicTests/JMComicTests/testOptInChromaRepairAndLosslessDownloadKeepSamePixels \
  -only-testing:JMComicTests/JMComicTests/testLosslessPagePreservesAlphaAndRGBProfile \
  -only-testing:JMComicTests/JMComicTests/testPageStoragePreferencesAndMixedLegacyLibrary \
  -only-testing:JMComicTests/JMComicTests/testDownloadDescriptorPersistsAttemptAndDecodesLegacyTask \
  CODE_SIGNING_ALLOWED=NO test > Artifacts/image-fidelity/regressions-final.log 2>&1
```

完整 App 构建、安装和启动实际命令（全部成功）：

```sh
xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/image-fidelity-app \
  CODE_SIGNING_ALLOWED=NO build > Artifacts/image-fidelity/app-build.log 2>&1
xcrun simctl boot 467D92A6-2187-48A6-BF24-9824B48313B1
xcrun simctl install 88E155ED-2CC4-4266-8137-148FD7FBB757 build/image-fidelity-app/Build/Products/Debug-iphonesimulator/JMComic.app
xcrun simctl install 467D92A6-2187-48A6-BF24-9824B48313B1 build/image-fidelity-app/Build/Products/Debug-iphonesimulator/JMComic.app
xcrun simctl launch 88E155ED-2CC4-4266-8137-148FD7FBB757 io.github.jmcomic.mobile
xcrun simctl launch 467D92A6-2187-48A6-BF24-9824B48313B1 io.github.jmcomic.mobile
```

- iPhone 17 Pro Max：`88E155ED-2CC4-4266-8137-148FD7FBB757`；iPad Pro 11-inch (M5)：`467D92A6-2187-48A6-BF24-9824B48313B1`。覆盖安装，没有卸载或清空数据；iPad 原登录状态及离线章节保留，iPhone 保持未登录。用 `simctl get_app_container … app/data` 定位安装产物与数据容器，校验两端 `JMComic`/`JMComic.debug.dylib` SHA-256 都与构建产物相同。Simulator 安装会重定位容器 UUID，未据此判断数据丢失。
- CUA smoke：两个完整 App 中实际切换修复开关、两种保存格式，确认菜单和设置布局。只读取新增两个偏好键核对持久化（`simctl spawn … defaults read` 不在应用容器域内，返回不存在；随后读取应用容器 plist 的这两个键确认）。两端最终均 `reader.repairChromaSeams=false`、`downloads.pageImageStorage=lossless`。iPad 已打开原有离线章节并显示图片，随后退出，没有拿实际内容制作夹具或保存内容文件。
- 完整产物：`/Users/othbradar/PycharmProjects/JMComic-iOS/build/image-fidelity-app/Build/Products/Debug-iphonesimulator/JMComic.app`，`DTPlatformName=iphonesimulator`，不是 IPA。`git diff --check` 通过；构建仅有未使用 AppIntents 的 metadata 提示。

### 待人工检查 / 未执行

- 在线图像链路已用拦截 URLSession 的合成响应跑通；真实 CDN 在线阅读界面、真实新下载从加入到完成再离线打开的端到端 smoke **未执行**，请人工检查这两条流程，并查看切换策略后的细节观感及已有任务行为。
- 真机帧率、峰值内存、触控手感、长章节/磁盘紧张时表现 **未执行**；没有运行 Instruments，不用模拟器结果宣称真机性能通过。在线仍直接后台解码像素，不经过 PNG 编码；保真下载的 PNG 可能增加存储和编码成本。
- 本批代码与记录未提交、未推送。等待用户检查完整 App 后再决定是否提交。

### 同批反馈修正：说明文字开关

- 将“尝试修复色缝”下的说明，以及同一画质区的保存格式/任务说明，统一放入现有 `if showsExplanatoryText`。保留其余本批未提交修改。
- 实际构建命令：`xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/image-fidelity-app CODE_SIGNING_ALLOWED=NO build > Artifacts/image-fidelity/explanatory-text-build.log 2>&1`，结果 `BUILD SUCCEEDED`。
- 重新执行上文两个设备的 `simctl install` 和 `simctl launch` 原命令，均成功；完整 App 产物路径不变，未卸载或清数据。
- CUA 在 iPhone 17 Pro Max 和 iPad Pro 11-inch (M5) 分别验证：关闭“显示说明文字”时，画质区只显示开关和保存选择器；开启后出现三段说明；验证后恢复两端原来的关闭状态。两端现有登录状态仍在。
- `git diff --check` 通过。此次只改条件显示，单元测试未执行，图像/下载回归未重复运行。待用户确认设置页；未提交、未推送。

### 提交授权

- 用户确认“好的现在提交”。提交前核对 HEAD、工作区和暂存区，范围仅为本批 6 个产品源码文件、1 个测试文件及本记录。沿用已完成的构建、测试和模拟器验证，此次未重复运行；只作本地提交，不推送。
