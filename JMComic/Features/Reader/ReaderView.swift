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

/// All focal coordinates are in the stationary viewport, never in a view
/// that is itself moving/scaling. Continuous rows additionally retain a page
/// identity and normalized point, so lazy height estimates cannot move focus.
enum ReaderZoomGeometry {
    static func normalizedPoint(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) / max(1, frame.width),
                y: (point.y - frame.minY) / max(1, frame.height))
    }

    static func point(_ normalized: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + normalized.x * frame.width,
                y: frame.minY + normalized.y * frame.height)
    }

    static func focalOffset(focus: CGPoint, initialOffset: CGSize, ratio: CGFloat) -> CGSize {
        CGSize(width: focus.x - (focus.x - initialOffset.width) * ratio,
               height: focus.y - (focus.y - initialOffset.height) * ratio)
    }

    static func clampedOffset(_ offset: CGSize, scale: CGFloat, viewport: CGSize) -> CGSize {
        let x = max(0, viewport.width * (scale - 1) / 2)
        let y = max(0, viewport.height * (scale - 1) / 2)
        return CGSize(width: min(max(offset.width, -x), x),
                      height: min(max(offset.height, -y), y))
    }

    static func scrollOffset(pageFrame: CGRect, point: CGPoint, focus: CGPoint,
                             contentSize: CGSize, viewport: CGSize, insets: UIEdgeInsets) -> CGPoint {
        let target = self.point(point, in: pageFrame)
        return CGPoint(
            x: min(max(target.x - focus.x, -insets.left),
                   max(-insets.left, contentSize.width - viewport.width + insets.right)),
            y: min(max(target.y - focus.y, -insets.top),
                   max(-insets.top, contentSize.height - viewport.height + insets.bottom))
        )
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
    @AppStorage(PageImagePreferences.prefetchCountKey) private var prefetchPages = PageImagePreferences.defaultPrefetchCount
    @AppStorage(PageImagePreferences.repairChromaKey) private var repairChroma = false
    @State private var prefetchOwner = UUID()
    @State private var chapterLoadGeneration = UUID()
    @State private var loadedChapterID: String?
    @State private var detail: ChapterDetail?
    @State private var localURLs: [URL] = []
    @State private var mode: ReaderMode = .vertical
    @State private var currentPage = 0
    @State private var error: String?
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
                    LocalPageView(url: localURLs[index], isCurrentPage: index == currentPage, isRequested: abs(index - currentPage) <= PageImagePreferences.boundedPrefetchCount(prefetchPages))
                }
            } else if let detail {
                readerContent { index in
                    OnlinePageView(chapter: detail, index: index, isCurrentPage: index == currentPage, isRequested: abs(index - currentPage) <= PageImagePreferences.boundedPrefetchCount(prefetchPages))
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
            chapterLoadGeneration = UUID()
            api.cancelReadingPrefetch(owner: prefetchOwner)
            LocalPageImages.shared.cancelPrefetch(owner: prefetchOwner)
            pageIsZoomed = false
            progressStore.flush()
            readerIsPresented.wrappedValue = false
        }
        .task(id: chapter.id) { await load() }
        .task(id: "\(chapter.id)|\(loadedChapterID ?? "")|\(pageCount)|\(currentPage)|\(prefetchPages)|\(repairChroma)") {
            guard !Task.isCancelled else { return }
            guard loadedChapterID == chapter.id else {
                api.cancelReadingPrefetch(owner: prefetchOwner)
                LocalPageImages.shared.cancelPrefetch(owner: prefetchOwner)
                return
            }
            if let detail, localURLs.isEmpty {
                api.prefetchDecodedPages(chapter: detail, around: currentPage, owner: prefetchOwner,
                    count: prefetchPages, processing: repairChroma ? .repairChroma : .faithful)
            } else if !localURLs.isEmpty {
                LocalPageImages.shared.updatePrefetch(owner: prefetchOwner, urls: localURLs,
                    around: currentPage, count: prefetchPages)
            }
        }
        .onChange(of: mode) { _, _ in
            pageIsZoomed = false
        }
        .onChange(of: currentPage) { _, value in
            progressStore.update(comicID: comic.id, chapterID: chapter.id, pageIndex: value)
            history.record(comic: comic, chapter: chapter, pageIndex: value)
        }
    }

    @ViewBuilder
    private func readerContent<Page: View>(@ViewBuilder page: @escaping (Int) -> Page) -> some View {
        if mode == .vertical {
            ContinuousReaderSurface(
                pageCount: pageCount,
                currentPage: $currentPage,
                isZoomed: $pageIsZoomed,
                onSingleTap: { withAnimation { controlsVisible.toggle() } },
                page: page
            )
            .id(ReaderMode.vertical)
        } else {
            ZoomableReaderSurface(
                isZoomed: $pageIsZoomed,
                onSingleTap: { withAnimation { controlsVisible.toggle() } }
            ) {
                TabView(selection: $currentPage) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        page(index).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // 避免放大态拖动整页时误切到上/下一页。
                .scrollDisabled(pageIsZoomed)
            }
            .id(ReaderMode.paged)
        }
    }

    private func load() async {
        let generation = UUID()
        chapterLoadGeneration = generation
        api.cancelReadingPrefetch(owner: prefetchOwner)
        LocalPageImages.shared.cancelPrefetch(owner: prefetchOwner)
        if loadedChapterID != chapter.id { localURLs = []; detail = nil; loadedChapterID = nil }
        // File checks and network metadata may outlive a dismissed reader or
        // chapter change; publish only into the still-current generation.
        let files = await downloads.localPageURLs(comicID: comic.id, chapterID: chapter.id)
        guard !Task.isCancelled, chapterLoadGeneration == generation else { return }
        localURLs = files
        if !files.isEmpty {
            loadedChapterID = chapter.id
            restorePage()
            history.record(comic: comic, chapter: chapter, pageIndex: currentPage)
            return
        }
        do {
            let result = try await api.chapter(id: chapter.id)
            guard !Task.isCancelled, chapterLoadGeneration == generation else { return }
            detail = result
            loadedChapterID = chapter.id
            restorePage()
            history.record(comic: comic, chapter: chapter, pageIndex: currentPage)
        } catch {
            guard !APIClient.isCancellation(error), !Task.isCancelled,
                  chapterLoadGeneration == generation else { return }
            self.error = error.localizedDescription
        }
    }

    private func restorePage() {
        currentPage = restoredPageIndex()
    }

    private func restoredPageIndex() -> Int {
        guard let saved = progressStore.progress(comicID: comic.id, chapterID: chapter.id),
              saved.chapterID == chapter.id else {
            return min(currentPage, max(0, pageCount - 1))
        }
        return min(saved.pageIndex, max(0, pageCount - 1))
    }

}

/// The chapter remains lazy and scrolls using SwiftUI's existing UIScrollView.
/// Scale is local to this surface; changing it doesn't rebuild ReaderView's
/// toolbar, progress observers or image request inputs.
private struct ContinuousReaderSurface<Page: View>: View {
    let pageCount: Int
    @Binding var currentPage: Int
    @Binding var isZoomed: Bool
    let onSingleTap: () -> Void
    let page: (Int) -> Page
    @StateObject private var zoom = ReaderContinuousZoomController()
    @State private var scrollPosition: Int?
    @State private var pendingRestore: Int?
    @State private var restoredPageVisible = false
    @State private var trackingEnabled = false
    @GestureState private var magnifying = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        ReaderContinuousRow(
                            baseWidth: ReaderInteractionPolicy.continuousContentWidth(
                                viewportWidth: geometry.size.width, scale: 1
                            ),
                            scale: zoom.scale,
                            index: index,
                            zoom: zoom,
                            content: page(index)
                        )
                        .id(index)
                    }
                }
                .scrollTargetLayout()
                .frame(width: ReaderInteractionPolicy.continuousContentWidth(
                    viewportWidth: geometry.size.width, scale: zoom.scale
                ))
                .frame(minWidth: max(1, geometry.size.width), alignment: .center)
            }
            .scrollPosition(id: $scrollPosition, anchor: .center)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .simultaneousGesture(continuousMagnifyGesture)
            .gesture(
                SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture(count: 1))
                    .onEnded { value in
                        switch value {
                        case .first(let tap): zoom.doubleTap(at: tap.location)
                        case .second: onSingleTap()
                        }
                    }
            )
            .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, _ in
                zoom.didScroll()
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                zoom.viewportChanged(to: size)
            }
            .onScrollPhaseChange { _, phase in
                zoom.scrollPhaseChanged(phase)
            }
            .task(id: pageCount) {
                guard pageCount > 0 else { return }
                trackingEnabled = false
                let restored = min(currentPage, pageCount - 1)
                pendingRestore = restored
                restoredPageVisible = false
                scrollPosition = restored
            }
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.01) { visible in
                guard let restored = pendingRestore else { return }
                restoredPageVisible = visible.contains(restored)
                enableTrackingIfRestored()
            }
            .onChange(of: scrollPosition) { _, visible in
                if pendingRestore != nil {
                    enableTrackingIfRestored()
                } else if trackingEnabled, !zoom.isAdjustingFocus,
                          let visible, (0..<pageCount).contains(visible) {
                    currentPage = visible
                }
            }
            .onChange(of: zoom.scale > ReaderInteractionPolicy.continuousHorizontalActivationScale) { _, value in
                isZoomed = value
            }
            .onChange(of: magnifying) { _, value in
                // GestureState also resets on cancellation (onEnded needn't run).
                if !value { zoom.endPinch() }
            }
            .onDisappear {
                zoom.detach()
                isZoomed = false
            }
            .accessibilityLabel("连续漫画阅读区")
            .accessibilityValue("缩放 \(Int(zoom.scale * 100))%")
        }
    }

    private var continuousMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .updating($magnifying) { _, state, _ in state = true }
            .onChanged { value in
                zoom.pinch(magnification: value.magnification, focus: value.startLocation)
            }
            .onEnded { _ in zoom.endPinch() }
    }

    private func enableTrackingIfRestored() {
        guard let restored = pendingRestore, restoredPageVisible,
              scrollPosition == restored else { return }
        pendingRestore = nil
        trackingEnabled = true
    }
}

/// Measure the unscaled page only when its image or base width changes. The
/// occupied height/width still grow at every zoom step, keeping scroll range,
/// neighboring pages and LazyVStack virtualization correct. No chapter bitmap,
/// downsampling, drawingGroup or transform of a clipped viewport is involved.
struct ReaderContinuousRow<Content: View>: View {
    let baseWidth: CGFloat
    let scale: CGFloat
    let index: Int
    let zoom: ReaderContinuousZoomController
    let content: Content
    @State private var baseHeight: CGFloat?

    var body: some View {
        content
            .frame(width: baseWidth)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if height > 0, baseHeight != height {
                    // A newly realized lazy row is not a change to a measured
                    // page. Do not arm scroll compensation on its first layout.
                    if baseHeight != nil { zoom.pageSizeWillChange(index: index) }
                    baseHeight = height
                }
            }
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: baseWidth * scale, height: baseHeight.map { $0 * scale }, alignment: .topLeading)
            .background { ReaderPageGeometryMarker(index: index, zoom: zoom) }
    }
}

struct ReaderPageGeometryMarker: UIViewRepresentable {
    let index: Int
    let zoom: ReaderContinuousZoomController

    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        view.index = index
        view.zoom = zoom
        return view
    }

    func updateUIView(_ view: Marker, context: Context) {
        view.zoom = zoom
        zoom.register(view)
    }

    static func dismantleUIView(_ view: Marker, coordinator: ()) {
        view.zoom?.unregister(view)
    }

    final class Marker: UIView {
        var index = 0
        weak var zoom: ReaderContinuousZoomController?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { zoom?.register(self) }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            zoom?.geometryChanged()
        }
    }
}

@MainActor
final class ReaderContinuousZoomController: NSObject, ObservableObject {
    @Published private(set) var scale: CGFloat = 1
    private struct Row {
        weak var view: UIView?
        var frame: CGRect
    }
    private struct Anchor {
        let index: Int
        let point: CGPoint
        var focus: CGPoint
    }
    private var rows: [Int: Row] = [:] // Only instantiated lazy rows, no chapter cache.
    private weak var scrollView: UIScrollView?
    private var oldMaximumTouches: Int?
    private var viewport = CGSize.zero
    private var anchor: Anchor?
    private var restingAnchor: Anchor?
    private var lastAdjustedOffset: CGPoint?
    private var passiveAdjustmentOffset: CGPoint?
    private var userScrollInProgress = false
    private var startScale: CGFloat?
    private var pendingScale: CGFloat?
    private var animation: (start: CGFloat, end: CGFloat, time: CFTimeInterval)?
    private var displayLink: CADisplayLink?
    private var frameTarget: ReaderZoomFrameTarget?
    private var adjustmentScheduled = false
    private var finishAfterLayout = false
    private(set) var isAdjustingFocus = false

    func register(_ marker: ReaderPageGeometryMarker.Marker) {
        if scrollView == nil || marker.window !== scrollView?.window {
            var parent = marker.superview
            while let view = parent, !(view is UIScrollView) { parent = view.superview }
            if let scroll = parent as? UIScrollView {
                scrollView = scroll
                oldMaximumTouches = scroll.panGestureRecognizer.maximumNumberOfTouches
                scroll.panGestureRecognizer.maximumNumberOfTouches = 1
                scroll.alwaysBounceHorizontal = false
                scroll.isDirectionalLockEnabled = true
            }
        }
        guard let scrollView, marker.isDescendant(of: scrollView) else { return }
        rows[marker.index] = Row(view: marker, frame: marker.convert(marker.bounds, to: scrollView))
        geometryChanged()
    }

    func unregister(_ marker: ReaderPageGeometryMarker.Marker) {
        if rows[marker.index]?.view === marker { rows.removeValue(forKey: marker.index) }
    }

    func pinch(magnification: CGFloat, focus: CGPoint) {
        if startScale == nil {
            stopFrames()
            refreshFrames()
            anchor = capture(at: focus)
            guard anchor != nil else { return }
            passiveAdjustmentOffset = nil
            startScale = scale
            isAdjustingFocus = true
            finishAfterLayout = false
        }
        pendingScale = ReaderInteractionPolicy.clampedZoomScale((startScale ?? scale) * magnification)
        scheduleFrame()
    }

    func endPinch() {
        guard startScale != nil else { return }
        if let pendingScale { scale = pendingScale }
        if scale <= ReaderInteractionPolicy.continuousHorizontalActivationScale { scale = 1 }
        stopFrames()
        startScale = nil
        finishAfterLayout = true
        geometryChanged()
    }

    func doubleTap(at focus: CGPoint) {
        guard startScale == nil else { return }
        stopFrames()
        refreshFrames()
        anchor = capture(at: focus)
        guard anchor != nil else { return }
        passiveAdjustmentOffset = nil
        isAdjustingFocus = true
        finishAfterLayout = false
        animation = (scale, scale > 1.01 ? 1 : 2, CACurrentMediaTime())
        scheduleFrame()
    }

    func beginPan() {
        guard startScale == nil else { return }
        stopFrames()
        releaseAnchor()
    }

    func scrollPhaseChanged(_ phase: ScrollPhase) {
        userScrollInProgress = phase != .idle
        if phase == .tracking || phase == .interacting || phase == .animating { beginPan() }
        if phase == .idle { didScroll() }
    }

    private var isUserScrolling: Bool {
        userScrollInProgress || scrollView?.isTracking == true
            || scrollView?.isDragging == true || scrollView?.isDecelerating == true
    }

    private func releaseAnchor() {
        anchor = nil
        lastAdjustedOffset = nil
        passiveAdjustmentOffset = nil
        finishAfterLayout = false
        isAdjustingFocus = false
    }

    func didScroll() {
        guard !isAdjustingFocus else { return }
        // Retain a zoom anchor for late layout only while the scroll position
        // is still the one we applied. A later drag/deceleration owns its offset.
        if scrollView?.contentOffset != lastAdjustedOffset { releaseAnchor() }
        refreshFrames()
        restingAnchor = capture(at: CGPoint(x: viewport.width / 2, y: viewport.height / 2))
    }

    func viewportChanged(to size: CGSize) {
        guard size != viewport, size.width > 0, size.height > 0 else { return }
        let old = viewport
        viewport = size
        guard old != .zero else { return }
        // Use the previously observed page coordinate, before new width/height
        // estimates arrive. Rotation also terminates the old pinch coordinate space.
        let retained = isAdjustingFocus ? anchor : restingAnchor
        stopFrames()
        startScale = nil
        passiveAdjustmentOffset = nil
        if var retained {
            retained.focus = CGPoint(x: size.width / 2, y: size.height / 2)
            anchor = retained
            isAdjustingFocus = true
            finishAfterLayout = true
            geometryChanged()
        }
    }

    func pageSizeWillChange(index: Int) {
        guard !isAdjustingFocus, !isUserScrolling, let restingAnchor,
              index <= restingAnchor.index,
              rows[restingAnchor.index] != nil else { return }
        passiveAdjustmentOffset = scrollView?.contentOffset
        anchor = restingAnchor
        isAdjustingFocus = true
        finishAfterLayout = true
        geometryChanged()
    }

    func geometryChanged() {
        guard !adjustmentScheduled else { return }
        adjustmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.adjustmentScheduled = false
            self.adjustFocus()
        }
    }

    private func refreshFrames() {
        guard let scrollView else { return }
        rows = rows.filter { $0.value.view?.window != nil }
        for (index, row) in rows {
            guard let view = row.view else { continue }
            rows[index]?.frame = view.convert(view.bounds, to: scrollView)
        }
    }

    private func capture(at focus: CGPoint) -> Anchor? {
        guard let scrollView else { return nil }
        let point = CGPoint(x: scrollView.contentOffset.x + focus.x,
                            y: scrollView.contentOffset.y + focus.y)
        let nearest = rows.filter { $0.value.frame.height > 0 }.min {
            distance(point.y, from: $0.value.frame) < distance(point.y, from: $1.value.frame)
        }
        guard let (index, row) = nearest else { return nil }
        return Anchor(index: index, point: ReaderZoomGeometry.normalizedPoint(point, in: row.frame), focus: focus)
    }

    private func distance(_ y: CGFloat, from frame: CGRect) -> CGFloat {
        max(frame.minY - y, y - frame.maxY, 0)
    }

    private func adjustFocus() {
        guard let scrollView else { return }
        // A user/native scroll may move before SwiftUI delivers its phase or
        // geometry callback. Never pull that newer position back on this turn.
        if let passiveAdjustmentOffset,
           isUserScrolling || passiveAdjustmentOffset != scrollView.contentOffset {
            releaseAnchor()
        } else if !isAdjustingFocus, scrollView.contentOffset != lastAdjustedOffset {
            releaseAnchor()
        }
        refreshFrames()
        if let anchor, let row = rows[anchor.index] {
            let offset = ReaderZoomGeometry.scrollOffset(
                pageFrame: row.frame, point: anchor.point, focus: anchor.focus,
                contentSize: scrollView.contentSize, viewport: scrollView.bounds.size,
                insets: scrollView.adjustedContentInset
            )
            if abs(offset.x - scrollView.contentOffset.x) > 0.25
                || abs(offset.y - scrollView.contentOffset.y) > 0.25 {
                scrollView.setContentOffset(offset, animated: false)
            }
            lastAdjustedOffset = scrollView.contentOffset
        }
        if finishAfterLayout {
            finishAfterLayout = false
            isAdjustingFocus = false
            passiveAdjustmentOffset = nil
            // Late zoom layout can retain the anchor until scrolling moves;
            // didScroll/adjustFocus release it before using any newer offset.
        }
        if !isAdjustingFocus { didScroll() }
    }

    private func scheduleFrame() {
        guard displayLink == nil else { return }
        let target = ReaderZoomFrameTarget { [weak self] in self?.frame() }
        frameTarget = target
        let link = CADisplayLink(target: target, selector: #selector(ReaderZoomFrameTarget.tick))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func frame() {
        if let animation {
            let t = min(1, (CACurrentMediaTime() - animation.time) / 0.26)
            let eased = t * t * (3 - 2 * t)
            scale = animation.start + (animation.end - animation.start) * eased
            if t >= 1 {
                stopFrames()
                finishAfterLayout = true
            }
            geometryChanged()
        } else if let pendingScale {
            if scale != pendingScale { scale = pendingScale }
            self.pendingScale = nil
            geometryChanged()
        } else if startScale == nil {
            stopFrames()
        }
    }

    private func stopFrames() {
        displayLink?.invalidate()
        displayLink = nil
        frameTarget = nil
        pendingScale = nil
        animation = nil
    }

    deinit { displayLink?.invalidate() }

    func detach() {
        stopFrames()
        if let oldMaximumTouches { scrollView?.panGestureRecognizer.maximumNumberOfTouches = oldMaximumTouches }
        scrollView = nil
        rows.removeAll()
        releaseAnchor()
        userScrollInProgress = false
        restingAnchor = nil
        startScale = nil
    }
}

private final class ReaderZoomFrameTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}

private struct OnlinePageView: View {
    @EnvironmentObject private var api: APIClient
    @AppStorage(PageImagePreferences.repairChromaKey) private var repairChroma = false
    let chapter: ChapterDetail
    let index: Int
    let isCurrentPage: Bool
    let isRequested: Bool
    @State private var onScreen = false
    @State private var consumer = UUID()
    @State private var generation = UUID()
    @State private var image: UIImage?
    @State private var dimensions: CGSize?
    @State private var error: String?
    @State private var retryID = 0
    private var visible: Bool { isCurrentPage || onScreen }
    private var shouldLoad: Bool { isRequested || onScreen }
    private var processing: PageImageProcessing { repairChroma ? .repairChroma : .faithful }

    var body: some View {
        Group {
            if let image { ReaderPageImage(image: image) }
            else {
                ReaderImagePlaceholder(dimensions: dimensions) {
                    if let error {
                        Button { self.error = nil; retryID &+= 1 } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise")
                                Text("加载失败，点击重试").font(.caption)
                                Text(error).font(.caption2).lineLimit(2)
                            }.foregroundStyle(.white)
                        }.buttonStyle(.plain)
                    } else { ProgressView().tint(.white) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .onChange(of: visible) { _, value in
            api.setDecodedPageVisible(value, chapter: chapter, index: index, processing: processing, consumer: consumer)
        }
        .onDisappear { image = nil }
        .task(id: "\(chapter.id)|\(index)|\(retryID)|\(repairChroma)|\(shouldLoad)") {
            let stamp = UUID(); generation = stamp
            let requestConsumer = UUID(); consumer = requestConsumer
            guard shouldLoad else { image = nil; return }
            let strategy = processing
            do {
                let result = try await api.decodedPageImage(chapter: chapter, index: index,
                    processing: strategy, consumer: requestConsumer, visible: visible, metadata: { size in
                        if generation == stamp { dimensions = size }
                    })
                guard !Task.isCancelled, generation == stamp else { return }
                image = result; error = nil
            } catch {
                guard !APIClient.isCancellation(error), !Task.isCancelled, generation == stamp else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

private struct LocalPageView: View {
    @Environment(\.scenePhase) private var scenePhase
    let url: URL
    let isCurrentPage: Bool
    let isRequested: Bool
    @State private var onScreen = false
    @State private var consumer = UUID()
    @State private var generation = UUID()
    @State private var image: UIImage?
    @State private var dimensions: CGSize?
    @State private var error: String?
    @State private var retryID = 0
    private var visible: Bool { isCurrentPage || onScreen }
    private var shouldLoad: Bool { isRequested || onScreen }

    var body: some View {
        Group {
            if let image { ReaderPageImage(image: image) }
            else {
                ReaderImagePlaceholder(dimensions: dimensions) {
                    if let error {
                        Button { self.error = nil; retryID &+= 1 } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise")
                                Text("文件读取失败，点击重试").font(.caption)
                                Text(error).font(.caption2).lineLimit(2)
                            }.foregroundStyle(.white)
                        }.buttonStyle(.plain)
                    } else { ProgressView().tint(.white) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .onChange(of: visible) { _, value in LocalPageImages.shared.setVisible(value, consumer: consumer) }
        .onChange(of: scenePhase) { _, value in if value == .active { retryID &+= 1 } }
        .onReceive(NotificationCenter.default.publisher(for: LocalPageImages.filesChanged)) { notice in
            guard let urls = notice.userInfo?["urls"] as? [URL], urls.contains(url) else { return }
            image = nil; dimensions = nil; retryID &+= 1
        }
        .onDisappear { image = nil }
        .task(id: "\(url.path)|\(retryID)|\(shouldLoad)") {
            let stamp = UUID(); generation = stamp
            let requestConsumer = UUID(); consumer = requestConsumer
            guard shouldLoad else { image = nil; return }
            do {
                let result = try await LocalPageImages.shared.image(url: url, consumer: requestConsumer, visible: visible) { size in
                    if generation == stamp { dimensions = size }
                }
                guard !Task.isCancelled, generation == stamp else { return }
                image = result; error = nil
            } catch {
                guard !APIClient.isCancellation(error), !Task.isCancelled, generation == stamp else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

private struct ReaderImagePlaceholder<Content: View>: View {
    let dimensions: CGSize?
    @ViewBuilder let content: () -> Content
    var body: some View {
        if let dimensions, dimensions.height > 0 {
            Color.clear.aspectRatio(dimensions.width / dimensions.height, contentMode: .fit)
                .overlay { content() }
        } else {
            Color.clear.frame(minHeight: 360).overlay { content() }
        }
    }
}

/// Keep the decoded image at full quality. Continuous rows measure this once
/// at the base width; their explicit outer frames reserve the scaled height.
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
/// Paged mode keeps its existing TabView and bounded pan. Gestures live on a
/// stationary viewport so both pinch and double tap use the same focal math.
private struct ZoomableReaderSurface<Content: View>: View {
    @Binding var isZoomed: Bool
    let onSingleTap: () -> Void
    private let content: Content
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var magnificationStartScale: CGFloat?
    @State private var magnificationStartOffset: CGSize = .zero
    @State private var panStartOffset: CGSize?
    @GestureState private var magnifying = false
    @GestureState private var panning = false

    init(isZoomed: Binding<Bool>, onSingleTap: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        _isZoomed = isZoomed
        self.onSingleTap = onSingleTap
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .clipped()
            .simultaneousGesture(magnifyGesture)
            .highPriorityGesture(panGesture, including: scale > 1.001 && !magnifying ? .all : .none)
            .gesture(
                SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture(count: 1))
                    .onEnded { value in
                        switch value {
                        case .first(let tap):
                            let next: CGFloat = scale > 1.01 ? 1 : 2
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.90)) {
                                applyScale(next, from: scale, offset: offset, focus: tap.location)
                            }
                        case .second: onSingleTap()
                        }
                    }
            )
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                let old = viewportSize
                viewportSize = size
                magnificationStartScale = nil
                panStartOffset = nil
                if old.width > 0, old.height > 0 {
                    offset = ReaderZoomGeometry.clampedOffset(
                        CGSize(width: offset.width * size.width / old.width,
                               height: offset.height * size.height / old.height),
                        scale: scale, viewport: size
                    )
                }
            }
            .onChange(of: magnifying) { _, value in
                if !value { finishPinch() }
            }
            .onChange(of: panning) { _, value in
                if !value { panStartOffset = nil }
            }
            .onDisappear { isZoomed = false }
            .accessibilityLabel("漫画阅读区")
            .accessibilityValue("缩放 \(Int(scale * 100))%")
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .updating($magnifying) { _, state, _ in state = true }
            .onChanged { value in
                if magnificationStartScale == nil {
                    magnificationStartScale = scale
                    magnificationStartOffset = offset
                    panStartOffset = nil
                }
                let initial = magnificationStartScale ?? scale
                applyScale(ReaderInteractionPolicy.clampedZoomScale(initial * value.magnification),
                           from: initial, offset: magnificationStartOffset, focus: value.startLocation)
            }
            .onEnded { _ in finishPinch() }
    }

    private func applyScale(_ next: CGFloat, from initial: CGFloat, offset initialOffset: CGSize, focus: CGPoint) {
        let centeredFocus = CGPoint(x: focus.x - viewportSize.width / 2,
                                    y: focus.y - viewportSize.height / 2)
        let proposed = ReaderZoomGeometry.focalOffset(
            focus: centeredFocus, initialOffset: initialOffset, ratio: next / max(1, initial)
        )
        scale = next
        offset = ReaderZoomGeometry.clampedOffset(proposed, scale: next, viewport: viewportSize)
        let zoomed = next > ReaderInteractionPolicy.continuousHorizontalActivationScale
        if isZoomed != zoomed { isZoomed = zoomed }
    }

    private func finishPinch() {
        magnificationStartScale = nil
        if scale <= ReaderInteractionPolicy.continuousHorizontalActivationScale {
            scale = 1
            offset = .zero
            isZoomed = false
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .updating($panning) { _, state, _ in state = true }
            .onChanged { value in
                guard scale > 1.001, !magnifying else { return }
                if panStartOffset == nil { panStartOffset = offset }
                let start = panStartOffset ?? offset
                offset = ReaderZoomGeometry.clampedOffset(
                    CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height),
                    scale: scale, viewport: viewportSize
                )
            }
            .onEnded { _ in panStartOffset = nil }
    }
}
