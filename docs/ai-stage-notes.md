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

## 2026-09-30：根横滑锁轴与阅读焦点缩放

- 基线：`89639e3ff75c3bc73162d8d3e58b3330f08438c0`，分支仍为 `codex/root-tab-resident-pages-v6`；`git status --short --branch` 干净。已核对 README、CONTRIBUTING、project.yml、`xcodebuild -list -project JMComic.xcodeproj` 和 `xcrun simctl list devices booted`。没有 pull、切分支或更改签名配置。
- 真实入口：`JMComicApp → RootView → RootResidentPages`。`LegacyRootView` 只保留编译参考，没有实例化；未修改其交互实现。确认活动根页的 update/finish 每次重新按纵向位移判轴，且初始方向截断反向位移；连续缩放原来仅改变整列宽度，未保存焦点页内位置；导航栏桥每次调度递归扫描整个窗口。
- 横滑：UIKit 开始识别时确定水平/拒绝状态，明确纵向与排除区域继续拒绝本次序列；识别后 update 和 finish 使用锁轴语义。取消归零、穿零自然反向，保留现有阈值、弹簧、首尾边界和导航路径限制。动画期间拒绝重复 begin；尺寸/外部 Tab/阅读器状态变化使旧序列失效，旧动画 token 不会覆盖新状态。常驻页面、ViewModel、task 结构保留。
- 阅读：仍使用现有 SwiftUI ScrollView + LazyVStack、分页 TabView 和原图片加载路径。缩放状态移入局部 surface；每个已实例化页面缓存基准高度，仅在图片/基准宽度变化时更新，外层占位宽高按缩放增长。变换逐页应用，没有整章位图或对裁剪视口整体放大，没有降采样/重编码。捏合更新合并到显示帧；弱引用标记只追踪已实例化页面，以页号、页内归一化坐标和视口焦点补偿 UIKit contentOffset，不逐帧 scrollTo 整页。保留真实滚动范围、横向边界与方向锁。
- 连续/分页均加入互斥双击和单击：双击 2x/复位；分页与连续共用焦点坐标函数。GestureState 结束/取消清理缩放和平移起点；尺寸变化保留合理页内位置并清理旧尺寸手势起点。导航栏桥移到各导航内容内部，只查自身 responder 祖先，按实例弱缓存 window/controller/bar；同一轮调度合并，边距确有差异才写入，无全局缓存和全窗口递归扫描。

### 本批验证

- 16 项不同的相关 XCTest 最终通过：首轮 14 项；另补真实 SwiftUI 懒布局 1 项；最终补测 3 项（其中新增覆盖既有生命周期测试 1 项）。覆盖横滑后纵向漂移、垂直起始不抢占、排除/取消、穿零反向、首尾、投影阈值、重复 begin；偏心焦点、页起点估算变化、边界、UIKit 取消后平移、尺寸变化；真实懒布局放大后的占位/滚动范围及有限页面实例数。夹具仅为内存中的灰色矩形和彩线，无账号/真实漫画。
- 懒布局测试前两次失败：未连接 UIWindowScene 的宿主没有实际刷新 SwiftUI 布局，scale 已变但 frame 未变；将测试窗口接入现有场景并显示，第三次及最终复测通过。产品未据此增加重建视图或强制全章布局。首轮、两次失败及修正日志均保留，不以失败记录冒充通过。
- 日志目录 `Artifacts/gesture-focal/`：`regressions.log/.xcresult`（14 项通过）；`lazy-layout.log/.xcresult`、`lazy-layout-2.log/.xcresult`（失败）；`lazy-layout-3.log/.xcresult`（通过）；`final-targeted.log/.xcresult`（3 项通过）。每份日志开头的 `Command line invocation` 保存实际全部参数和 only-testing 名称；未执行全量测试。

最终定向复测实际命令：

```sh
xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug \
  -destination 'platform=iOS Simulator,id=88E155ED-2CC4-4266-8137-148FD7FBB757' \
  -derivedDataPath build/gesture-focal -resultBundlePath Artifacts/gesture-focal/final-targeted.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:JMComicTests/JMComicTests/testContinuousZoomBridgeRetainsOffCenterPagePointAndAllowsPanAfterCancel \
  -only-testing:JMComicTests/JMComicTests/testLazyContinuousRowsKeepFocalPointAndBaseMeasurementsAcrossZoom \
  -only-testing:JMComicTests/JMComicTests/testRootTabGestureLifecycleRejectsRepeatedBeginUntilCleanup \
  CODE_SIGNING_ALLOWED=NO test > Artifacts/gesture-focal/final-targeted.log 2>&1
```

完整 App 最终构建/安装实际命令：

```sh
xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/gesture-focal-app \
  CODE_SIGNING_ALLOWED=NO build > Artifacts/gesture-focal/final-build.log 2>&1
xcrun simctl install 88E155ED-2CC4-4266-8137-148FD7FBB757 build/gesture-focal-app/Build/Products/Debug-iphonesimulator/JMComic.app
xcrun simctl launch 88E155ED-2CC4-4266-8137-148FD7FBB757 io.github.jmcomic.mobile
xcrun simctl terminate 467D92A6-2187-48A6-BF24-9824B48313B1 io.github.jmcomic.mobile
xcrun simctl install 467D92A6-2187-48A6-BF24-9824B48313B1 build/gesture-focal-app/Build/Products/Debug-iphonesimulator/JMComic.app
xcrun simctl launch 467D92A6-2187-48A6-BF24-9824B48313B1 io.github.jmcomic.mobile
```

- 结果均成功；环境仍为 Xcode 26.6 / iOS 26.5 Simulator。完整产物 `/Users/othbradar/PycharmProjects/JMComic-iOS/build/gesture-focal-app/Build/Products/Debug-iphonesimulator/JMComic.app`。保持 `io.github.jmcomic.mobile`，没有卸载或清数据，已有登录和 iPad 离线章节仍在。通过 `simctl get_app_container … app/data` 定位两端容器，Python hashlib 校验主程序及 debug dylib 均与产物一致，结果在 `installed-product-check.log`。这是 Simulator App，非真机 IPA。构建仅原有 AppIntents metadata 提示，`git diff --check` 通过。
- CUA 实际观察：iPad 连续/分页阅读均双击 100%→200%→100%，单击显示控件，切换模式仍显示当前章节，旋转与复原可正常显示内容，退出回到原离线章节列表。iPhone 根 Tab 点按、设置 push/按钮返回及 iPad 根页布局已检查。未保存/导出实际阅读内容作为夹具或报告附件。
- CUA 尝试平移、根 Tab 斜向拖动及系统边缘返回，但未能可靠观察到完整拖动识别；临时诊断也未捕获根 pan 开始事件，诊断已移除。工具未提供多指轨迹/持续按键能力。因此这些 UI 拖动项目、偏心捏合、多次反向、动画中重触、iPad 实际分屏 **未完成自动化验证，待人工检查**；不能用上述坐标和生命周期测试代替手感验收。真机帧率/掉帧、触控与妙控触控板手感 **未执行**；没有运行 Instruments。
- 本批仅修改 RootView、ReaderView、现有测试及本记录。未提交、未推送，等待完整 App 人工检查。

### 本批提交授权

- 用户确认“提交”。提交前再次核对 HEAD、工作区与暂存区，只有本批上述 4 个文件；沿用已记录的验证结果与人工检查限制，此次未重复测试。仅作本地提交，不推送。

## 2026-09-30：当前页优先、离线复用与长图预算

- 基线 `13bbdaee88856236e6d4e4b0c60eb27551baf41e`，分支 `codex/root-tab-resident-pages-v6`；开始时工作区干净。已执行 `git status --short --branch`、`git rev-parse HEAD`、`xcodebuild -list -project JMComic.xcodeproj`、`xcrun simctl list devices booted`，阅读 README、CONTRIBUTING、project.yml 与实际调用链。未 pull、切分支、清理工作区、修改签名/发布配置或提交。
- 调用链：`ReaderView → OnlinePageView → decodedPageImage → performDecodedPageLoad → prioritizedImageData → URLSession → ImageScrambler`；本地为 `localPageURLs → LocalPageView → 文件读取/栅格解码`；下载为普通 dataTask 回调 → `decodeAndStore → 文件/SQLite`，封面为 `ensureCoverCached → performCoverCache`。网络许可原本就会在收到数据后释放，未占用解码阶段；真正缺口是预取无独立优先级/使用者退出管理、像素解码无统一预算、本地页面反复读盘解码，以及下载封面最终提交仍在主线程。
- 新增小型阅读加载器，在线/本地共享缓存预算和解码准入。每个页面/预取持有独立使用权；预取可提升既有请求的队列和 URLSessionTask 优先级，不另发请求；最后一个使用者退出才取消任务。代次同时保护元数据、缓存、页面结果和章节加载。内存警告清空成品缓存并取消纯推测消费者，不误取消仍有页面等待的任务。
- 阅读会话集中维护前后窗口，默认各 2 页，设置范围 0…6；设置在“阅读预取”，与网络并发分开，说明受“显示说明文字”控制。移除原本逐页完成后继续发散预取的调用；翻远、换章、退出会取消过期窗口。近邻已实例化行和真正可见行共用同一加载结果，超出范围会释放行持有的图片。
- 保守默认：阅读源数据流水线最多 3 项，其中预留 1 个可见页位置；网络继续使用用户现有并发设置，并为可见页保留位置。图片后台解码最多 2 项，按在线/本地 16 B/像素、下载含编码 20 B/像素估算临时工作区；成品 LRU 最多 12 张/64 MiB，与已收到的压缩数据、工作区共同计入 192 MiB 软预算。超过软预算的单图独占，估算工作区超过 512 MiB 或异常大的输入明确可恢复失败，不降采样；不会永远等许可。下载编码结果等待串行落盘期间也持续计入预算。
- 以上是准入估算，**不是进程峰值内存硬上限**：URLSession 接收中的数据、UIKit 持有的可见图片、ImageIO 内部开销，以及既有独立封面缓存不等同于阅读 LRU。网络等待、解码等待、文件提交等待分别管理；没有根据这些测试宣称真机帧率或内存数值。
- 本地缓存键包含存储像素处理版本、规范化文件 URL、设备/inode、大小、mtime/ctime 纳秒信息；读盘、头信息和解码均后台执行，合并进行中的读取。替换后重新校验，删除/重新写入主动失效，回到前台重新验证文件版本；旧 JPEG 继续按原像素读取，不重解扰、不转换整库。缓存仅保留有限图片和 256 项尺寸元数据。
- 占位比例使用 ImageIO 头信息，在线复用已有响应、本地只读取所需文件头，不为尺寸完整解码/下载整章。尺寸到达时使用上一批的页内归一化锚点补偿，未新增逐帧 scrollTo 或另一套阅读器。
- 下载封面最终原子写入、索引登记、页面路径预留/旧文件处理、页面提交和删除进入同一后台串行队列；队列内校验 token/tombstone，删除结束前禁止重新加入。也修复章节元数据晚到后可能继续登记旧任务的问题。保留既有普通下载、并发控制和进度合并；文件扩展名/保真策略与上一批一致。

### 验证及实际命令

- 16 项不同的定向 XCTest 通过（新增 9 项，复用 7 项），没有运行全量测试或 Instruments。合成夹具覆盖共享提升/使用者取消、旧代次晚到、超时重试、前后窗口跳远退出、完整 128×8192 长图、两项解码上限与大图独占、等待取消、编码输出等待提交时的预算、本地替换逐像素核对/旧 JPEG/内存警告、封面删除后重下载与旧章节元数据晚到、占位尺寸变化页内锚点；没有使用账号凭据或实际漫画做夹具。
- `Artifacts/reading-scheduler/targeted.log/.xcresult`：iPhone 13 项通过；`boundaries.log/.xcresult`：iPhone 3 项通过；`ipad-final.log/.xcresult`：iPad 10 项通过；`commit-memory.log/.xcresult`：最后修改涉及的 iPhone 4 项通过。每份日志首段 `Command line invocation` 保留完整实际命令及所有 only-testing 参数。
- 首次 `build.log` 因 continuation 类型推断与 stat 调用失败，修正后 `build-fixed.log` 成功；最终 `complete-app-build.log` 成功，只有 AppIntents metadata 提示。测试日志存在 AttributeGraph cycle 提示；上一批 `Artifacts/gesture-focal/final-targeted.log` 已有同类提示，本批未以测试通过声称消除这些提示。

最后补测实际命令：

```sh
xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug \
  -destination 'platform=iOS Simulator,id=88E155ED-2CC4-4266-8137-148FD7FBB757' \
  -derivedDataPath build/reading-scheduler-tests \
  -resultBundlePath Artifacts/reading-scheduler/commit-memory.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:JMComicTests/JMComicTests/testDownloadEncodedOutputStaysBudgetedUntilCommit \
  -only-testing:JMComicTests/JMComicTests/testReadingLongImageDecodeBudgetAndRecoverableOversize \
  -only-testing:JMComicTests/JMComicTests/testLateChapterMetadataCannotRecreateDeletedDownload \
  -only-testing:JMComicTests/JMComicTests/testLateCoverCannotOverwriteDeleteAndRedownload \
  CODE_SIGNING_ALLOWED=NO test > Artifacts/reading-scheduler/commit-memory.log 2>&1
```

最终完整 App 构建/安装/启动（全部成功）：

```sh
xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/reading-scheduler-app \
  CODE_SIGNING_ALLOWED=NO build > Artifacts/reading-scheduler/complete-app-build.log 2>&1
xcrun simctl terminate 88E155ED-2CC4-4266-8137-148FD7FBB757 io.github.jmcomic.mobile
xcrun simctl install 88E155ED-2CC4-4266-8137-148FD7FBB757 /Users/othbradar/PycharmProjects/JMComic-iOS/build/reading-scheduler-app/Build/Products/Debug-iphonesimulator/JMComic.app
xcrun simctl launch 88E155ED-2CC4-4266-8137-148FD7FBB757 io.github.jmcomic.mobile
xcrun simctl terminate 467D92A6-2187-48A6-BF24-9824B48313B1 io.github.jmcomic.mobile
xcrun simctl install 467D92A6-2187-48A6-BF24-9824B48313B1 /Users/othbradar/PycharmProjects/JMComic-iOS/build/reading-scheduler-app/Build/Products/Debug-iphonesimulator/JMComic.app
xcrun simctl launch 467D92A6-2187-48A6-BF24-9824B48313B1 io.github.jmcomic.mobile
```

- 环境 Xcode 26.6 / iOS 26.5 Simulator；iPhone 17 Pro Max `88E155ED-2CC4-4266-8137-148FD7FBB757`、iPad Pro 11-inch (M5) `467D92A6-2187-48A6-BF24-9824B48313B1`。完整产物路径如上，bundle ID 仍为 `io.github.jmcomic.mobile`，这是 Simulator `.app`，不是 IPA。
- 安装详情、get_app_container 和 SHA-256 校验见 `delivery-install.log`。两端已安装主程序/debug dylib 与最终产物一致。覆盖安装使容器路径 UUID 改变；早先 `install.log` 的 `preserved=False` 仅比较路径字符串，不能据此认定数据丢失。最终再次安装前后，iPad 原 25 个下载文件的相对路径/大小清单一致（共 12,347,673 字节），iPhone 原无下载仍无下载；没有卸载或清数据。iPad 界面确认原登录状态、离线章节和阅读页仍可用。
- CUA smoke：iPad 设置预取 2→3→2、说明文字开关显示/隐藏并恢复原值；已打开既有离线连续阅读并观察图片显示，最终安装后再次打开同一章节。iPhone 首页与在线详情能够加载，详情按钮返回成功；两端启动正常。

### 待人工检查 / 未执行

- CUA 拖动没有可靠地产生 Simulator 滚动，部分底部导航/阅读控制在 AX 中不暴露且坐标点击未可靠生效。因此快速往返翻页、远距离跳转/换章、长图回看手感、iPhone 设置切换、在线阅读完整界面及同时下载时普通浏览的完整 UI smoke **未执行完成**，请人工检查；请求/解码/离线文件链路已按上文合成测试验证。
- 真机帧率、峰值内存、触控手感 **未执行**。本批不报告性能提升百分比，不把模拟器或编译结果当成真机验收。
- `git diff --check` 通过；本批未暂存、未提交、未推送。交付完整 App，等待人工检查。

### 本批提交授权

- 用户确认“那就提交”。提交前再次核对 HEAD、工作区、暂存区和已完成的构建/测试/安装日志；暂存区原为空，范围仅为本批 11 个文件。沿用上述验证，此次未重复构建或运行测试；只作本地提交，不推送。

## 2026-09-30：本地管理、隐私与轻量备份 / CBZ

- 基线 `a0de9b71e4cdbf9a0adca500ae8d4d6ac683f215`，`codex/root-tab-resident-pages-v6`；开始时工作区干净。已核对 `git status --short --branch`、`git rev-parse HEAD`、README、CONTRIBUTING、project.yml、`xcodebuild -list -project JMComic.xcodeproj`、`xcrun simctl list devices booted` 和实际调用链。没有 pull、切分支、reset、卸载或清数据。真实入口仍为 RootView，新保护层保持其身份和导航结构。
- 真实存储边界：Documents/download 为原图，Documents/cache 为下载/收藏/历史共享持久封面，Documents/database 为必要索引；这三类不由“清理缓存”删除。后台空间统计合并进行中计算、缓存 30 秒，按设备/inode 去重并跳过符号链接；单独列出下载、必要索引/封面、HTTP 缓存和实际导出临时目录。默认清理只走 URLCache API 与有界内存图片缓存；活跃读者继续使用当前结果，清理前请求不能重新登记旧缓存。下载删除复用原串行提交队列与 tombstone，并单独确认。
- 标签：仅使用 API 模型实际携带的 tags；未发现可靠服务端排除参数，不逐条获取详情。兼容 Unicode、空白、大小写的完整标签匹配，最多 200 条；设置可新增/移除并持久化，覆盖发现/最新、相关推荐与搜索，收藏/历史/下载保持可见。缺标签条目保留并明确说明覆盖限制。搜索一次主动操作最多补 3 页，支持继续追加、原始重复页/空页终止；过滤后显示已载入数量，不伪报精确总数。发现原本无追加分页，保留现有刷新方式。
- 应用锁：默认关闭，启停均先调用 LocalAuthentication 的 deviceOwnerAuthentication，可由系统选择生物识别或设备密码。失败/取消保持原锁态，可重试；只有 background 更新认证代次并重新锁定，普通 inactive 仅遮挡。窗口内独立高层 UIWindow 覆盖根页、阅读器和 sheet，旧回调不能解锁新代次，无静态跨窗口引用；设置变更通知其他场景。应用切换器始终遮挡，不宣称数据库/图片加密，不退出登录或删下载。
- 备份：schemaVersion=1 的 JSON，12 MiB、5,000 本书、50,000 章进度/书目章节及字段类型/时间/数量限制，白名单导出非敏感设置。明确不含认证信息、Cookie、Token、Keychain、权限、应用锁状态、图片或原设备文件路径。导入先预检展示，再安全合并：章节进度取较新时间；无可靠更新时间的现有设置优先；标签与书目合并保留现有内容。先原子发布可重放导入记录，发布失败不改变状态，崩溃后幂等恢复；不向下载表导入“完成”记录。恢复书目单独标明“资料，不代表已下载”，不自动下载。进度在保留旧最近章节接口及 300 ms 合并写入的基础上增加各章存储，旧数据可读。
- 导出：当前仓库没有用户所述的既有完整图片分享入口，因此补充复用的系统文件分享宿主。下载书籍菜单、离线章节上下文菜单和章节列表工具栏接入 CBZ。后台预检文件版本、实际格式与头尺寸；按章节 sort/id、补零页序和安全名称组织，同名章增加稳定后缀。ZIP STORE 以 64 KiB 块复制现有 PNG/JPEG 等原字节，无联网/重编码；经典 ZIP 上限约 4 GiB、50,000 页，超过时明确失败。预检与写入可取消，源文件变化使整次导出失败并移除半成品，进度通知有界。分享期间租约保护文件，完成/关闭后保留 10 分钟再清理，进程中断残留按 24 小时过期清理。
- 完整范围限制：旧下载索引未保存完整服务端章节目录；“导出本地全部章节”明确提示无法保证网站整本齐全，需同意本地范围，文件名前缀“部分-”。单章所有预期页存在时可完整导出；缺页必须另行同意部分导出。旧 JPEG 保留现有质量，不称为无损原图。

### 验证与实际命令

- 20 项不同的定向 XCTest 最终通过（新增 15、复用 5）：清理期间旧请求/图片缓存代次、清理后本地图片与进度、硬链接去重与统计限频、标签持久化与最多 3 页、认证启用取消/成功/失败/自身 inactive/旧回调、旧进度迁移与各章合并、备份白名单/类型/版本/大小/数量/写入失败/无图片元数据、导出顺序/格式/缺页/取消/替换/临时文件租约，以及既有共享加载、文件替换、删除后重下载和旧 JPEG。夹具仅使用生成图案、虚构书目、独立 UserDefaults suite 与临时 SQLite。
- `Artifacts/local-management/tests-iphone.log`：13 项通过；`regression-iphone.log`：8 项通过（3 项本批、5 项既有）；`ipad-share-fixed.log`、`ipad-wrapper.log`：各 1 项通过，含真实 iPad 系统分享呈现、宿主锚点、取消回调后文件保留及高层遮挡窗口。没有跑全量测试或 Instruments。
- 调试过程如实记录：最初新增文件误入测试 target / Components group，修正 Xcode 工程后构建成功；最初 only-testing 使用不支持的前缀选择，实际 0 项，未算验证。随后 13 项首轮有 3 个夹具失败（比较包含系统全局域的 UserDefaults、页全局编号从 0 起、分享宿主尚未挂窗），修正后通过。iPad 分享实际发现自身视图作为 popover 锚点导致布局循环，已改为独立宿主锚点；失败日志 `tests-ipad.log` 保留，修复及真实宿主复测通过。
- 定向测试命令采用 `xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug -sdk iphonesimulator -destination 'id=<上述模拟器 UUID>' -derivedDataPath Artifacts/local-management/DerivedData -parallel-testing-enabled NO -only-testing:JMComicTests/JMComicTests/<具体方法> test`。每份日志开头有完整实际参数；初始 13 项与补测的精确参数另存 `test-command.txt`、`regression-command.txt`、`ipad-command.txt`，iPad 修复/宿主测试使用各自同名方法。
- 独立导出核对：对测试打印的 `SYNTHETIC_EXPORT_FIXTURE` 目录，使用 Python `zipfile.ZipFile.testzip()/namelist()/read()` 解包，逐项与源文件字节比较，再用 `sips -g pixelWidth -g pixelHeight` 检查尺寸及 PNG/JPEG 魔数。4 页 / 2 章顺序、CRC、原始字节及 31×173 尺寸均一致；部分包仅 1 页。结果 `Artifacts/local-management/zip-verification.json`。未导出真实阅读内容作为夹具或报告附件。

最终完整 App 构建和覆盖安装均成功（Xcode 26.6 / iOS 26.5 Simulator）：

```sh
xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/local-management-app \
  CODE_SIGNING_ALLOWED=NO build > Artifacts/local-management/complete-app-build.log 2>&1
xcrun simctl terminate 88E155ED-2CC4-4266-8137-148FD7FBB757 io.github.jmcomic.mobile
xcrun simctl install 88E155ED-2CC4-4266-8137-148FD7FBB757 /Users/othbradar/PycharmProjects/JMComic-iOS/build/local-management-app/Build/Products/Debug-iphonesimulator/JMComic.app
xcrun simctl launch 88E155ED-2CC4-4266-8137-148FD7FBB757 io.github.jmcomic.mobile
xcrun simctl terminate 467D92A6-2187-48A6-BF24-9824B48313B1 io.github.jmcomic.mobile
xcrun simctl install 467D92A6-2187-48A6-BF24-9824B48313B1 /Users/othbradar/PycharmProjects/JMComic-iOS/build/local-management-app/Build/Products/Debug-iphonesimulator/JMComic.app
xcrun simctl launch 467D92A6-2187-48A6-BF24-9824B48313B1 io.github.jmcomic.mobile
```

- iPhone 17 Pro Max `88E155ED-2CC4-4266-8137-148FD7FBB757`；iPad Pro 11-inch (M5) `467D92A6-2187-48A6-BF24-9824B48313B1`。完整产物路径如上，bundle ID 保持 `io.github.jmcomic.mobile`；这是 Simulator `.app`，不是 IPA。没有改签名/发布配置或上传。
- `final-install.log` 保存上述命令、两端 `simctl get_app_container … data/app` 和主程序/debug dylib SHA-256 比对结果，均与最终产物相同。数据容器路径 UUID 有变化，不能称“容器未变”；iPad 原 25 个下载文件、12,347,673 字节及相对路径/大小摘要一致，iPhone 原无下载仍无下载。清缓存后也未改变这些文件。`final-install-checks.json` 为汇总。没有卸载、清空账号/进度或下载。
- CUA smoke：两端最终完整 App 启动、发现内容加载；iPad 原登录状态保留；设置分类统计与清理按钮可用（下载 12.3 MB 保留），合成屏蔽标签添加→返回重入仍在→移除恢复原值；清理后进入离线连续阅读，控制栏显示恢复到 12/25。下载菜单导出预检实际识别 25 页、缺失 0 页，未同意本地范围时按钮禁用。备份入口、系统文件选择器打开及 Escape 取消已验证。iPad 应用切换器卡片实际仅显示锁图标/JMComic 遮挡页。

### 待人工检查 / 未执行

- LocalAuthentication 在 iPad Simulator 可弹出系统设备密码页面；未输入/设置任何密码，其取消操作未被 CUA 可靠驱动，使用 `simctl terminate` / `launch` 原 bundle 返回，启用状态保持关闭。成功/失败/取消/旧回调已通过可控认证替身验证，真实 Face ID / Touch ID / 设备密码成功与回退、实际锁定后跨应用/深链、多窗口、权限弹窗需真机人工验证，未冒充系统认证通过。
- iPhone 底部 Tab 的 AX 不暴露子按钮，坐标点击未可靠生效，iPhone 新设置细节 UI smoke 未执行完成。系统文件提供者上的完整导入/分享保存流程、实际大书导出中取消、旋转/分屏下分享仍需人工检查；导入合并/坏文件/取消/文件正确性已按上述合成回归验证。没有上传或发送文件给第三方。
- 真机帧率、峰值内存、触控手感未执行；没有性能提升百分比或“满帧”声明。`git diff --check` 通过。本批未暂存、未提交、未推送，等待完整 App 人工检查。


### 本批提交与 1.0.2 发布授权

- 用户确认本批并明确授权提交、推送、构建 1.0.2 IPA 和发布更新说明。提交前再次核对工作区、暂存区、远端 refs 及现有发布方式；只有本批文件，未暂存其他改动。沿用上文 20 项定向回归和完整 App 验证，本次提交阶段未重复运行测试。
- 远端 main 位于 `5aa3a29`（v1.0.1），是当前分支祖先；采用快进推送，不切换/重置本地分支。现有发布为 iOS 18+、arm64 未签名 IPA，继续此方式，不使用个人证书或 Provisioning Profile。新版本计划为 1.0.2 / build 23。

### 1.0.2 真机 IPA 构建

- 本地管理提交 `73bc471`，`git push origin HEAD:main` 成功，远端由 `5aa3a29` 快进至该提交。版本源 `project.yml` 与 Xcode 工程同步更新为 1.0.2 / build 23；bundle ID 仍为 `io.github.jmcomic.mobile`。
- 实际执行 `xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Release -destination 'generic/platform=iOS' -sdk iphoneos -derivedDataPath Artifacts/v1.0.2/DerivedData CODE_SIGNING_ALLOWED=NO build > Artifacts/v1.0.2/build.log 2>&1`，结果 `BUILD SUCCEEDED`。
- 产物 `/Users/othbradar/PycharmProjects/JMComic-iOS/Artifacts/v1.0.2/DerivedData/Build/Products/Release-iphoneos/JMComic.app`；`lipo -archs` 为 arm64，`vtool -show-build` 为 IOS / minos 18.0 / SDK 26.5。`codesign -dv` 确认未签名，未加入证书或 Provisioning Profile。
- 使用 `ditto` 复制到 `Artifacts/v1.0.2/package/Payload/JMComic.app`，再以 Python `zipfile.ZipFile(..., 'w', compression=ZIP_DEFLATED, compresslevel=9)` 逐文件打包（不带 AppleDouble / 扩展属性文件）。`testzip()`、plist 版本/平台、主程序可执行权限及全部 7 个包内文件与构建产物字节比对通过。
- IPA：`/Users/othbradar/PycharmProjects/JMComic-iOS/Artifacts/v1.0.2/JMComic-v1.0.2-iOS18-arm64-UNSIGNED.ipa`，2,418,352 字节，SHA-256 `760ce49983357ff2f35c61617c618913d5924ffaf56bae25528fdb280a32c2ef`。汇总 `Artifacts/v1.0.2/verification.json`；发布说明与校验文件在同目录。该包为真机 iOS 构建，不是 Simulator App。
- 本次仅版本元数据变化，沿用本批及前三批定向测试/模拟器验证，未重复运行测试；真机安装、身份验证及性能测试未执行。发布说明包含已实现功能、修复、实际过滤/备份/导出限制和未签名安装方式。

### 1.0.2 发布结果

- 版本提交 `4c47ad746347ab56c7a116183a4c202c4c66883d` 已通过 `git push origin HEAD:main` 快进推送。执行 `git tag -a v1.0.2 -m 'JMComic 1.0.2 (23)'`、`git push origin refs/tags/v1.0.2` 成功；`git ls-remote origin refs/heads/main refs/tags/v1.0.2 'refs/tags/v1.0.2^{}'` 确认标签指向该版本提交。
- GitHub CLI 未登录；使用已登录的 Chrome 仓库发布表单选择现有 v1.0.2 标签、填写更新说明、上传上述 IPA 并发布为 Latest。公开发布页：<https://github.com/othbradar/JMComic-iOS/releases/tag/v1.0.2>，发布时间 2026-09-30T07:23:22Z。
- 实际执行 `curl -fsSL 'https://api.github.com/repos/othbradar/JMComic-iOS/releases/tags/v1.0.2' -o Artifacts/v1.0.2/published-release.json` 及 `/releases/latest` 核验：非草稿、非预发布，Latest 为 v1.0.2；公开正文与本地 `RELEASE_NOTES.md` 标准化换行后完全一致。
- 附件 ID `600291137`，状态 uploaded；服务器记录大小 2,418,352 字节，digest `sha256:760ce49983357ff2f35c61617c618913d5924ffaf56bae25528fdb280a32c2ef`，均与本地 IPA 一致。下载地址：<https://github.com/othbradar/JMComic-iOS/releases/download/v1.0.2/JMComic-v1.0.2-iOS18-arm64-UNSIGNED.ipa>。仅发布构建包，不含账号、下载内容、测试数据库或个人签名材料。

## 2026-09-30：iOS 27 实机根 Tab 横滑白屏修复候选

- 用户报告：原版模拟器正常；实机系统最终更正为 **iOS 27**。初装最初几次横滑正常，触发后横滑几乎必定只剩背景和底栏；直接点击底栏可恢复。截图显示中途两页仍可见、松手完成后内容区消失。本机只有 iOS 26.5 Simulator，**没有复现用户 iOS 27 实机故障，未宣称实机已修复**。
- 基线 `da3623327479078711b8660f13536b290a093530`，当前分支 `codex/root-tab-resident-pages-v6`；`git status --short --branch` 干净。已核对 README、CONTRIBUTING、project.yml、`xcodebuild -list -project JMComic.xcodeproj`、`xcrun simctl list devices booted` / `list runtimes`。入口 `JMComicApp → ProtectedAppRoot → RootView → RootResidentPages`；LegacyRootView 未使用、未修改。
- 定位的代码缺陷：RootResidentPageHostStore 把完整页面宿主插入 selectedView 的内部祖先容器，假定它在原生 Tab 切换中永远保留；内部容器退出时，子层 zPosition=100 也无法保住内容。新受控用例在旧代码下移除该容器，实际断言 host.window 丢失；这仅证明该生命周期缺陷，不能等同于已拿到 iOS 27 实机调用栈。
- 小范围修正：页面宿主由窗口内对应 UITabBarController 根视图上的自有 MountView 持有，与可替换的内容容器并列，使用普通兄弟顺序保留系统标签栏/侧栏在上方。切换选中项、原生切换完成和尺寸变化时合并校正；只有尺寸/层级确实改变才写入，不再从 locator.layoutSubviews 强制祖先 layoutIfNeeded / 每次 setNeedsLayout。旧页的异步顶部 inset 回调不能更新新选中页。保留同一个 UIHostingController、五个常驻页、导航路径、图片策略及弹簧手势；未添加额外 tab child、静态全局宿主或重置页面身份。
- Apple 文档核对：<https://developer.apple.com/documentation/uikit/uitabbarcontroller>、<https://developer.apple.com/documentation/uikit/uitabbarcontroller/contentlayoutguide>。iOS 27 相关论坛报告涉及旧 shouldSelect delegate，当前真实入口没有使用该 delegate，因此没有套用该线索。

### 实际验证和产物

- 定向回归：iPhone 6 项通过（2 个新宿主回归、4 个既有锁轴/取消/反向/生命周期用例），iPad 重复 2 个宿主回归通过。真实 SwiftUI TabView 的 14 次首次/重复/反向选中与尺寸变化中，同一宿主持续可见、可 hitTest；合成 StateObject 构造 / onAppear / task 均为 1 次。另一个用例覆盖旧内容容器被移除。仅合成文字和色块，无真实账号/漫画夹具。
- 实际命令：`xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug -sdk iphonesimulator -destination 'id=<下列 UUID>' -derivedDataPath Artifacts/root-host-fix/DerivedData -parallel-testing-enabled NO -only-testing:JMComicTests/JMComicTests/<方法名> test`。方法完整参数与结果位于 `Artifacts/root-host-fix/tests-iphone-fixed.log`、`tests-ipad.log` 的开头。`before-fix.log` 保留旧实现的 2 条失败断言；首轮 `tests-iphone.log` 因合成计数器缺 MainActor 标记编译失败，补齐后上述测试通过。不把旧实现的受控失败称作实机复现。
- 完整 Simulator App：`xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/root-host-fix CODE_SIGNING_ALLOWED=NO build > Artifacts/root-host-fix/simulator-build.log 2>&1` → BUILD SUCCEEDED。
- 对 iPhone 17 Pro Max `88E155ED-2CC4-4266-8137-148FD7FBB757`、iPad Pro 11-inch (M5) `467D92A6-2187-48A6-BF24-9824B48313B1` 实际依次执行 `xcrun simctl terminate <UUID> io.github.jmcomic.mobile`、`install <UUID> /Users/othbradar/PycharmProjects/JMComic-iOS/build/root-host-fix/Build/Products/Debug-iphonesimulator/JMComic.app`、`launch <UUID> io.github.jmcomic.mobile`。命令与输出 `Artifacts/root-host-fix/install.log`。两端二进制摘要与最终产物一致；未卸载/清数据。容器 UUID 改变，iPad 25 个原下载文件/12,347,673 字节的相对路径和大小摘要一致；iPhone 原无下载仍无下载。汇总 `install-verification.json`。
- CUA 基本检查：两端完整 App 启动、发现内容和系统 Tab 栏可见；iPad 点击搜索显示标题、搜索框和空状态，侧栏可展开/收起，未被新宿主遮住。iPhone CUA 两次 drag 没有产生可确认的切换，完整触摸横滑 smoke **未执行完成**；没有将模拟器无白屏计作 iOS 27 实机通过。
- 真机候选：`xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Release -destination 'generic/platform=iOS' -sdk iphoneos -derivedDataPath Artifacts/root-host-fix/Device CODE_SIGNING_ALLOWED=NO build > Artifacts/root-host-fix/device-build.log 2>&1` → BUILD SUCCEEDED。沿用 1.0.2（23）/ iOS 18+ / `io.github.jmcomic.mobile`，未改签名配置。`lipo -archs`=arm64，`vtool -show-build`=IOS，SDK 26.5，`codesign -dv` 确认未签名。
- 使用 Python zipfile 将 Release-iphoneos/JMComic.app 逐文件打入 Payload（忽略 AppleDouble），验证 CRC、版本、平台、主程序可执行权限及源文件字节一致。候选 IPA：`/Users/othbradar/PycharmProjects/JMComic-iOS/Artifacts/root-host-fix/JMComic-1.0.2-tab-host-fix-UNSIGNED.ipa`，2,423,663 字节，SHA-256 `424074439369627ccae07325ad7e15d63443673558d857f169af2d26c8435027`。汇总 `ipa-verification.json`。这是未发布的实机候选，不是 Simulator .app 改后缀。
- 待用户实机检查：用原签名身份/原应用标识覆盖安装候选包，在 iOS 27 连续往返横滑、首次与重复访问所有 Tab、点击底栏后再滑动、拖动反向/取消，以及二级页返回后再滑动。无需卸载。实机白屏是否消失、触感/性能尚未验证；未执行真机安装或 iOS 27 runtime 测试。本批未提交、未推送、未替换公开 1.0.2 Release，等待人工验收。

## 2026-09-30：收藏夹数量更新与连续阅读回跳

- 用户已在 iOS 27 实机确认上一节的根 Tab 白屏候选修复有效；该未提交修改完整保留。本批起点 HEAD 仍为 `da3623327479078711b8660f13536b290a093530`，已有 RootView、测试及本记录修改，未覆盖或提交。重新核对 git status/HEAD、真实 scheme/构建入口和两端模拟器；沿用此前已读的 README、CONTRIBUTING、project.yml。
- 收藏数量：确认 `FavoriteFolderContentModel → FavoriteCacheStore → SQLite` 会更新文件夹 total，但常驻 `FavoritesViewModel.folders` 只在账户任务加载时更新；手机 `.badge(Int)` 又会隐藏 0，使首次未带 count 的文件夹即使已完成内容加载仍不显示数字。现于缓存事务成功后通知小型文件夹元数据快照，在主线程更新对应账号的常驻列表；数量不变不重绘，退出/切换账号拒绝旧账号通知。手机使用文本 badge，也能显示真实空文件夹的 0。保留数据库对缺失 count 的元数据不覆盖已知总数的规则；没有添加逐文件夹请求或重拉全库，没有更改收藏远端接口/数据库结构。
- 阅读回跳：确认 `pageSizeWillChange` 可在拖动/惯性期间重新设置旧 anchor，且完成尺寸补偿后 anchor 仍被后续每次 geometryChanged 使用，覆盖新 contentOffset。新增两条测试在旧实现真实失败：下滑 2500/2580/2660 被拉回 2400；拖动/惯性中 2450 被拉回 2300。此为受控代码路径复现，不宣称复现了实机所有时序。
- 修正：跟踪 scroll phase，并同时检查 UIScrollView 的 tracking/dragging/decelerating；滚动中不重新启动图片尺寸的被动锚点补偿。排队补偿发现 contentOffset 已变化即放弃旧位置；完成缩放后仅在 offset 仍等于自己施加的值时保留锚点以吸收晚到布局。新懒加载行的首次测量、当前锚点之后的行不触发无关补偿。静止时图片尺寸补偿、偏心缩放/复位、旋转位置逻辑仍保留，没有降画质、关闭预取或重新构建阅读器。

### 验证 / 交付

- `Artifacts/favorites-reader-fix/before-fix.log`：两个新回跳测试在旧代码下失败（5 条 offset 断言），作为修复前证据。最终 `tests-iphone.log` 中 **8 项定向 XCTest 通过**：4 项新增（数量提交后即时更新/保留已知总数/变为空/账号隔离；补偿后的继续下滑；拖动与惯性图片到达；SwiftUI 回调晚于 native offset）与 4 项既有（静止占位锚点、偏心缩放/取消/尺寸改变、真实懒布局缩放焦点与有界行、收藏 SQLite 分页/账户隔离）。夹具仅合成页几何和独立临时数据库，无真实账号、凭据或私密漫画。
- 测试命令：`xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug -sdk iphonesimulator -destination 'id=88E155ED-2CC4-4266-8137-148FD7FBB757' -derivedDataPath Artifacts/root-host-fix/DerivedData -parallel-testing-enabled NO -only-testing:JMComicTests/JMComicTests/<具体方法> test`；两份日志开头保留完整方法参数。没有跑全量测试或 Instruments，本批 iPad XCTest 未执行。
- 完整 Simulator 构建：`xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/root-host-fix CODE_SIGNING_ALLOWED=NO build > Artifacts/favorites-reader-fix/simulator-build.log 2>&1` → BUILD SUCCEEDED。
- 真机 Release 构建：`xcodebuild -project JMComic.xcodeproj -scheme JMComic -configuration Release -destination 'generic/platform=iOS' -sdk iphoneos -derivedDataPath Artifacts/root-host-fix/Device CODE_SIGNING_ALLOWED=NO build > Artifacts/favorites-reader-fix/device-build.log 2>&1` → BUILD SUCCEEDED。保持 1.0.2（23）、`io.github.jmcomic.mobile` 和原签名配置；仅构建命令使用 CODE_SIGNING_ALLOWED=NO。
- 对 iPhone 17 Pro Max `88E155ED-2CC4-4266-8137-148FD7FBB757`、iPad Pro 11-inch (M5) `467D92A6-2187-48A6-BF24-9824B48313B1`，实际逐个执行 `simctl terminate`、`install <UUID> /Users/othbradar/PycharmProjects/JMComic-iOS/build/root-host-fix/Build/Products/Debug-iphonesimulator/JMComic.app`、`launch` 原 bundle ID；完整命令/输出 `Artifacts/favorites-reader-fix/install.log`。两端主程序/debug dylib 与产物摘要一致；没有卸载或清数据，容器 UUID 改变。iPad 25 个下载文件/12,347,673 字节相对路径与大小摘要保留，iPhone 原无下载仍无下载，见 `install-verification.json`。
- CUA：iPad 完整 App 发现页启动及内容载入，点击收藏后既有收藏内容可见。iPhone 本批仅执行启动和安装产物校验；手机收藏夹计数 UI、长距离实际手势连续阅读/惯性与缩放后的手感未执行，留待 iOS 27 实机检查。没有用模拟器或代码测试宣称实机全部通过。
- 实机候选包：`/Users/othbradar/PycharmProjects/JMComic-iOS/Artifacts/favorites-reader-fix/JMComic-1.0.2-favorites-reader-fix-UNSIGNED.ipa`。包含上一节已获实机确认的 Tab 白屏修复及本批两项修改。Python zipfile 将 Release-iphoneos/JMComic.app 逐文件装入 Payload；CRC、plist 版本/bundle/platform、可执行权限、包内与构建文件字节一致通过。`lipo -archs`=arm64，`vtool -show-build`=IOS / SDK 26.5，`codesign -dv`=未签名。大小 2,429,090 字节，SHA-256 `ab9101d1c9fc907047ae7a7fa973911c1786b23008492fd37d6893e3780cf985`，汇总 `ipa-verification.json`。不是 Simulator .app 改后缀；未替换公开 Release。
- 待人工检查：使用原签名身份/原 bundle ID 覆盖安装候选包；进入一个自定义收藏夹加载后返回检查数量，重新打开仍应保留；连续阅读普通下滑、图片逐步加载、松手惯性、缩放后平移/复位。无需卸载清数据。`git diff --check` 通过；本批及上一节均未提交/推送，等用户验收。

### 实机确认与替换 1.0.2 授权

- 用户已明确确认根 Tab 白屏、收藏夹计数和连续阅读回跳修复，并授权提交、推送 GitHub、用新版 IPA 替换公开 1.0.2 附件。实机反馈为用户提供，未扩大为帧率/内存或全部流程验证。
- 提交前 `git status --short`、`git diff --check`、`git ls-remote origin refs/heads/main refs/tags/v1.0.2 'refs/tags/v1.0.2^{}'` 核对：只有本次两组修复的 5 个文件；远端 main 仍为 `da36233`，采用快进推送。保留原 v1.0.2 标签；修订附件对应本次修复提交，见下方发布记录。
- 已确认的候选 IPA 原路径文件在发布时已不在项目内；保留的 Release-iphoneos/JMComic.app 仍完整。使用与前次相同的 Python zipfile（排序逐文件、DEFLATED level 9）重新打包到 `Artifacts/favorites-reader-fix/release/JMComic-v1.0.2-iOS18-arm64-UNSIGNED.ipa`，得到与已验收候选**完全相同**的 2,429,090 字节和 SHA-256 `ab9101d1c9fc907047ae7a7fa973911c1786b23008492fd37d6893e3780cf985`；CRC、7 个包内文件逐一对比及 plist 校验通过。未重新编译或修改程序，保持 1.0.2（23）/ 原 bundle ID / arm64 未签名。
- 本次发布步骤沿用已记录的定向 XCTest、完整 App 构建安装及用户实机确认；未重复运行测试。`gh auth status` 未登录，使用已有 Chrome 登录会话更新同一发布页，不提取凭据。

### 1.0.2 附件替换结果

- 修复提交 `381699231e50739fb5bbc95df27abcc5635a74c9` 已通过 `git push origin HEAD:main` 快进推送（`da36233..3816992`）。只提交 RootView、FavoritesView、ReaderView、对应定向测试与本记录；不含构建产物或私密数据。
- 用户随后明确要求发布页不新增这次修复说明、只更新 SHA-256。已遵守：标题仍为 `JMComic 1.0.2`，正文经标准化换行/末尾空白后与原正文仅摘要不同；没有新增白屏等说明。原标签及自动生成源码包仍对应初始 1.0.2；本次 IPA 对应上面的 `3816992` 修复提交。
- 通过已登录 Chrome 的原发布编辑页替换同名 IPA 并保存。Release ID 仍为 `399804002`、Latest 为 v1.0.2，非草稿/非预发布。新附件 ID `600440691`，uploaded，2,429,090 字节；旧附件 ID 已不在发布资产列表，仅保留一个新版 IPA。原旧包仍保留在本地 Artifacts/v1.0.2，未清理工作区文件。
- 实际执行 `curl -fsSL https://api.github.com/repos/othbradar/JMComic-iOS/releases/tags/v1.0.2` 和 `/releases/latest`，保存为 `Artifacts/favorites-reader-fix/release-after-replacement.json`、`release-latest.json`；核对标题、正文、附件数量/状态/大小/digest。
- 实际执行 `curl -fL --max-time 60 --retry 1 https://github.com/othbradar/JMComic-iOS/releases/download/v1.0.2/JMComic-v1.0.2-iOS18-arm64-UNSIGNED.ipa -o Artifacts/favorites-reader-fix/release/downloaded-verification.ipa` 及 `shasum -a 256`，公开下载文件 SHA-256 为 `ab9101d1c9fc907047ae7a7fa973911c1786b23008492fd37d6893e3780cf985`，与已验收候选、本地发布包和 GitHub digest 完全一致；ZIP CRC 通过。汇总 `Artifacts/favorites-reader-fix/release-verification.json`。
- 发布页：<https://github.com/othbradar/JMComic-iOS/releases/tag/v1.0.2>。本次未改版本/签名配置，未再次安装或重跑测试。
