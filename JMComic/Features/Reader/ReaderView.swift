import SwiftUI
import UIKit

private enum ReaderMode: String, CaseIterable {
    case vertical = "连续"
    case paged = "分页"
}

/// 阅读器边缘返回与缩放的统一交互参数。独立成纯函数后可以在不启动 UI 的
/// 情况下验证手势阈值，避免纵向滚动或分页翻页被误判为退出。
enum ReaderInteractionPolicy {
    static let edgeActivationWidth: CGFloat = 36
    static let minimumDismissDistance: CGFloat = 96
    static let maximumZoomScale: CGFloat = 5
    static let continuousHorizontalActivationScale: CGFloat = 1.01

    static func shouldDismissFromLeftEdge(
        controlsVisible: Bool,
        startX: CGFloat,
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> Bool {
        guard controlsVisible, startX >= 0, startX <= edgeActivationWidth else { return false }
        guard translation.width > 0 else { return false }

        // 必须是明显水平向右的手势；纵向阅读中轻微向右偏移不会退出。
        guard translation.width > abs(translation.height) * 1.25 else { return false }

        let projectedDistance = max(translation.width, predictedEndTranslation.width)
        return projectedDistance >= minimumDismissDistance
    }

    static func clampedZoomScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, 1), maximumZoomScale)
    }

    /// Continuous mode changes the real layout width instead of applying a
    /// visual transform to an already-clipped ScrollView viewport.
    static func continuousContentWidth(
        viewportWidth: CGFloat,
        scale: CGFloat,
        maximumBaseWidth: CGFloat = 1_200
    ) -> CGFloat {
        min(max(1, viewportWidth), maximumBaseWidth) * clampedZoomScale(scale)
    }

    /// At the natural reading size the chapter is strictly vertical. This is
    /// deliberately separate from the content-width calculation: declaring a
    /// two-axis ScrollView at 100% makes UIKit accept horizontal rubber-banding
    /// even though the content is only as wide as the screen.
    static func continuousHorizontalScrollingEnabled(scale: CGFloat) -> Bool {
        clampedZoomScale(scale) > continuousHorizontalActivationScale
    }
}

/// 统一的阅读器入口。在 iPad 上从多列导航中 push Reader 只会替换详情列，
/// fullScreenCover 则会覆盖整个应用窗口，包括根 TabView 与收藏夹侧栏。
struct ReaderPresentationLink<Label: View>: View {
    let comic: ComicSummary
    let chapter: Chapter
    private let label: Label
    @State private var isPresented = false

    init(
        comic: ComicSummary,
        chapter: Chapter,
        @ViewBuilder label: () -> Label
    ) {
        self.comic = comic
        self.chapter = chapter
        self.label = label()
    }

    var body: some View {
        Button { isPresented = true } label: {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .fullScreenCover(isPresented: $isPresented) {
            FullScreenReaderContainer(comic: comic, chapter: chapter)
        }
    }
}

private struct FullScreenReaderContainer: View {
    @Environment(\.dismiss) private var dismiss
    let comic: ComicSummary
    let chapter: Chapter
    @State private var controlsVisible = true
    @State private var pageIsZoomed = false

    var body: some View {
        NavigationStack {
            ReaderView(
                comic: comic,
                chapter: chapter,
                controlsVisible: $controlsVisible,
                pageIsZoomed: $pageIsZoomed
            )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.backward")
                        }
                        .accessibilityLabel("关闭阅读器")
                    }
                }
        }
        .preferredColorScheme(.dark)
        // fullScreenCover 没有可 pop 的上一层，因此在最外层补上左边缘退出。
        // 只有控件显示时才启用；即使图片已放大，用户明确唤出
        // 返回按钮后仍可从左边缘退出。沉浸阅读时完全不参与手势竞争。
        .modifier(ReaderEdgeDismissModifier(
            isEnabled: controlsVisible,
            onDismiss: dismiss.callAsFunction
        ))
        .interactiveDismissDisabled()
    }
}

private struct ReaderEdgeDismissModifier: ViewModifier {
    let isEnabled: Bool
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        // 手势结构始终不变，显隐控件时只切换 GestureMask，不会重建
        // NavigationStack 或丢失当前页码。
        content.simultaneousGesture(
            DragGesture(minimumDistance: 14, coordinateSpace: .global)
                .onEnded { value in
                    guard ReaderInteractionPolicy.shouldDismissFromLeftEdge(
                        controlsVisible: isEnabled,
                        startX: value.startLocation.x,
                        translation: value.translation,
                        predictedEndTranslation: value.predictedEndTranslation
                    ) else { return }
                    onDismiss()
                },
            including: isEnabled ? .all : .none
        )
    }
}

struct ReaderView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var progressStore: ReadingProgressStore
    @EnvironmentObject private var history: ReadingHistoryStore
    @Environment(\.readerIsPresented) private var readerIsPresented
    let comic: ComicSummary
    let chapter: Chapter
    @State private var detail: ChapterDetail?
    @State private var localURLs: [URL] = []
    @State private var mode: ReaderMode = .vertical
    @State private var currentPage = 0
    @State private var continuousScrollPosition: Int?
    @State private var continuousPageTrackingEnabled = false
    @State private var pendingContinuousRestorePage: Int?
    @State private var pendingRestorePageIsVisible = false
    @State private var error: String?
    @State private var continuousZoomScale: CGFloat = 1
    @State private var continuousMagnificationStartScale: CGFloat = 1
    @State private var continuousMagnificationIsActive = false
    @Binding private var controlsVisible: Bool
    @Binding private var pageIsZoomed: Bool

    init(
        comic: ComicSummary,
        chapter: Chapter,
        controlsVisible: Binding<Bool>,
        pageIsZoomed: Binding<Bool>
    ) {
        self.comic = comic
        self.chapter = chapter
        _controlsVisible = controlsVisible
        _pageIsZoomed = pageIsZoomed
    }

    private var pageCount: Int { localURLs.isEmpty ? (detail?.images.count ?? 0) : localURLs.count }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !localURLs.isEmpty {
                readerContent { index in
                    LocalPageView(url: localURLs[index])
                }
            } else if let detail {
                readerContent { index in
                    OnlinePageView(chapter: detail, index: index)
                }
            } else if let error {
                ContentUnavailableView("无法打开章节", systemImage: "photo.stack", description: Text(error))
                    .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("正在读取章节")
            }
        }
        .toolbar(controlsVisible ? .visible : .hidden, for: .navigationBar)
        // 阅读器层始终隐藏应用主 TabBar，pop 返回时 SwiftUI 会自动恢复。
        // 修饰在两种 readerContent 之外，连续/分页模式都生效。
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack {
                    Text(chapter.title).font(.headline)
                    if pageCount > 0 { Text("\(currentPage + 1) / \(pageCount)").font(.caption) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("阅读模式", selection: $mode) {
                        ForEach(ReaderMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: { Image(systemName: mode == .vertical ? "rectangle.stack" : "rectangle.portrait") }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onAppear { readerIsPresented.wrappedValue = true }
        .onDisappear {
            resetContinuousZoom()
            pageIsZoomed = false
            progressStore.flush()
            readerIsPresented.wrappedValue = false
        }
        .task(id: chapter.id) { await load() }
        .onChange(of: mode) { _, _ in
            resetContinuousZoom()
            pageIsZoomed = false
            // A newly-created continuous ScrollView briefly reports its
            // default position before we restore the saved/current page.
            // Ignore that transient value so it cannot overwrite progress.
            continuousPageTrackingEnabled = false
            continuousScrollPosition = nil
            pendingContinuousRestorePage = nil
            pendingRestorePageIsVisible = false
        }
        .onChange(of: currentPage) { _, value in
            progressStore.update(comicID: comic.id, chapterID: chapter.id, pageIndex: value)
            history.record(comic: comic, chapter: chapter, pageIndex: value)
            if let detail {
                api.prefetchDecodedPages(chapter: detail, after: value)
            }
        }
    }

    @ViewBuilder
    private func readerContent<Page: View>(@ViewBuilder page: @escaping (Int) -> Page) -> some View {
        if mode == .vertical {
            GeometryReader { geometry in
                // Keep UIKit's scroll axes stable for the complete lifetime of
                // one pinch. Rebuilding the underlying scroll view as scale
                // crosses 1.01 cancels gestures and jumps content offsets.
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<pageCount, id: \.self) { index in
                            page(index)
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                    // The width participates in layout, so ScrollView's
                    // contentSize grows with the complete chapter. Every
                    // neighboring page remains reachable after zooming.
                    .frame(width: ReaderInteractionPolicy.continuousContentWidth(
                        viewportWidth: geometry.size.width,
                        scale: continuousZoomScale
                    ))
                    .frame(minWidth: max(1, geometry.size.width), alignment: .center)
                    // Keep a handle to the actual UIKit scroll view. SwiftUI
                    // does not expose directional locking, which is needed
                    // after zooming so a mostly vertical drag cannot make
                    // the complete chapter drift left and right.
                    .background {
                        ReaderScrollDirectionConfigurator(
                            horizontalScrollingEnabled:
                                ReaderInteractionPolicy.continuousHorizontalScrollingEnabled(
                                    scale: continuousZoomScale
                                )
                        )
                        .frame(width: 0, height: 0)
                    }
                }
                // Track the page at the viewport's main (center) anchor.
                // Unlike per-row onAppear, this is not fired merely because
                // LazyVStack preloaded a neighboring image.
                .scrollPosition(id: $continuousScrollPosition, anchor: .center)
                .scrollIndicators(.hidden)
                // At 100% the content width equals the viewport and UIKit's
                // configurator disables horizontal bounce and normalises x.
                // After zooming the wider chapter pans on both axes normally.
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .simultaneousGesture(continuousMagnifyGesture)
                .onTapGesture { withAnimation { controlsVisible.toggle() } }
                .task(id: "\(chapter.id)|\(pageCount)|\(mode.rawValue)") {
                    guard pageCount > 0 else { return }
                    continuousPageTrackingEnabled = false
                    let restoredPage = restoredPageIndex()
                    pendingContinuousRestorePage = restoredPage
                    pendingRestorePageIsVisible = false
                    currentPage = restoredPage
                    continuousScrollPosition = restoredPage
                }
                .onScrollTargetVisibilityChange(
                    idType: Int.self,
                    threshold: 0.01
                ) { visiblePages in
                    guard let restoredPage = pendingContinuousRestorePage else { return }
                    pendingRestorePageIsVisible = visiblePages.contains(restoredPage)
                    enableContinuousPageTrackingIfRestored(restoredPage)
                }
                .onChange(of: continuousScrollPosition) { _, visiblePage in
                    if let restoredPage = pendingContinuousRestorePage {
                        guard visiblePage == restoredPage else { return }
                        enableContinuousPageTrackingIfRestored(restoredPage)
                        return
                    }
                    guard continuousPageTrackingEnabled,
                          let visiblePage,
                          visiblePage >= 0,
                          visiblePage < pageCount,
                          visiblePage != currentPage else { return }
                    currentPage = visiblePage
                }
                .accessibilityLabel("连续漫画阅读区")
                .accessibilityValue("缩放 \(Int(continuousZoomScale * 100))%")
            }
            .id(ReaderMode.vertical)
        } else {
            ZoomableReaderSurface(isZoomed: $pageIsZoomed) {
                TabView(selection: $currentPage) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        page(index).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // 避免放大态拖动整页时误切到上/下一页。
                .scrollDisabled(pageIsZoomed)
                .onTapGesture { withAnimation { controlsVisible.toggle() } }
            }
            .id(ReaderMode.paged)
        }
    }

    private var continuousMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if !continuousMagnificationIsActive {
                    continuousMagnificationIsActive = true
                    continuousMagnificationStartScale = continuousZoomScale
                }
                continuousZoomScale = ReaderInteractionPolicy.clampedZoomScale(
                    continuousMagnificationStartScale * value.magnification
                )
                pageIsZoomed = continuousZoomScale > 1.01
            }
            .onEnded { _ in
                continuousMagnificationIsActive = false
                if continuousZoomScale <= 1.01 {
                    resetContinuousZoom()
                }
            }
    }

    private func resetContinuousZoom() {
        continuousZoomScale = 1
        continuousMagnificationStartScale = 1
        continuousMagnificationIsActive = false
    }

    private func load() async {
        // localPageURLs already validates completeness and file existence.
        localURLs = downloads.localPageURLs(comicID: comic.id, chapterID: chapter.id)
        if !localURLs.isEmpty {
            restorePage()
            history.record(comic: comic, chapter: chapter, pageIndex: currentPage)
            return
        }
        do {
            detail = try await api.chapter(id: chapter.id)
            restorePage()
            history.record(comic: comic, chapter: chapter, pageIndex: currentPage)
            if let detail {
                api.prefetchDecodedPages(chapter: detail, after: max(-1, currentPage - 1))
            }
        } catch {
            guard !APIClient.isCancellation(error), !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func restorePage() {
        currentPage = restoredPageIndex()
    }

    private func restoredPageIndex() -> Int {
        guard let saved = progressStore.progress(comicID: comic.id),
              saved.chapterID == chapter.id else {
            return min(currentPage, max(0, pageCount - 1))
        }
        return min(saved.pageIndex, max(0, pageCount - 1))
    }

    private func enableContinuousPageTrackingIfRestored(_ restoredPage: Int) {
        guard pendingRestorePageIsVisible,
              continuousScrollPosition == restoredPage else { return }
        pendingContinuousRestorePage = nil
        continuousPageTrackingEnabled = true
    }
}

/// Configures the `UIScrollView` owned by SwiftUI's continuous reader without
/// replacing it with a second scrolling implementation. Keeping SwiftUI in
/// charge preserves LazyVStack recycling, ScrollViewReader restoration and
/// trackpad/touch pinch handling, while UIKit's directional lock removes the
/// diagonal drift that is especially noticeable on wide, zoomed pages.
private struct ReaderScrollDirectionConfigurator: UIViewRepresentable {
    let horizontalScrollingEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> HierarchyMarkerView {
        let marker = HierarchyMarkerView(frame: .zero)
        marker.isUserInteractionEnabled = false
        marker.backgroundColor = .clear
        marker.hierarchyDidChange = { [weak marker, weak coordinator = context.coordinator] in
            guard let marker else { return }
            coordinator?.hierarchyDidChange(from: marker)
        }
        context.coordinator.update(
            horizontalScrollingEnabled: horizontalScrollingEnabled,
            from: marker
        )
        return marker
    }

    func updateUIView(_ marker: HierarchyMarkerView, context: Context) {
        context.coordinator.update(
            horizontalScrollingEnabled: horizontalScrollingEnabled,
            from: marker
        )
    }

    final class HierarchyMarkerView: UIView {
        var hierarchyDidChange: (() -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            hierarchyDidChange?()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            hierarchyDidChange?()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private var horizontalScrollingEnabled = false
        private var lastAppliedHorizontalScrollingEnabled: Bool?
        private weak var cachedScrollView: UIScrollView?
        private weak var cachedWindow: UIWindow?
        private var isConfigurationScheduled = false

        func update(horizontalScrollingEnabled: Bool, from marker: UIView) {
            let valueChanged = self.horizontalScrollingEnabled != horizontalScrollingEnabled
            self.horizontalScrollingEnabled = horizontalScrollingEnabled
            guard valueChanged || !cacheIsValid(for: marker) else { return }
            scheduleConfiguration(from: marker)
        }

        func hierarchyDidChange(from marker: UIView) {
            cachedScrollView = nil
            cachedWindow = nil
            lastAppliedHorizontalScrollingEnabled = nil
            scheduleConfiguration(from: marker)
        }

        private func scheduleConfiguration(from marker: UIView) {
            guard !isConfigurationScheduled else { return }
            isConfigurationScheduled = true
            // The representable can be updated before SwiftUI has inserted it
            // into the scroll view's hosting hierarchy. Deferring one run-loop
            // turn covers initial insertion while coalescing rapid scale updates.
            DispatchQueue.main.async { [weak self, weak marker] in
                guard let self else { return }
                self.isConfigurationScheduled = false
                guard let marker else { return }
                self.configureNearestScrollView(from: marker)
            }
        }

        private func configureNearestScrollView(from marker: UIView) {
            let scrollView: UIScrollView
            let isNewScrollView: Bool
            if cacheIsValid(for: marker), let cachedScrollView {
                scrollView = cachedScrollView
                isNewScrollView = false
            } else {
                var ancestor = marker.superview
                while let view = ancestor, !(view is UIScrollView) {
                    ancestor = view.superview
                }
                guard let found = ancestor as? UIScrollView else { return }
                scrollView = found
                cachedScrollView = found
                cachedWindow = marker.window
                lastAppliedHorizontalScrollingEnabled = nil
                isNewScrollView = true
            }

            // `alwaysBounceHorizontal = false` still permits horizontal
            // scrolling whenever zoom makes contentSize wider than bounds; it
            // only removes the empty rubber-band movement at natural size.
            if isNewScrollView {
                scrollView.alwaysBounceHorizontal = false
                scrollView.showsHorizontalScrollIndicator = false
                scrollView.isDirectionalLockEnabled = true
            }

            let shouldResetHorizontalOffset = !horizontalScrollingEnabled
                && (isNewScrollView || lastAppliedHorizontalScrollingEnabled == true)
            if shouldResetHorizontalOffset {
                let restingX = -scrollView.adjustedContentInset.left
                if abs(scrollView.contentOffset.x - restingX) > 0.5 {
                    scrollView.setContentOffset(
                        CGPoint(x: restingX, y: scrollView.contentOffset.y),
                        animated: false
                    )
                }
            }
            lastAppliedHorizontalScrollingEnabled = horizontalScrollingEnabled
        }

        private func cacheIsValid(for marker: UIView) -> Bool {
            guard let scrollView = cachedScrollView,
                  let markerWindow = marker.window,
                  cachedWindow === markerWindow,
                  scrollView.window === markerWindow else { return false }
            return marker.isDescendant(of: scrollView)
        }
    }
}

private struct OnlinePageView: View {
    @EnvironmentObject private var api: APIClient
    @AppStorage(PageImagePreferences.repairChromaKey) private var repairChroma = false
    let chapter: ChapterDetail
    let index: Int
    @State private var image: UIImage?
    @State private var error: String?
    @State private var retryID = 0

    var body: some View {
        Group {
            if let image {
                ReaderPageImage(image: image)
            } else if let error {
                Button {
                    self.error = nil
                    retryID &+= 1
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("加载失败，点击重试").font(.caption)
                        Text(error).font(.caption2).lineLimit(2)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
                .buttonStyle(.plain)
            } else {
                ProgressView().tint(.white).frame(minHeight: 360)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: "\(chapter.id)|\(index)|\(retryID)|\(repairChroma)") {
            let processing: PageImageProcessing = repairChroma ? .repairChroma : .faithful
            do {
                let value = try await api.decodedPageImage(chapter: chapter, index: index, processing: processing)
                guard !Task.isCancelled else { return }
                image = value
                error = nil
                api.prefetchDecodedPages(chapter: chapter, after: index, processing: processing)
            } catch {
                // LazyVStack/TabView 回收页面时的取消是正常生命周期，不应显示 cancelled。
                guard !APIClient.isCancellation(error), !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

private struct LocalPageView: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false
    @State private var retryID = 0

    var body: some View {
        Group {
            if let image {
                ReaderPageImage(image: image)
            } else if failed {
                Button {
                    failed = false
                    retryID &+= 1
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("文件读取失败，点击重试").font(.caption)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
                .buttonStyle(.plain)
            } else {
                ProgressView().tint(.white).frame(minHeight: 360)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: "\(url.path)#\(retryID)") {
            do {
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                let value = try await Task.detached(priority: .userInitiated) {
                    try ImageScrambler.rasterImage(from: data)
                }.value
                guard !Task.isCancelled else { return }
                image = value
                failed = false
            } catch {
                guard !APIClient.isCancellation(error), !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}

/// 图片本身不再单独缩放或裁剪。连续模式通过整条 LazyVStack 的真实
/// 布局宽度放大，分页模式变换整个 TabView，因此相邻页不会盖住当前图。
private struct ReaderPageImage: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .accessibilityLabel("漫画图片")
    }
}

/// 分页阅读的统一缩放层。`MagnifyGesture` 同时支持 iPhone/iPad
/// 触屏双指与妙控键盘/触控板缩放；它变换整个分页容器，而不是单图。
/// 连续阅读不能使用视觉 transform，因为那会先裁掉 ScrollView 视口外
/// 的章节内容；连续模式在上方用参与布局的 content width 实现。
private struct ZoomableReaderSurface<Content: View>: View {
    @Binding var isZoomed: Bool
    private let content: Content
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var magnificationIsActive = false
    @State private var magnificationStartScale: CGFloat = 1
    @State private var magnificationStartOffset: CGSize = .zero
    @State private var panIsActive = false
    @State private var panStartOffset: CGSize = .zero

    init(isZoomed: Binding<Bool>, @ViewBuilder content: () -> Content) {
        _isZoomed = isZoomed
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                viewportSize = newSize
                offset = clampedOffset(offset, scale: scale, viewport: newSize)
            }
            .scaleEffect(scale)
            .offset(offset)
            // 这里不做固定 frame 或单页裁剪；最外层的全屏阅读器
            // 自然形成屏幕边界，相邻漫画页仍作为同一整体变换。
            .contentShape(Rectangle())
            .simultaneousGesture(magnifyGesture)
            // 只在放大后抢占单指拖动；100% 时不挂载平移手势，不影响阅读滚动。
            .highPriorityGesture(
                panGesture,
                including: scale > 1.001 && !magnificationIsActive ? .all : .none
            )
            .onDisappear {
                isZoomed = false
            }
            .accessibilityLabel("漫画阅读区")
            .accessibilityValue("缩放 \(Int(scale * 100))%")
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if !magnificationIsActive {
                    magnificationIsActive = true
                    magnificationStartScale = scale
                    magnificationStartOffset = offset
                }

                let nextScale = ReaderInteractionPolicy.clampedZoomScale(
                    magnificationStartScale * value.magnification
                )
                let focalPoint = CGSize(
                    width: (value.startAnchor.x - 0.5) * viewportSize.width,
                    height: (value.startAnchor.y - 0.5) * viewportSize.height
                )
                let ratio = nextScale / max(magnificationStartScale, 0.001)
                let focalOffset = CGSize(
                    width: focalPoint.width - (focalPoint.width - magnificationStartOffset.width) * ratio,
                    height: focalPoint.height - (focalPoint.height - magnificationStartOffset.height) * ratio
                )
                scale = nextScale
                offset = clampedOffset(focalOffset, scale: nextScale, viewport: viewportSize)
                if nextScale > 1.01 { setZoomed(true) }
            }
            .onEnded { value in
                magnificationIsActive = false
                if scale <= 1.01 {
                    scale = 1
                    offset = .zero
                    setZoomed(false)
                } else {
                    offset = clampedOffset(offset, scale: scale, viewport: viewportSize)
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard scale > 1.001, !magnificationIsActive else { return }
                if !panIsActive {
                    panIsActive = true
                    panStartOffset = offset
                }
                let proposed = CGSize(
                    width: panStartOffset.width + value.translation.width,
                    height: panStartOffset.height + value.translation.height
                )
                offset = clampedOffset(proposed, scale: scale, viewport: viewportSize)
            }
            .onEnded { _ in
                panIsActive = false
                offset = clampedOffset(offset, scale: scale, viewport: viewportSize)
            }
    }

    private func clampedOffset(_ proposed: CGSize, scale: CGFloat, viewport: CGSize) -> CGSize {
        let maximumX = max(0, viewport.width * (scale - 1) / 2)
        let maximumY = max(0, viewport.height * (scale - 1) / 2)
        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY)
        )
    }

    private func setZoomed(_ newValue: Bool) {
        guard isZoomed != newValue else { return }
        isZoomed = newValue
    }
}
