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
