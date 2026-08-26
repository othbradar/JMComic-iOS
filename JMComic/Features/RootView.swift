import SwiftUI
import UIKit
import OSLog

#if DEBUG
private let rootTabTransitionLogger = Logger(
    subsystem: "io.github.jmcomic.mobile",
    category: "RootTabTransition"
)
#endif

private struct ReaderPresentationBindingKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    /// Reader 用这个 binding 通知根层导航收起 iPad 上的标签栏。
    var readerIsPresented: Binding<Bool> {
        get { self[ReaderPresentationBindingKey.self] }
        set { self[ReaderPresentationBindingKey.self] = newValue }
    }
}

/// 根标签的固定顺序同时是左右滑动的顺序。
///
/// 不使用 `TabView` 的 page style，因为这里仍需要保留 iPadOS 的
/// `sidebarAdaptable` 标签栏和点按切换。
enum RootTab: Int, CaseIterable, Hashable {
    case explore
    case search
    case favorites
    case downloads
    case account
}

/// A content-owned large-title row for root pages that must keep an inline
/// navigation bar. Favorites (compact width) and Downloads share this exact
/// geometry so their visible titles line up with the system large titles on
/// Explore and Search without reintroducing a large/inline bar-height change
/// during navigation pushes.
struct RootPageLargeTitleRow: View {
    static let topInset: CGFloat = 5
    static let bottomInset: CGFloat = 8

    let title: String

    var body: some View {
        Text(title)
            .font(.largeTitle.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(
                top: Self.topInset,
                leading: 0,
                bottom: Self.bottomInset,
                trailing: 0
            ))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Root-tab paging is permitted only while the currently selected column is
/// showing its first page.  This policy consumes SwiftUI-owned state rather
/// than attempting to infer a private UIKit navigation-controller hierarchy.
enum RootNavigationPathPolicy {
    static func allowsRootTabSwipe<Route>(path: [Route]) -> Bool {
        path.isEmpty
    }

    static func allowsFavoritesSidebarRootTabSwipe(
        isRegularWidth: Bool,
        selectedFolderID: String?,
        detailDepth: Int
    ) -> Bool {
        detailDepth == 0 && (isRegularWidth || selectedFolderID == nil)
    }
}

/// 将拖动转成一次相邻根标签切换。放在独立类型中便于用单元测试
/// 锁定阈值、方向和边界，避免垂直滚动被误判。
enum RootTabSwipePolicy {
    // Keep the activation threshold close to UIKit's normal touch slop so a
    // confirmed horizontal drag starts following the finger without a second
    // visible dead zone after DragGesture has already begun.
    static let activationTranslation: CGFloat = 10
    static let minimumTranslation: CGFloat = 56
    static let minimumProjectedTranslation: CGFloat = 110
    static let horizontalDominance: CGFloat = 1.15

    static func beginsOutsideExclusions(
        at location: CGPoint,
        excludedFrames: [CGRect]
    ) -> Bool {
        !excludedFrames.contains { $0.contains(location) }
    }

    static func destination(
        from source: RootTab,
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> RootTab? {
        let horizontal = translation.width
        let vertical = translation.height
        guard abs(horizontal) > abs(vertical) * horizontalDominance else { return nil }

        let projectedHorizontal = predictedEndTranslation.width
        guard abs(horizontal) >= minimumTranslation
                || abs(projectedHorizontal) >= minimumProjectedTranslation else { return nil }

        // 实际位移决定方向，避免系统预测值在抬手时反向抖动。
        let delta = horizontal < 0 ? 1 : -1
        guard let destination = RootTab(rawValue: source.rawValue + delta) else { return nil }
        return destination
    }

    static func adjacentTab(from source: RootTab, horizontalTranslation: CGFloat) -> RootTab? {
        guard horizontalTranslation != 0 else { return nil }
        let delta = horizontalTranslation < 0 ? 1 : -1
        return RootTab(rawValue: source.rawValue + delta)
    }

    /// 拖动过程的跟手位移。有相邻栏目时保持接近 1:1，到边界时
    /// 只给少量阻尼反馈，避免首页/末页被拖出大块空白。
    static func interactiveOffset(
        from source: RootTab,
        translation: CGSize,
        viewportWidth: CGFloat
    ) -> CGFloat {
        guard abs(translation.width) > abs(translation.height) * horizontalDominance else {
            return 0
        }

        let raw = min(max(translation.width, -viewportWidth), viewportWidth)
        let hasDestination = adjacentTab(from: source, horizontalTranslation: raw) != nil
        // 两页的位移由同一个值驱动，有相邻页时必须 1:1
        // 跟手，否则两页之间会露出背景缝隙。
        return raw * (hasDestination ? 1 : 0.16)
    }
}

/// Magic Keyboard and external trackpads deliver two-finger movement as
/// continuous scroll input rather than as SwiftUI touch drags. Keep only the
/// small input-specific pieces here; destination choice and animation still
/// use `RootTabSwipePolicy` and the existing interactive transition state.
enum RootTabTrackpadPolicy {
    static let projectionDuration: CGFloat = 0.20

    static func isHorizontal(velocity: CGPoint) -> Bool {
        abs(velocity.x) > abs(velocity.y) * RootTabSwipePolicy.horizontalDominance
    }

    static func predictedEndTranslation(
        translation: CGSize,
        velocity: CGPoint
    ) -> CGSize {
        CGSize(
            width: translation.width + velocity.x * projectionDuration,
            height: translation.height + velocity.y * projectionDuration
        )
    }
}

/// Keeps window-owned status/tab chrome out of the moving page snapshot.
/// `tabContentFrame` is the area UIKit says is unobscured by the current tab
/// presentation, so the same crop works when iPad moves its adaptive tabs
/// between a sidebar and a top bar.
enum RootTabSnapshotPolicy {
    static func pageCrop(
        anchorFrame: CGRect,
        windowBounds: CGRect,
        safeAreaTop: CGFloat,
        tabContentFrame: CGRect? = nil,
        tabBarFrames: [CGRect] = []
    ) -> CGRect {
        var available = windowBounds
        let statusBarBottom = windowBounds.minY + max(0, safeAreaTop)
        available.origin.y = max(available.minY, statusBarBottom)
        available.size.height = max(0, windowBounds.maxY - available.minY)

        if let tabContentFrame {
            let visibleContent = tabContentFrame.intersection(windowBounds)
            if !visibleContent.isNull, !visibleContent.isEmpty {
                available = available.intersection(visibleContent)
            }
        }

        // iOS 18 has no contentLayoutGuide. A conventional UITabBar is still
        // public and can be removed geometrically. Horizontal bars reserve a
        // complete top/bottom band; vertical bars reserve a leading/trailing
        // band, including RTL layouts.
        for frame in tabBarFrames {
            let visible = frame.intersection(windowBounds)
            guard !visible.isNull, !visible.isEmpty else { continue }
            if visible.width >= visible.height {
                if visible.midY < windowBounds.midY {
                    let newMinY = max(available.minY, visible.maxY)
                    available.size.height = max(0, available.maxY - newMinY)
                    available.origin.y = newMinY
                } else {
                    available.size.height = max(0, min(available.maxY, visible.minY) - available.minY)
                }
            } else if visible.midX < windowBounds.midX {
                let newMinX = max(available.minX, visible.maxX)
                available.size.width = max(0, available.maxX - newMinX)
                available.origin.x = newMinX
            } else {
                available.size.width = max(0, min(available.maxX, visible.minX) - available.minX)
            }
        }

        let visibleAnchor = anchorFrame.intersection(windowBounds)
        guard !visibleAnchor.isNull, !available.isNull else { return .null }
        return visibleAnchor.intersection(available)
    }

    static func stationaryTopHeight(
        windowBounds: CGRect,
        safeAreaTop: CGFloat,
        tabContentFrame: CGRect? = nil,
        tabBarFrames: [CGRect] = [],
        screenScale: CGFloat
    ) -> CGFloat {
        let pixelTolerance = max(0.5, 1 / max(1, screenScale))
        let statusBarBottom = windowBounds.minY + max(0, safeAreaTop)

        // In iPad's adaptive top-tab presentation the liquid-glass capsule
        // visually extends a few points above its layout frame. A foreground
        // status-area fill would therefore shave off that live material while
        // an interactive transition is active. The content guide identifies
        // this presentation without relying on UIKit's private tab-bar class:
        // it spans the window width and begins below the safe-area top.
        if let tabContentFrame {
            let visibleContent = tabContentFrame.intersection(windowBounds)
            if !visibleContent.isNull, !visibleContent.isEmpty {
                let spansWindowWidth = abs(visibleContent.minX - windowBounds.minX) <= pixelTolerance
                    && abs(visibleContent.maxX - windowBounds.maxX) <= pixelTolerance
                if spansWindowWidth,
                   visibleContent.minY > statusBarBottom + pixelTolerance {
                    return 0
                }
            }
        }

        // iOS 18 has no contentLayoutGuide. Preserve the same behaviour for a
        // conventional public UITabBar occupying the top horizontal band.
        for frame in tabBarFrames {
            let visible = frame.intersection(windowBounds)
            guard !visible.isNull, !visible.isEmpty,
                  visible.width >= visible.height,
                  visible.midY < windowBounds.midY,
                  visible.minY <= statusBarBottom + pixelTolerance,
                  visible.maxY > statusBarBottom + pixelTolerance else { continue }
            return 0
        }

        return max(1, safeAreaTop)
    }

    /// Two independently composited SwiftUI layers can otherwise expose a
    /// one-physical-pixel line when their fractional offsets meet exactly.
    /// Extending the outgoing snapshot into the incoming page by two pixels
    /// is visually lossless and keeps their edges overlapped at every frame.
    static func seamOverlap(screenScale: CGFloat) -> CGFloat {
        max(0.5, 2 / max(1, screenScale))
    }

    static func expandedSourceFrame(
        viewportFrame: CGRect,
        destinationBaseOffset: CGFloat,
        screenScale: CGFloat
    ) -> CGRect {
        guard destinationBaseOffset != 0 else { return viewportFrame }
        let overlap = seamOverlap(screenScale: screenScale)
        if destinationBaseOffset > 0 {
            return CGRect(
                x: viewportFrame.minX,
                y: viewportFrame.minY,
                width: viewportFrame.width + overlap,
                height: viewportFrame.height
            )
        }
        return CGRect(
            x: viewportFrame.minX - overlap,
            y: viewportFrame.minY,
            width: viewportFrame.width + overlap,
            height: viewportFrame.height
        )
    }
}

enum RootTabTransitionPhase: Equatable {
    case installingSourceSnapshot
    case preparingDestination
    case installingDestinationSnapshot
    case interactive
    case settling
    case installingCommittedDestination
}

enum RootTabTransitionPreparationAction: Equatable {
    case discardWithoutSelectingDestination
    case prepareDestination
    case restoreSourceWithoutReveal
    case revealInteractively
    case revealAndCommit
}

/// Keeps the two asynchronous readiness callbacks from overriding a decision
/// already made by the physical gesture.
enum RootTabTransitionPreparationPolicy {
    static func sourceSnapshotInstalledAction(
        endDecision: Bool?
    ) -> RootTabTransitionPreparationAction {
        endDecision == false
            ? .discardWithoutSelectingDestination
            : .prepareDestination
    }

    static func destinationReadyAction(
        endDecision: Bool?
    ) -> RootTabTransitionPreparationAction {
        switch endDecision {
        case false:
            return .restoreSourceWithoutReveal
        case true:
            return .revealAndCommit
        case nil:
            return .revealInteractively
        }
    }
}

/// Internal selection mutations are consumed by exact value. A reference gate
/// is intentional: SwiftUI can coalesce ordinary @State changes before
/// `onChange` observes them.
@MainActor
final class RootTabSelectionMutationGate {
    private var expectedSelections: [RootTab] = []

    func expect(_ selection: RootTab) {
        expectedSelections.append(selection)
    }

    func consume(_ selection: RootTab) -> Bool {
        guard let index = expectedSelections.firstIndex(of: selection) else { return false }
        expectedSelections.removeSubrange(...index)
        return true
    }

    func clear() {
        expectedSelections.removeAll(keepingCapacity: true)
    }
}

/// 目的 Tab 是原生 TabView 持有的真实页面。开始水平拖动后
/// 立即选中它，再用这个位移把它放到当前页旁边。
private struct RootTabVisualTransition: Equatable {
    var incomingTab: RootTab?
    var incomingOffset: CGFloat = 0
}

private struct RootTabVisualTransitionKey: EnvironmentKey {
    static let defaultValue = RootTabVisualTransition()
}

private struct RootTabSelectionBindingKey: EnvironmentKey {
    static let defaultValue: Binding<RootTab> = .constant(.explore)
}

extension EnvironmentValues {
    var rootTabSelection: Binding<RootTab> {
        get { self[RootTabSelectionBindingKey.self] }
        set { self[RootTabSelectionBindingKey.self] = newValue }
    }

    fileprivate var rootTabVisualTransition: RootTabVisualTransition {
        get { self[RootTabVisualTransitionKey.self] }
        set { self[RootTabVisualTransitionKey.self] = newValue }
    }
}

private struct RootTabSwipeSurface: Equatable {
    let tab: RootTab
    let frame: CGRect
    let isEnabled: Bool
}

/// Root swipe geometry is queried only when a horizontal gesture is about to
/// begin. Keeping weak UIKit markers avoids publishing a new global CGRect on
/// every vertical ScrollView layout pass (notably the account history strip).
@MainActor
private final class RootTabSwipeRegistry {
    private final class WeakSurface {
        weak var view: RootTabSwipeSurfaceMarkerView?
        init(_ view: RootTabSwipeSurfaceMarkerView) { self.view = view }
    }

    private final class WeakExclusion {
        weak var view: RootTabSwipeExclusionMarkerView?
        init(_ view: RootTabSwipeExclusionMarkerView) { self.view = view }
    }

    private var surfaces: [WeakSurface] = []
    private var exclusions: [WeakExclusion] = []

    func register(_ view: RootTabSwipeSurfaceMarkerView) {
        surfaces.removeAll { $0.view == nil || $0.view === view }
        surfaces.append(WeakSurface(view))
    }

    func unregister(_ view: RootTabSwipeSurfaceMarkerView) {
        surfaces.removeAll { $0.view == nil || $0.view === view }
    }

    func register(_ view: RootTabSwipeExclusionMarkerView) {
        exclusions.removeAll { $0.view == nil || $0.view === view }
        exclusions.append(WeakExclusion(view))
    }

    func unregister(_ view: RootTabSwipeExclusionMarkerView) {
        exclusions.removeAll { $0.view == nil || $0.view === view }
    }

    func activeSurface(for tab: RootTab, at location: CGPoint) -> RootTabSwipeSurface? {
        surfaces.removeAll { $0.view == nil }
        exclusions.removeAll { $0.view == nil }

        for marker in surfaces.reversed().compactMap(\.view) {
            guard marker.tab == tab,
                  marker.isSwipeEnabled,
                  let window = marker.window,
                  let frame = visibleFrame(of: marker, in: window) else { continue }
            guard frame.contains(location) else { continue }

            let excludedFrames = exclusions.compactMap { exclusion -> CGRect? in
                guard let view = exclusion.view,
                      view.tab == tab,
                      view.window === window,
                      let exclusionFrame = visibleFrame(of: view, in: window) else { return nil }
                return exclusionFrame.intersects(frame) ? exclusionFrame : nil
            }
            guard RootTabSwipePolicy.beginsOutsideExclusions(
                at: location,
                excludedFrames: excludedFrames
            ) else { return nil }
            return RootTabSwipeSurface(tab: tab, frame: frame, isEnabled: true)
        }
        return nil
    }

    private func visibleFrame(of view: UIView, in window: UIWindow) -> CGRect? {
        var frame = view.convert(view.bounds, to: window)
        var current: UIView? = view
        while let candidate = current {
            guard !candidate.isHidden, candidate.alpha > 0.01 else { return nil }
            if candidate.clipsToBounds {
                frame = frame.intersection(candidate.convert(candidate.bounds, to: window))
                guard !frame.isNull, !frame.isEmpty else { return nil }
            }
            if candidate === window { break }
            current = candidate.superview
        }
        frame = frame.intersection(window.bounds)
        return frame.isNull || frame.isEmpty ? nil : frame
    }
}

private struct RootTabSwipeRegistryKey: EnvironmentKey {
    static let defaultValue: RootTabSwipeRegistry? = nil
}

private struct RootTabSwipeSourceKey: EnvironmentKey {
    static let defaultValue: RootTab? = nil
}

private extension EnvironmentValues {
    var rootTabSwipeRegistry: RootTabSwipeRegistry? {
        get { self[RootTabSwipeRegistryKey.self] }
        set { self[RootTabSwipeRegistryKey.self] = newValue }
    }

    var rootTabSwipeSource: RootTab? {
        get { self[RootTabSwipeSourceKey.self] }
        set { self[RootTabSwipeSourceKey.self] = newValue }
    }
}

private final class RootTabSwipeSurfaceMarkerView: UIView {
    weak var registry: RootTabSwipeRegistry?
    var tab: RootTab = .explore
    var isSwipeEnabled = false
}

private final class RootTabSwipeExclusionMarkerView: UIView {
    weak var registry: RootTabSwipeRegistry?
    var tab: RootTab?
}

@MainActor
private struct RootTabSwipeSurfaceMarker: UIViewRepresentable {
    let registry: RootTabSwipeRegistry
    let tab: RootTab
    let isEnabled: Bool

    func makeUIView(context: Context) -> RootTabSwipeSurfaceMarkerView {
        let view = RootTabSwipeSurfaceMarkerView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        update(view)
        return view
    }

    func updateUIView(_ uiView: RootTabSwipeSurfaceMarkerView, context: Context) {
        update(uiView)
    }

    static func dismantleUIView(
        _ uiView: RootTabSwipeSurfaceMarkerView,
        coordinator: Void
    ) {
        uiView.registry?.unregister(uiView)
        uiView.registry = nil
    }

    private func update(_ view: RootTabSwipeSurfaceMarkerView) {
        if view.registry !== registry {
            view.registry?.unregister(view)
            view.registry = registry
        }
        view.tab = tab
        view.isSwipeEnabled = isEnabled
        registry.register(view)
    }
}

@MainActor
private struct RootTabSwipeExclusionMarker: UIViewRepresentable {
    let registry: RootTabSwipeRegistry
    let tab: RootTab

    func makeUIView(context: Context) -> RootTabSwipeExclusionMarkerView {
        let view = RootTabSwipeExclusionMarkerView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        update(view)
        return view
    }

    func updateUIView(_ uiView: RootTabSwipeExclusionMarkerView, context: Context) {
        update(uiView)
    }

    static func dismantleUIView(
        _ uiView: RootTabSwipeExclusionMarkerView,
        coordinator: Void
    ) {
        uiView.registry?.unregister(uiView)
        uiView.registry = nil
    }

    private func update(_ view: RootTabSwipeExclusionMarkerView) {
        if view.registry !== registry {
            view.registry?.unregister(view)
            view.registry = registry
        }
        view.tab = tab
        registry.register(view)
    }
}

/// 只对当前已经在 window 中显示的根页面截图。目的页从不截图：
/// 它一直是 native TabView 中的真实、持久页面，因此不会重建 ViewModel
/// 或额外触发 `.task`/网络请求。
@MainActor
private final class RootTabVisiblePageSnapshotter {
    struct Snapshot {
        let contentView: UIView
        let frame: CGRect
        let screenScale: CGFloat
        let stationaryTopHeight: CGFloat
    }

    private final class WeakAnchor {
        weak var view: RootTabSnapshotAnchorView?
        init(_ view: RootTabSnapshotAnchorView) { self.view = view }
    }

    private struct AnchorWaiter {
        let token: UUID
        let tab: RootTab
        let expectedFrame: CGRect
        let minimumAppearanceGeneration: Int
        let completion: (UUID) -> Void
    }

    private var anchors: [RootTab: [WeakAnchor]] = [:]
    private var anchorWaiters: [UUID: AnchorWaiter] = [:]
    private var appearanceGenerations: [RootTab: Int] = [:]

    func register(
        _ view: RootTabSnapshotAnchorView,
        for tab: RootTab,
        isSelected: Bool
    ) {
        var values = anchors[tab, default: []].filter { $0.view != nil && $0.view !== view }
        values.append(WeakAnchor(view))
        anchors[tab] = values
        view.configure(snapshotter: self, tab: tab, isSelected: isSelected)
    }

    func waitForSelectedAnchor(
        for tab: RootTab,
        token: UUID,
        matching expectedFrame: CGRect,
        completion: @escaping (UUID) -> Void
    ) {
        anchorWaiters[token] = AnchorWaiter(
            token: token,
            tab: tab,
            expectedFrame: expectedFrame,
            minimumAppearanceGeneration: appearanceGenerations[tab, default: 0] + 1,
            completion: completion
        )
    }

    func tabDidAppear(_ tab: RootTab) {
        appearanceGenerations[tab, default: 0] += 1
        for anchor in anchors[tab, default: []].compactMap(\.view) {
            anchorDidUpdate(anchor)
        }
    }

    func cancelAnchorWait(token: UUID) {
        anchorWaiters[token] = nil
    }

    func hasConfirmedSelectedAnchor(
        for tab: RootTab,
        matching expectedFrame: CGRect
    ) -> Bool {
        guard let values = anchors[tab] else { return false }
        return values.compactMap(\.view).contains { view in
            view.isSelectedRootTab
                && view.window != nil
                && view.bounds.width > 1
                && view.bounds.height > 1
                && isSelectedByTabController(view, tab: tab)
                && frameMatchScore(of: view, with: expectedFrame) > 0.5
        }
    }

    fileprivate func anchorDidUpdate(_ view: RootTabSnapshotAnchorView) {
        guard view.isSelectedRootTab,
              view.window != nil,
              view.bounds.width > 1,
              view.bounds.height > 1,
              isSelectedByTabController(view, tab: view.rootTab) else { return }

        let matchingWaiters = anchorWaiters.values.filter {
            $0.tab == view.rootTab
                && appearanceGenerations[view.rootTab, default: 0]
                    >= $0.minimumAppearanceGeneration
                && frameMatchScore(of: view, with: $0.expectedFrame) > 0.5
        }
        for waiter in matchingWaiters {
            anchorWaiters[waiter.token] = nil
            DispatchQueue.main.async {
                waiter.completion(waiter.token)
            }
        }
    }

    private func isSelectedByTabController(
        _ view: UIView,
        tab: RootTab
    ) -> Bool {
        var responder: UIResponder? = view
        var tabBarController: UITabBarController?
        while let current = responder {
            if let controller = current as? UIViewController {
                tabBarController = (controller as? UITabBarController)
                    ?? controller.tabBarController
                if tabBarController != nil { break }
            }
            responder = current.next
        }
        guard let tabBarController,
              tabBarController.selectedIndex == tab.rawValue,
              let selectedView = tabBarController.selectedViewController?.view else {
            return false
        }
        return view === selectedView || view.isDescendant(of: selectedView)
    }

    func visibleSnapshot(
        for tab: RootTab,
        matching expectedFrame: CGRect,
        backgroundColor: UIColor
    ) -> Snapshot? {
        guard let values = anchors[tab] else { return nil }
        let candidates = values.compactMap(\.view).filter(isEffectivelyVisible)
        guard let anchor = candidates.max(by: {
            frameMatchScore(of: $0, with: expectedFrame)
                < frameMatchScore(of: $1, with: expectedFrame)
        }), let window = anchor.window else { return nil }

        let anchorFrame = anchor.convert(anchor.bounds, to: window)
        // The system status bar is owned by the window rather than by an
        // individual tab. Capturing it into the outgoing page duplicates the
        // clock / Dynamic Island and UIKit sometimes renders its transparent
        // material against pure white. Keep that strip stationary and only
        // snapshot the page below the safe-area top.
        let tabBarFrames = visibleTabBars(in: window).map {
            $0.convert($0.bounds, to: window)
        }
        let tabContentFrame = visibleTabContentFrame(from: anchor, in: window)
        let screenScale = window.screen.scale
        let crop = RootTabSnapshotPolicy.pageCrop(
            anchorFrame: anchorFrame,
            windowBounds: window.bounds,
            safeAreaTop: window.safeAreaInsets.top,
            tabContentFrame: tabContentFrame,
            tabBarFrames: tabBarFrames
        )
        guard crop.width > 1, crop.height > 1 else { return nil }
        let stationaryTopHeight = RootTabSnapshotPolicy.stationaryTopHeight(
            windowBounds: window.bounds,
            safeAreaTop: window.safeAreaInsets.top,
            tabContentFrame: tabContentFrame,
            tabBarFrames: tabBarFrames,
            screenScale: screenScale
        )

        // `drawHierarchy` rasterizes the complete window synchronously and
        // took 30-45 ms on an iPhone 17 Pro Max simulator, which is enough to
        // drop several 120 Hz frames exactly when a slow drag crosses the
        // activation threshold. UIKit's snapshot view keeps a compositor-
        // backed representation of the same crop and is normally created in
        // well below one frame. It is short-lived and released as soon as the
        // interactive transition settles.
        if let fastSnapshot = window.resizableSnapshotView(
            from: crop,
            afterScreenUpdates: false,
            withCapInsets: .zero
        ) {
            return Snapshot(
                contentView: snapshotContainer(
                    contentView: fastSnapshot,
                    size: crop.size,
                    backgroundColor: backgroundColor
                ),
                frame: crop,
                screenScale: screenScale,
                stationaryTopHeight: stationaryTopHeight
            )
        }

        // Never synchronously rasterize the complete window on the gesture
        // activation path. This second compositor-backed snapshot is cropped
        // by its lightweight container; if UIKit cannot provide it either,
        // this physical swipe is simply abandoned.
        guard let windowSnapshot = window.snapshotView(afterScreenUpdates: false) else {
            return nil
        }
        let contentFrame = CGRect(
            x: window.bounds.minX - crop.minX,
            y: window.bounds.minY - crop.minY,
            width: window.bounds.width,
            height: window.bounds.height
        )
        return Snapshot(
            contentView: snapshotContainer(
                contentView: windowSnapshot,
                size: crop.size,
                backgroundColor: backgroundColor,
                contentFrame: contentFrame
            ),
            frame: crop,
            screenScale: screenScale,
            stationaryTopHeight: stationaryTopHeight
        )
    }

    /// Captures the selected tab controller itself rather than the app window.
    /// The root transition overlay lives above TabView, so a controller-local
    /// snapshot contains only the real destination page and never recaptures
    /// the outgoing overlay that is currently covering it.
    func selectedContentSnapshot(
        for tab: RootTab,
        matching expectedFrame: CGRect,
        backgroundColor: UIColor
    ) -> Snapshot? {
        guard let values = anchors[tab] else { return nil }
        let candidates = values.compactMap(\.view).filter {
            $0.isSelectedRootTab && isEffectivelyVisible($0)
        }
        guard let anchor = candidates.max(by: {
            frameMatchScore(of: $0, with: expectedFrame)
                < frameMatchScore(of: $1, with: expectedFrame)
        }), let window = anchor.window else { return nil }

        var responder: UIResponder? = anchor
        var tabBarController: UITabBarController?
        while let current = responder {
            if let controller = current as? UIViewController {
                tabBarController = (controller as? UITabBarController)
                    ?? controller.tabBarController
                if tabBarController != nil { break }
            }
            responder = current.next
        }
        guard let tabBarController,
              tabBarController.selectedIndex == tab.rawValue,
              let selectedView = tabBarController.selectedViewController?.view else {
            return nil
        }

        selectedView.setNeedsLayout()
        selectedView.layoutIfNeeded()
        let cropInSelectedView = selectedView.convert(expectedFrame, from: window)
            .intersection(selectedView.bounds)
        guard cropInSelectedView.width > 1,
              cropInSelectedView.height > 1 else { return nil }

        let content = selectedView.resizableSnapshotView(
            from: cropInSelectedView,
            afterScreenUpdates: true,
            withCapInsets: .zero
        ) ?? selectedView.snapshotView(afterScreenUpdates: true)
        guard let content else { return nil }

        let contentFrame: CGRect?
        if content.bounds.size == selectedView.bounds.size {
            contentFrame = CGRect(
                x: -cropInSelectedView.minX,
                y: -cropInSelectedView.minY,
                width: selectedView.bounds.width,
                height: selectedView.bounds.height
            )
        } else {
            contentFrame = nil
        }

        return Snapshot(
            contentView: snapshotContainer(
                contentView: content,
                size: expectedFrame.size,
                backgroundColor: backgroundColor,
                contentFrame: contentFrame
            ),
            frame: expectedFrame,
            screenScale: window.screen.scale,
            stationaryTopHeight: 0
        )
    }

    private func snapshotContainer(
        contentView: UIView,
        size: CGSize,
        backgroundColor: UIColor,
        contentFrame: CGRect? = nil
    ) -> UIView {
        let container = UIView(frame: CGRect(origin: .zero, size: size))
        container.isUserInteractionEnabled = false
        container.backgroundColor = backgroundColor
        container.clipsToBounds = true
        contentView.frame = contentFrame ?? container.bounds
        contentView.autoresizingMask = contentFrame == nil
            ? [.flexibleWidth, .flexibleHeight]
            : []
        contentView.isUserInteractionEnabled = false
        container.addSubview(contentView)
        return container
    }

    private func frameMatchScore(of view: UIView, with frame: CGRect) -> CGFloat {
        guard let window = view.window else { return 0 }
        let viewFrame = view.convert(view.bounds, to: window)
        let intersection = viewFrame.intersection(frame)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let viewArea = viewFrame.width * viewFrame.height
        let expectedArea = frame.width * frame.height
        let unionArea = viewArea + expectedArea - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    private func isEffectivelyVisible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            guard !candidate.isHidden, candidate.alpha > 0.01 else { return false }
            if candidate === view.window { return true }
            current = candidate.superview
        }
        return false
    }

    /// iOS 26 exposes the exact area unobscured by an adaptive tab sidebar or
    /// tab bar. It also covers private system implementations such as the
    /// floating iPad top bar, which is not a UITabBar subclass.
    private func visibleTabContentFrame(from anchor: UIView, in window: UIWindow) -> CGRect? {
        guard #available(iOS 26.0, *) else { return nil }

        var responder: UIResponder? = anchor
        var tabBarController: UITabBarController?
        while let current = responder {
            if let controller = current as? UIViewController {
                tabBarController = (controller as? UITabBarController)
                    ?? controller.tabBarController
                if tabBarController != nil { break }
            }
            responder = current.next
        }
        guard let tabBarController,
              let owner = tabBarController.contentLayoutGuide.owningView else { return nil }
        owner.layoutIfNeeded()
        let frame = owner.convert(
            tabBarController.contentLayoutGuide.layoutFrame,
            to: window
        ).intersection(window.bounds)
        return !frame.isNull && !frame.isEmpty ? frame : nil
    }

    private func visibleTabBars(in window: UIWindow) -> [UITabBar] {
        var pending: [UIView] = [window]
        var tabBars: [UITabBar] = []
        while let view = pending.popLast() {
            pending.append(contentsOf: view.subviews)
            guard let tabBar = view as? UITabBar,
                  isEffectivelyVisible(tabBar) else { continue }
            tabBars.append(tabBar)
        }
        return tabBars
    }
}

private struct RootTabSnapshotterKey: EnvironmentKey {
    static let defaultValue: RootTabVisiblePageSnapshotter? = nil
}

private extension EnvironmentValues {
    var rootTabSnapshotter: RootTabVisiblePageSnapshotter? {
        get { self[RootTabSnapshotterKey.self] }
        set { self[RootTabSnapshotterKey.self] = newValue }
    }
}

@MainActor
private final class RootTabSnapshotAnchorView: UIView {
    weak var snapshotter: RootTabVisiblePageSnapshotter?
    var rootTab: RootTab = .explore
    var isSelectedRootTab = false
    private var updateGeneration = 0

    func configure(
        snapshotter: RootTabVisiblePageSnapshotter,
        tab: RootTab,
        isSelected: Bool
    ) {
        self.snapshotter = snapshotter
        rootTab = tab
        isSelectedRootTab = isSelected
        updateGeneration &+= 1
        let generation = updateGeneration
        setNeedsLayout()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.updateGeneration == generation else { return }
            self.layoutIfNeeded()
            self.snapshotter?.anchorDidUpdate(self)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        snapshotter?.anchorDidUpdate(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        snapshotter?.anchorDidUpdate(self)
    }
}

private struct RootTabSnapshotAnchor: UIViewRepresentable {
    let tab: RootTab
    let snapshotter: RootTabVisiblePageSnapshotter
    let isSelected: Bool

    func makeUIView(context: Context) -> RootTabSnapshotAnchorView {
        let view = RootTabSnapshotAnchorView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        snapshotter.register(view, for: tab, isSelected: isSelected)
        return view
    }

    func updateUIView(_ uiView: RootTabSnapshotAnchorView, context: Context) {
        snapshotter.register(uiView, for: tab, isSelected: isSelected)
    }
}

private final class RootTabSnapshotHostView: UIView {
    var token: UUID? {
        didSet {
            guard oldValue != token else { return }
            reportedToken = nil
            scheduledToken = nil
            checkInstallation()
        }
    }
    var onInstalled: ((UUID) -> Void)?
    private var reportedToken: UUID?
    private var scheduledToken: UUID?

    var hostedView: UIView? {
        didSet {
            guard oldValue !== hostedView else { return }
            oldValue?.removeFromSuperview()
            if let hostedView {
                hostedView.frame = bounds
                hostedView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(hostedView)
            }
            checkInstallation()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        checkInstallation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostedView?.frame = bounds
        checkInstallation()
    }

    private func checkInstallation() {
        guard let token,
              reportedToken != token,
              scheduledToken != token,
              window != nil,
              bounds.width > 1,
              bounds.height > 1,
              hostedView != nil else { return }

        scheduledToken = token
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.token == token,
                  self.reportedToken != token,
                  self.window != nil,
                  self.bounds.width > 1,
                  self.bounds.height > 1,
                  self.hostedView != nil else {
                if self?.scheduledToken == token {
                    self?.scheduledToken = nil
                }
                return
            }
            self.scheduledToken = nil
            self.reportedToken = token
            self.onInstalled?(token)
        }
    }
}

/// Hosts UIKit's compositor-backed snapshot inside the SwiftUI transition
/// overlay without converting it to a bitmap on the main thread.
private struct RootTabSnapshotContentView: UIViewRepresentable {
    let contentView: UIView
    let token: UUID
    let onInstalled: (UUID) -> Void

    func makeUIView(context: Context) -> RootTabSnapshotHostView {
        let host = RootTabSnapshotHostView(frame: .zero)
        host.isUserInteractionEnabled = false
        host.backgroundColor = .clear
        host.clipsToBounds = true
        host.onInstalled = onInstalled
        host.token = token
        host.hostedView = contentView
        return host
    }

    func updateUIView(_ uiView: RootTabSnapshotHostView, context: Context) {
        uiView.onInstalled = onInstalled
        uiView.token = token
        uiView.hostedView = contentView
    }

    static func dismantleUIView(_ uiView: RootTabSnapshotHostView, coordinator: Void) {
        uiView.onInstalled = nil
        uiView.token = nil
        uiView.hostedView = nil
    }
}

/// A distinct representable identity for the incoming page. Keeping the two
/// UIKit hosts as different SwiftUI view types prevents an insertion update
/// from temporarily moving the outgoing snapshot into the incoming slot.
private struct RootTabDestinationSnapshotContentView: UIViewRepresentable {
    let contentView: UIView
    let token: UUID
    let onInstalled: (UUID) -> Void

    func makeUIView(context: Context) -> RootTabSnapshotHostView {
        let host = RootTabSnapshotHostView(frame: .zero)
        host.isUserInteractionEnabled = false
        host.backgroundColor = .clear
        host.clipsToBounds = true
        host.onInstalled = onInstalled
        host.token = token
        host.hostedView = contentView
        return host
    }

    func updateUIView(_ uiView: RootTabSnapshotHostView, context: Context) {
        uiView.onInstalled = onInstalled
        uiView.token = token
        uiView.hostedView = contentView
    }

    static func dismantleUIView(_ uiView: RootTabSnapshotHostView, coordinator: Void) {
        uiView.onInstalled = nil
        uiView.token = nil
        uiView.hostedView = nil
    }
}

private struct RootTabSwipeModifier: ViewModifier {
    @Environment(\.rootTabSwipeRegistry) private var registry
    let source: RootTab
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.rootTabSwipeSource, source)
            .overlay {
                if let registry {
                    RootTabSwipeSurfaceMarker(
                        registry: registry,
                        tab: source,
                        isEnabled: isEnabled
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
            }
    }
}

private struct RootTabSwipeExclusionModifier: ViewModifier {
    @Environment(\.rootTabSwipeRegistry) private var registry
    @Environment(\.rootTabSwipeSource) private var source

    func body(content: Content) -> some View {
        content
            .background {
                if let registry, let source {
                    RootTabSwipeExclusionMarker(registry: registry, tab: source)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// 视觉过渡包在整个 Tab 容器上，而手势判定仍由内部的
/// `rootTabSwipe` 根内容上报。因此导航栏、大标题和 toolbar 会跟页面
/// 一起移动，但 push 到二级页后不会误开根切换手势。
private struct RootTabTransitionContainerModifier: ViewModifier {
    @EnvironmentObject private var appearance: AppAppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.rootTabSelection) private var selection
    @Environment(\.rootTabVisualTransition) private var visualTransition
    @Environment(\.rootTabSnapshotter) private var snapshotter
    let tab: RootTab

    func body(content: Content) -> some View {
        content
            .offset(x: visualTransition.incomingTab == tab
                    ? visualTransition.incomingOffset : 0)
            .onAppear {
                snapshotter?.tabDidAppear(tab)
            }
            .background {
                // Modifier order is intentional: only the page above moves.
                // This palette base stays stationary, so the host exposed
                // beneath the one live floating tab bar is never white. It
                // also removes the need to capture or duplicate that bar.
                appearance.background(for: colorScheme)
                    .ignoresSafeArea()
                if let snapshotter {
                    RootTabSnapshotAnchor(
                        tab: tab,
                        snapshotter: snapshotter,
                        isSelected: selection.wrappedValue == tab
                    )
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct RootTabInteractiveTransition {
    let token: UUID
    let source: RootTab
    let destination: RootTab
    let sourceView: UIView
    let sourceScale: CGFloat
    let viewportFrame: CGRect
    let stationaryTopHeight: CGFloat
    let destinationBaseOffset: CGFloat
    var destinationView: UIView?
    var sourceOffset: CGFloat
    var destinationOffset: CGFloat
    var pendingSourceOffset: CGFloat
    var phase: RootTabTransitionPhase
    var endDecision: Bool?
}

/// SwiftUI batches `@State` invalidations until the next render pass. A slow
/// pointer/touch can deliver several `onChanged` callbacks in that gap, so a
/// state-only `interactiveTransition == nil` check may start and snapshot the
/// same gesture repeatedly. This small reference gate changes synchronously
/// and guarantees exactly one root transition per physical drag.
@MainActor
final class RootTabGestureLifecycle {
    private(set) var isActive = false

    func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    func end() {
        isActive = false
    }
}

private struct RootTabLivePageTransition {
    let source: RootTab
    let destination: RootTab
    let viewportWidth: CGFloat
    var offset: CGFloat
    var isSettling = false
}

/// Drives an interactive transition with the two real tab controller views.
/// The native TabView remains the sole owner of selection, safe areas,
/// NavigationStack containment and liquid-glass chrome. During a drag its
/// selection never changes; only the already-owned source and adjacent views
/// are translated inside the tab content container.
@MainActor
private final class RootTabLivePagePager {
    private weak var tabBarController: UITabBarController?
    private weak var sourceView: UIView?
    private weak var destinationView: UIView?
    private weak var transitionContainer: UIView?
    private var sourceFrame: CGRect = .zero
    private var destination: RootTab?
    private var animator: UIViewPropertyAnimator?
    private var prewarmGeneration = 0
    private var scheduledPrewarmSelection: Int?
    private var prewarmedSelection: Int?

    func attach(to tabBarController: UITabBarController) {
        guard self.tabBarController !== tabBarController else {
            let selectedIndex = tabBarController.selectedIndex
            if prewarmedSelection != selectedIndex,
               scheduledPrewarmSelection != selectedIndex {
                schedulePrewarm(selectedIndex: selectedIndex)
            }
            return
        }
        cancelImmediately()
        scheduledPrewarmSelection = nil
        prewarmedSelection = nil
        self.tabBarController = tabBarController
        preloadPages()
        schedulePrewarm(selectedIndex: tabBarController.selectedIndex)
    }

    func begin(source: RootTab, destination: RootTab) -> CGFloat? {
        guard animator == nil,
              let tabBarController,
              tabBarController.selectedIndex == source.rawValue,
              prewarmedSelection == source.rawValue else { return nil }
        let controllers = rootControllers(in: tabBarController)
        guard controllers.indices.contains(source.rawValue),
              controllers.indices.contains(destination.rawValue) else { return nil }

        let sourceController = controllers[source.rawValue]
        let destinationController = controllers[destination.rawValue]
        sourceController.loadViewIfNeeded()
        destinationController.loadViewIfNeeded()
        tabBarController.view.layoutIfNeeded()

        let sourceView = sourceController.view!
        let destinationView = destinationController.view!
        guard let container = sourceView.superview,
              sourceView.window != nil,
              sourceView.bounds.width > 1 else { return nil }

        // Prewarmed pages are already direct siblings of the selected page.
        // Keep the destination in the same hierarchy and only change its
        // transform/z-order. Reparenting an inactive SwiftUI controller view at
        // gesture start makes Core Animation expose the selected page's stale
        // backing layer for one frame even though the destination is rendered.
        guard destinationView.superview === container else { return nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        destinationView.frame = sourceView.frame
        destinationView.autoresizingMask = sourceView.autoresizingMask
        destinationView.transform = CGAffineTransform(
            translationX: destination.rawValue > source.rawValue
                ? sourceView.bounds.width : -sourceView.bounds.width,
            y: 0
        )
        container.insertSubview(destinationView, aboveSubview: sourceView)
        CATransaction.commit()

        self.sourceView = sourceView
        self.destinationView = destinationView
        transitionContainer = container
        sourceFrame = sourceView.frame
        self.destination = destination
        return sourceView.bounds.width
    }

    func update(offset: CGFloat, viewportWidth: CGFloat) {
        guard let sourceView, let destinationView, let destination else { return }
        sourceView.transform = CGAffineTransform(translationX: offset, y: 0)
        let base = destination.rawValue > (tabBarController?.selectedIndex ?? 0)
            ? viewportWidth : -viewportWidth
        destinationView.transform = CGAffineTransform(translationX: base + offset, y: 0)
    }

    func settle(
        commit: Bool,
        viewportWidth: CGFloat,
        completion: @escaping () -> Void
    ) {
        guard let sourceView, let destinationView, let destination else {
            completion()
            return
        }
        let finalSourceOffset: CGFloat
        let finalDestinationOffset: CGFloat
        if commit {
            finalSourceOffset = destination.rawValue > (tabBarController?.selectedIndex ?? 0)
                ? -viewportWidth : viewportWidth
            finalDestinationOffset = 0
        } else {
            finalSourceOffset = 0
            finalDestinationOffset = destination.rawValue > (tabBarController?.selectedIndex ?? 0)
                ? viewportWidth : -viewportWidth
        }

        let animator = UIViewPropertyAnimator(duration: 0.30, dampingRatio: 0.90) {
            sourceView.transform = CGAffineTransform(translationX: finalSourceOffset, y: 0)
            destinationView.transform = CGAffineTransform(
                translationX: finalDestinationOffset,
                y: 0
            )
        }
        self.animator = animator
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.animator = nil
            if !commit {
                self.restoreSourceHierarchy()
            }
            completion()
        }
        animator.startAnimation()
    }

    func commitSelection(to tab: RootTab) {
        guard let tabBarController else {
            clearReferences()
            return
        }
        tabBarController.selectedIndex = tab.rawValue
        tabBarController.view.setNeedsLayout()
        tabBarController.view.layoutIfNeeded()

        sourceView?.transform = .identity
        destinationView?.transform = .identity
        sourceView?.frame = sourceFrame
        clearReferences()
        prewarmedSelection = nil
        schedulePrewarm(selectedIndex: tab.rawValue)
    }

    func cancelImmediately() {
        animator?.stopAnimation(true)
        animator = nil
        restoreSourceHierarchy()
    }

    private func restoreSourceHierarchy() {
        sourceView?.transform = .identity
        sourceView?.frame = sourceFrame
        destinationView?.transform = .identity
        returnDestinationBelowSource()
        transitionContainer?.setNeedsLayout()
        transitionContainer?.layoutIfNeeded()
        clearReferences()
    }

    private func returnDestinationBelowSource() {
        guard let destinationView,
              let sourceView,
              let container = sourceView.superview else {
            destinationView?.removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        destinationView.transform = .identity
        destinationView.frame = sourceFrame
        destinationView.autoresizingMask = sourceView.autoresizingMask
        if destinationView.superview !== container {
            destinationView.removeFromSuperview()
            container.insertSubview(destinationView, belowSubview: sourceView)
        } else {
            container.insertSubview(destinationView, belowSubview: sourceView)
        }
        CATransaction.commit()
        destinationView.setNeedsLayout()
        destinationView.layoutIfNeeded()
    }

    private func clearReferences() {
        sourceView = nil
        destinationView = nil
        transitionContainer = nil
        sourceFrame = .zero
        destination = nil
    }

    private func preloadPages() {
        guard let tabBarController else { return }
        rootControllers(in: tabBarController).forEach { $0.loadViewIfNeeded() }
    }

    /// Keep every inactive real tab view attached to the same content container
    /// directly underneath the selected, opaque root page. `loadViewIfNeeded()`
    /// alone is insufficient for SwiftUI: its first layer transaction otherwise
    /// happens only after a drag has already exposed the adjacent page. Keeping
    /// the views as direct siblings also avoids reparenting a live layer when a
    /// physical gesture begins.
    private func schedulePrewarm(selectedIndex: Int) {
        guard scheduledPrewarmSelection != selectedIndex else { return }
        prewarmGeneration += 1
        scheduledPrewarmSelection = selectedIndex
        let generation = prewarmGeneration
        DispatchQueue.main.async { [weak self] in
            self?.prewarmInactivePages(
                selectedIndex: selectedIndex,
                generation: generation,
                remainingRenderTurns: 3
            )
        }
    }

    private func prewarmInactivePages(
        selectedIndex: Int,
        generation: Int,
        remainingRenderTurns: Int
    ) {
        guard generation == prewarmGeneration,
              animator == nil,
              destination == nil,
              let tabBarController else { return }
        let controllers = rootControllers(in: tabBarController)
        guard controllers.indices.contains(selectedIndex) else { return }

        let selectedController = controllers[selectedIndex]
        selectedController.loadViewIfNeeded()
        let selectedView = selectedController.view!
        guard selectedView.window != nil,
              let container = selectedView.superview,
              selectedView.bounds.width > 1,
              selectedView.bounds.height > 1 else {
            guard remainingRenderTurns > 0 else {
                scheduledPrewarmSelection = nil
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.prewarmInactivePages(
                    selectedIndex: selectedIndex,
                    generation: generation,
                    remainingRenderTurns: remainingRenderTurns - 1
                )
            }
            return
        }

        for (index, controller) in controllers.enumerated() where index != selectedIndex {
            controller.loadViewIfNeeded()
            let view = controller.view!
            controller.beginAppearanceTransition(true, animated: false)
            view.transform = .identity
            if view.superview !== container {
                view.removeFromSuperview()
                container.insertSubview(view, belowSubview: selectedView)
            } else {
                container.insertSubview(view, belowSubview: selectedView)
            }
            view.frame = selectedView.frame
            view.autoresizingMask = selectedView.autoresizingMask
            view.setNeedsLayout()
            view.layoutIfNeeded()
            controller.endAppearanceTransition()
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
        }
        container.setNeedsLayout()
        container.layoutIfNeeded()

        // Leave the real pages connected for at least one more main render
        // turn. This is not a gesture delay: it happens ahead of interaction
        // and allows SwiftUI/Core Animation to commit their initial contents.
        guard remainingRenderTurns > 0 else {
            prewarmedSelection = selectedIndex
            scheduledPrewarmSelection = nil
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.prewarmInactivePages(
                selectedIndex: selectedIndex,
                generation: generation,
                remainingRenderTurns: remainingRenderTurns - 1
            )
        }
    }

    private func rootControllers(in tabBarController: UITabBarController) -> [UIViewController] {
        if #available(iOS 18.0, *), !tabBarController.tabs.isEmpty {
            return tabBarController.tabs.compactMap(\.viewController)
        }
        return tabBarController.viewControllers ?? []
    }
}

private struct RootTabControllerLocator: UIViewRepresentable {
    let pager: RootTabLivePagePager

    func makeUIView(context: Context) -> LocatorView {
        let view = LocatorView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.didMoveToWindowHandler = { [weak pager] view in
            guard let tabBarController = Self.tabBarController(from: view) else { return }
            pager?.attach(to: tabBarController)
        }
        return view
    }

    func updateUIView(_ uiView: LocatorView, context: Context) {
        guard let tabBarController = Self.tabBarController(from: uiView) else { return }
        pager.attach(to: tabBarController)
    }

    final class LocatorView: UIView {
        var didMoveToWindowHandler: ((LocatorView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            didMoveToWindowHandler?(self)
        }
    }

    private static func tabBarController(from view: UIView) -> UITabBarController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController,
               let tabBarController = (controller as? UITabBarController)
                ?? controller.tabBarController {
                return tabBarController
            }
            responder = current.next
        }
        return nil
    }
}

@MainActor
private final class RootTabDisplayRefreshGate {
    private var links: [UUID: RootTabOneShotDisplayLink] = [:]

    func waitForNextRefresh(token: UUID, completion: @escaping () -> Void) {
        cancel(token: token)
        let link = RootTabOneShotDisplayLink { [weak self] in
            self?.links[token] = nil
            completion()
        }
        links[token] = link
        link.start()
    }

    func cancel(token: UUID) {
        links.removeValue(forKey: token)?.invalidate()
    }
}

@MainActor
private final class RootTabOneShotDisplayLink: NSObject {
    private var displayLink: CADisplayLink?
    private var completion: (() -> Void)?

    init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(fire))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
        completion = nil
    }

    @objc private func fire() {
        displayLink?.invalidate()
        displayLink = nil
        let completion = completion
        self.completion = nil
        completion?()
    }
}

/// A zero-sized SwiftUI attachment that installs one scroll-only pan recognizer
/// on the current app window. `allowedTouchTypes = []` is intentional: screen
/// touches continue to use the existing SwiftUI DragGesture, while this bridge
/// receives only continuous mouse/trackpad scrolling.
@MainActor
private struct RootTabTrackpadPanBridge: UIViewRepresentable {
    let shouldBegin: (_ startLocation: CGPoint, _ velocity: CGPoint) -> Bool
    let onChanged: (_ startLocation: CGPoint, _ translation: CGSize) -> Void
    let onEnded: (
        _ startLocation: CGPoint,
        _ translation: CGSize,
        _ predictedEndTranslation: CGSize
    ) -> Void
    let onCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: self)
    }

    func makeUIView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.install(on: window)
        }
        return view
    }

    func updateUIView(_ uiView: WindowAttachmentView, context: Context) {
        context.coordinator.bridge = self
        context.coordinator.install(on: uiView.window)
    }

    static func dismantleUIView(_ uiView: WindowAttachmentView, coordinator: Coordinator) {
        uiView.windowDidChange = nil
        coordinator.install(on: nil)
    }

    final class WindowAttachmentView: UIView {
        var windowDidChange: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowDidChange?(window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var bridge: RootTabTrackpadPanBridge
        private weak var installedWindow: UIWindow?
        private var recognizer: UIPanGestureRecognizer?
        private var startLocation: CGPoint?

        init(bridge: RootTabTrackpadPanBridge) {
            self.bridge = bridge
        }

        func install(on window: UIWindow?) {
            guard installedWindow !== window else { return }
            if let recognizer, let installedWindow {
                installedWindow.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            installedWindow = window
            startLocation = nil

            guard let window else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.allowedScrollTypesMask = .continuous
            pan.allowedTouchTypes = []
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delegate = self
            pan.name = "JMComic.RootTabTrackpadPaging"
            window.addGestureRecognizer(pan)
            recognizer = pan
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let window = installedWindow else { return false }
            let location = pan.location(in: window)
            let velocity = pan.velocity(in: window)
            let allowed = bridge.shouldBegin(location, velocity)
            startLocation = allowed ? location : nil
            return allowed
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let window = installedWindow else { return }
            let point = pan.translation(in: window)
            let translation = CGSize(width: point.x, height: point.y)
            let location = startLocation ?? pan.location(in: window)

            switch pan.state {
            case .began, .changed:
                startLocation = location
                bridge.onChanged(location, translation)
            case .ended:
                let predicted = RootTabTrackpadPolicy.predictedEndTranslation(
                    translation: translation,
                    velocity: pan.velocity(in: window)
                )
                bridge.onEnded(location, translation, predicted)
                startLocation = nil
            case .cancelled, .failed:
                bridge.onCancelled()
                startLocation = nil
            case .possible:
                break
            @unknown default:
                bridge.onCancelled()
                startLocation = nil
            }
        }
    }
}

extension View {
    /// 只应挂在每个标签的一级内容上，不要挂在 `NavigationStack`
    /// 本身。调用方必须把显式 SwiftUI 导航路径是否为空传入
    /// `isEnabled`；任意二级页存在时关闭根 Tab 手势，让系统边缘右滑独占。
    func rootTabSwipe(
        selection: Binding<RootTab>,
        from source: RootTab,
        isEnabled: Bool = true
    ) -> some View {
        modifier(RootTabSwipeModifier(
            source: source,
            isEnabled: isEnabled
        ))
    }

    /// 标记一级页中需要自己处理水平拖动的局部区域。
    func rootTabSwipeExclusion() -> some View {
        modifier(RootTabSwipeExclusionModifier())
    }

    fileprivate func rootTabTransitionContainer(for tab: RootTab) -> some View {
        modifier(RootTabTransitionContainerModifier(tab: tab))
    }

    /// iOS 26 owns the complete floating liquid-glass tab bar. Forcing a
    /// toolbar background there turns its transparent outer capsule into an
    /// opaque band. Older systems still need the explicit palette fallback
    /// because their non-floating tab bar otherwise defaults to white.
    @ViewBuilder
    fileprivate func rootTabBarChromeFallback(_ background: Color) -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self
                .toolbarBackground(background, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }
}

/// Preserved temporarily as a compile-time reference while the resident-page
/// implementation below replaces the old snapshot/live-controller experiments.
/// Nothing in the app instantiates this view.
private struct LegacyRootView: View {
    @EnvironmentObject private var appearance: AppAppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var readerIsPresented = false
    @State private var selectedTab: RootTab = .explore
    @State private var exploreNavigationPath: [AppNavigationRoute] = []
    @State private var searchNavigationPath: [AppNavigationRoute] = []
    // The downloads stack can push both download-only destinations and the
    // shared comic/search destinations reached from an online detail page.
    // NavigationPath keeps that mixed route chain observable so every
    // secondary page still gives the system pop gesture exclusive ownership.
    @State private var downloadsNavigationPath = NavigationPath()
    @State private var accountNavigationPath: [AppNavigationRoute] = []
    @State private var visualTransition = RootTabVisualTransition()
    @State private var interactiveTransition: RootTabInteractiveTransition?
    @State private var isSettlingRootTransition = false
    @State private var rootGlobalFrame: CGRect = .zero
    @State private var snapshotter = RootTabVisiblePageSnapshotter()
    @State private var swipeRegistry = RootTabSwipeRegistry()
    @State private var gestureLifecycle = RootTabGestureLifecycle()
    @State private var selectionMutationGate = RootTabSelectionMutationGate()
    @State private var displayRefreshGate = RootTabDisplayRefreshGate()
    @State private var livePagePager = RootTabLivePagePager()
    @State private var livePageTransition: RootTabLivePageTransition?

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("发现", systemImage: "sparkles", value: RootTab.explore) {
                NavigationStack(path: $exploreNavigationPath) {
                    ExploreView()
                        .appNavigationDestinations()
                        .rootTabSwipe(
                            selection: $selectedTab,
                            from: .explore,
                            isEnabled: RootNavigationPathPolicy.allowsRootTabSwipe(
                                path: exploreNavigationPath
                            )
                        )
                }
                .rootTabTransitionContainer(for: .explore)
                .background { rootTabControllerLocator }
            }
            Tab("搜索", systemImage: "magnifyingglass", value: RootTab.search) {
                NavigationStack(path: $searchNavigationPath) {
                    SearchView()
                        .appNavigationDestinations()
                        .rootTabSwipe(
                            selection: $selectedTab,
                            from: .search,
                            isEnabled: RootNavigationPathPolicy.allowsRootTabSwipe(
                                path: searchNavigationPath
                            )
                        )
                }
                .rootTabTransitionContainer(for: .search)
                .background { rootTabControllerLocator }
            }
            Tab("收藏", systemImage: "heart", value: RootTab.favorites) {
                FavoritesView()
                    .rootTabTransitionContainer(for: .favorites)
                    .background { rootTabControllerLocator }
            }
            Tab("下载", systemImage: "arrow.down.circle", value: RootTab.downloads) {
                NavigationStack(path: $downloadsNavigationPath) {
                    DownloadsView(navigationPath: $downloadsNavigationPath)
                        .rootTabSwipe(
                            selection: $selectedTab,
                            from: .downloads,
                            isEnabled: DownloadsNavigationPolicy.allowsRootTabSwipe(
                                pathCount: downloadsNavigationPath.count
                            )
                        )
                }
                .rootTabTransitionContainer(for: .downloads)
                .background { rootTabControllerLocator }
            }
            Tab("我的", systemImage: "person.crop.circle", value: RootTab.account) {
                NavigationStack(path: $accountNavigationPath) {
                    AccountView()
                        .appNavigationDestinations()
                        .rootTabSwipe(
                            selection: $selectedTab,
                            from: .account,
                            isEnabled: RootNavigationPathPolicy.allowsRootTabSwipe(
                                path: accountNavigationPath
                            )
                        )
                }
                .rootTabTransitionContainer(for: .account)
                .background { rootTabControllerLocator }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(\.readerIsPresented, $readerIsPresented)
        .environment(\.rootTabSelection, $selectedTab)
        .environment(\.rootTabVisualTransition, visualTransition)
        .environment(\.rootTabSnapshotter, snapshotter)
        .environment(\.rootTabSwipeRegistry, swipeRegistry)
        .toolbar(readerIsPresented ? .hidden : .visible, for: .tabBar)
        .tint(.accentColor)
        .background(appearance.background(for: colorScheme).ignoresSafeArea())
        .rootTabBarChromeFallback(appearance.background(for: colorScheme))
        .background {
            rootTabTrackpadBridge
        }
        .onChange(of: selectedTab) { _, newSelection in
            if selectionMutationGate.consume(newSelection) { return }
            guard livePageTransition != nil else { return }
            // A tab-bar tap during a transition is external input and wins.
            invalidateLivePageTransition()
        }
        .simultaneousGesture(rootTabDragGesture)
    }

    private var rootTabControllerLocator: some View {
        RootTabControllerLocator(pager: livePagePager)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var rootTabTrackpadBridge: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            RootTabTrackpadPanBridge(
                shouldBegin: { startLocation, velocity in
                    trackpadGestureShouldBegin(
                        at: startLocation,
                        velocity: velocity
                    )
                },
                onChanged: { startLocation, translation in
                    if livePageTransition == nil {
                        beginLivePageTransition(
                            startLocation: startLocation,
                            translation: translation
                        )
                    } else {
                        updateLivePageTransition(translation: translation)
                    }
                },
                onEnded: { _, translation, predictedEndTranslation in
                    finishLivePageTransition(
                        translation: translation,
                        predictedEndTranslation: predictedEndTranslation
                    )
                },
                onCancelled: {
                    finishLivePageTransition(
                        translation: .zero,
                        predictedEndTranslation: .zero
                    )
                }
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var sourcePageOverlay: some View {
        if let transition = interactiveTransition {
            let sourceFrame = RootTabSnapshotPolicy.expandedSourceFrame(
                viewportFrame: transition.viewportFrame,
                destinationBaseOffset: transition.destinationBaseOffset,
                screenScale: transition.sourceScale
            )
            ZStack(alignment: .topLeading) {
                // Moving the real destination NavigationStack exposes the
                // TabView host underneath the status bar. UIKit's host uses a
                // white default there, so keep one palette-coloured strip
                // stationary while the two page bodies move underneath it.
                // The system continues to draw the clock / Dynamic Island /
                // signal icons above this background.
                if transition.stationaryTopHeight > 0 {
                    appearance.background(for: colorScheme)
                        .frame(
                            width: rootGlobalFrame.width,
                            // Only the status-area palette is painted here.
                            // iPad's top liquid-glass tab bar owns this edge,
                            // so that presentation deliberately uses no
                            // foreground status fill at all.
                            height: transition.stationaryTopHeight
                        )
                        .ignoresSafeArea(edges: .top)
                }

                ZStack(alignment: .topLeading) {
                    if let destinationView = transition.destinationView {
                        RootTabDestinationSnapshotContentView(
                            contentView: destinationView,
                            token: transition.token,
                            onInstalled: destinationSnapshotDidInstall
                        )
                            .frame(
                                width: transition.viewportFrame.width,
                                height: transition.viewportFrame.height
                            )
                            .offset(x: transition.destinationOffset)
                    }

                    RootTabSnapshotContentView(
                        contentView: transition.sourceView,
                        token: transition.token,
                        onInstalled: sourceSnapshotDidInstall
                    )
                        .frame(
                            width: sourceFrame.width,
                            height: sourceFrame.height
                        )
                        .offset(
                            x: sourceFrame.minX
                                - transition.viewportFrame.minX
                                + transition.sourceOffset,
                            y: sourceFrame.minY - transition.viewportFrame.minY
                        )
                }
                    .frame(
                        width: transition.viewportFrame.width,
                        height: transition.viewportFrame.height,
                        alignment: .topLeading
                    )
                    // A moving page must never spill over a stationary iPad
                    // sidebar/top bar (or the iPhone floating bottom bar).
                    .clipped()
                    .position(
                        x: transition.viewportFrame.midX - rootGlobalFrame.minX,
                        y: transition.viewportFrame.midY - rootGlobalFrame.minY
                    )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var rootTabDragGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                if livePageTransition == nil {
                    beginLivePageTransition(
                        startLocation: value.startLocation,
                        translation: value.translation
                    )
                } else {
                    updateLivePageTransition(translation: value.translation)
                }
            }
            .onEnded { value in
                finishLivePageTransition(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                )
            }
    }

    private func trackpadGestureShouldBegin(
        at startLocation: CGPoint,
        velocity: CGPoint
    ) -> Bool {
        guard !readerIsPresented,
              livePageTransition?.isSettling != true,
              livePageTransition == nil,
              !gestureLifecycle.isActive,
              RootTabTrackpadPolicy.isHorizontal(velocity: velocity),
              RootTabSwipePolicy.adjacentTab(
                from: selectedTab,
                horizontalTranslation: velocity.x
              ) != nil,
              activeSwipeSurface(at: startLocation) != nil else { return false }
        return true
    }

    private func activeSwipeSurface(at startLocation: CGPoint) -> RootTabSwipeSurface? {
        swipeRegistry.activeSurface(for: selectedTab, at: startLocation)
    }

    private func beginLivePageTransition(
        startLocation: CGPoint,
        translation: CGSize
    ) {
        guard !readerIsPresented,
              livePageTransition == nil,
              abs(translation.width) >= RootTabSwipePolicy.activationTranslation,
              abs(translation.width) > abs(translation.height)
                * RootTabSwipePolicy.horizontalDominance,
              activeSwipeSurface(at: startLocation) != nil else { return }

        guard let destination = RootTabSwipePolicy.adjacentTab(
            from: selectedTab,
            horizontalTranslation: translation.width
        ), gestureLifecycle.begin() else { return }

        let source = selectedTab
        guard let width = livePagePager.begin(
            source: source,
            destination: destination
        ) else {
            gestureLifecycle.end()
            return
        }
        let offset = RootTabSwipePolicy.interactiveOffset(
            from: source,
            translation: translation,
            viewportWidth: width
        )
        livePageTransition = RootTabLivePageTransition(
            source: source,
            destination: destination,
            viewportWidth: width,
            offset: offset
        )
        livePagePager.update(offset: offset, viewportWidth: width)
    }

    private func updateLivePageTransition(translation: CGSize) {
        guard var transition = livePageTransition,
              !transition.isSettling else { return }
        let proposed = RootTabSwipePolicy.interactiveOffset(
            from: transition.source,
            translation: translation,
            viewportWidth: transition.viewportWidth
        )
        transition.offset = transition.destination.rawValue > transition.source.rawValue
            ? min(0, proposed) : max(0, proposed)
        livePageTransition = transition
        livePagePager.update(
            offset: transition.offset,
            viewportWidth: transition.viewportWidth
        )
    }

    private func finishLivePageTransition(
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) {
        guard var transition = livePageTransition,
              !transition.isSettling else {
            gestureLifecycle.end()
            return
        }
        let destination = RootTabSwipePolicy.destination(
            from: transition.source,
            translation: translation,
            predictedEndTranslation: predictedEndTranslation
        )
        let shouldCommit = destination == transition.destination
        transition.isSettling = true
        livePageTransition = transition

        livePagePager.settle(
            commit: shouldCommit,
            viewportWidth: transition.viewportWidth
        ) {
            if shouldCommit {
                selectionMutationGate.expect(transition.destination)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    selectedTab = transition.destination
                }
                livePagePager.commitSelection(to: transition.destination)
            }
            livePageTransition = nil
            gestureLifecycle.end()
        }
    }

    private func invalidateLivePageTransition() {
        livePagePager.cancelImmediately()
        livePageTransition = nil
        selectionMutationGate.clear()
        gestureLifecycle.end()
    }

    private func beginInteractiveTransition(
        startLocation: CGPoint,
        translation: CGSize
    ) {
        guard !readerIsPresented,
              !isSettlingRootTransition,
              abs(translation.width) >= RootTabSwipePolicy.activationTranslation,
              let surface = activeSwipeSurface(at: startLocation) else { return }

        let offset = RootTabSwipePolicy.interactiveOffset(
            from: selectedTab,
            translation: translation,
            viewportWidth: surface.frame.width
        )
        guard offset != 0,
              let destination = RootTabSwipePolicy.adjacentTab(
                from: selectedTab,
                horizontalTranslation: offset
              ),
              gestureLifecycle.begin() else { return }

        guard let snapshot = snapshotter.visibleSnapshot(
                for: selectedTab,
                matching: surface.frame,
                backgroundColor: UIColor(appearance.background(for: colorScheme))
              ) else {
            gestureLifecycle.end()
            return
        }

        let source = selectedTab
        let viewportFrame = snapshot.frame
        let trackedOffset = RootTabSwipePolicy.interactiveOffset(
            from: source,
            translation: translation,
            viewportWidth: viewportFrame.width
        )
        let baseOffset = destination.rawValue > source.rawValue
            ? viewportFrame.width : -viewportFrame.width
        let token = UUID()
        interactiveTransition = RootTabInteractiveTransition(
            token: token,
            source: source,
            destination: destination,
            sourceView: snapshot.contentView,
            sourceScale: snapshot.screenScale,
            viewportFrame: viewportFrame,
            stationaryTopHeight: snapshot.stationaryTopHeight,
            destinationBaseOffset: baseOffset,
            destinationView: nil,
            sourceOffset: 0,
            destinationOffset: baseOffset,
            pendingSourceOffset: trackedOffset,
            phase: .installingSourceSnapshot,
            endDecision: nil
        )
        visualTransition = RootTabVisualTransition(
            incomingTab: destination,
            incomingOffset: baseOffset
        )
        traceRootTabTransition(
            "begin token=\(token) source=\(source.rawValue) destination=\(destination.rawValue) offset=\(trackedOffset)"
        )
    }

    private func updateInteractiveTransition(translation: CGSize) {
        guard !isSettlingRootTransition,
              var transition = interactiveTransition else { return }
        let proposed = RootTabSwipePolicy.interactiveOffset(
            from: transition.source,
            translation: translation,
            viewportWidth: transition.viewportFrame.width
        )

        // 手指退回起点时可以取消，但一次手势不会在两个目的 Tab
        // 之间来回重选，避免频繁触发 onAppear/数据加载。
        let directionalOffset = transition.destinationBaseOffset > 0
            ? min(0, proposed) : max(0, proposed)
        transition.pendingSourceOffset = directionalOffset
        if transition.phase == .interactive {
            transition.sourceOffset = directionalOffset
            transition.destinationOffset = transition.destinationBaseOffset
                + directionalOffset
        }
        interactiveTransition = transition
    }

    private func finishInteractiveTransition(
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) {
        guard let transition = interactiveTransition,
              transition.phase != .settling,
              transition.phase != .installingCommittedDestination else { return }
        let destination = RootTabSwipePolicy.destination(
            from: transition.source,
            translation: translation,
            predictedEndTranslation: predictedEndTranslation
        )
        let shouldCommit = destination == transition.destination
        traceRootTabTransition(
            "end token=\(transition.token) phase=\(transition.phase) commit=\(shouldCommit) offset=\(transition.pendingSourceOffset)"
        )
        var decided = transition
        decided.endDecision = shouldCommit
        interactiveTransition = decided

        switch decided.phase {
        case .installingSourceSnapshot:
            if !shouldCommit {
                completeUnselectedCancelledTransition(token: decided.token)
            }
        case .preparingDestination:
            if !shouldCommit {
                restoreSourceWithoutReveal(decided)
            }
        case .installingDestinationSnapshot:
            // Readiness callbacks finish installing both deterministic page
            // snapshots. The physical gesture decision is consumed exactly
            // once when that preparation completes.
            break
        case .interactive:
            if shouldCommit {
                commitInteractiveTransition(decided)
            } else {
                cancelInteractiveTransition(decided)
            }
        case .settling, .installingCommittedDestination:
            break
        }
    }

    private func sourceSnapshotDidInstall(_ token: UUID) {
        guard let transition = interactiveTransition,
              transition.token == token,
              transition.phase == .installingSourceSnapshot else { return }
        traceRootTabTransition("source-installed token=\(token)")

        // Being attached to a window is necessary but not sufficient: SwiftUI
        // may still install the overlay and mutate TabView selection in the
        // same compositor transaction. Wait for one real display refresh so
        // the opaque source snapshot is guaranteed to have reached screen.
        displayRefreshGate.waitForNextRefresh(token: token) {
            sourceSnapshotDidReachDisplay(token)
        }
    }

    private func sourceSnapshotDidReachDisplay(_ token: UUID) {
        guard var transition = interactiveTransition,
              transition.token == token,
              transition.phase == .installingSourceSnapshot else { return }
        traceRootTabTransition(
            "source-displayed token=\(token) decision=\(String(describing: transition.endDecision))"
        )

        switch RootTabTransitionPreparationPolicy.sourceSnapshotInstalledAction(
            endDecision: transition.endDecision
        ) {
        case .discardWithoutSelectingDestination:
            completeUnselectedCancelledTransition(token: token)
        case .prepareDestination:
            transition.phase = .preparingDestination
            interactiveTransition = transition
            snapshotter.waitForSelectedAnchor(
                for: transition.destination,
                token: token,
                matching: transition.viewportFrame,
                completion: destinationAnchorDidBecomeReady
            )
            traceRootTabTransition("select-destination token=\(token)")
            setSelectedTabInternally(transition.destination)
        default:
            break
        }
    }

    private func destinationAnchorDidBecomeReady(_ token: UUID) {
        guard let transition = interactiveTransition,
              transition.token == token,
              transition.phase == .preparingDestination,
              selectedTab == transition.destination else { return }
        traceRootTabTransition(
            "destination-anchor token=\(token) decision=\(String(describing: transition.endDecision))"
        )

        let action = RootTabTransitionPreparationPolicy.destinationReadyAction(
            endDecision: transition.endDecision
        )
        guard action != .restoreSourceWithoutReveal else {
            restoreSourceWithoutReveal(transition)
            return
        }

        // Render the real destination at its final geometry while the opaque
        // source snapshot still covers the viewport. The next refresh can
        // then be captured without ever exposing a recycled source host.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            visualTransition.incomingOffset = 0
        }
        displayRefreshGate.waitForNextRefresh(token: token) {
            destinationDidReachDisplay(token)
        }
    }

    private func destinationDidReachDisplay(_ token: UUID) {
        guard var transition = interactiveTransition,
              transition.token == token,
              transition.phase == .preparingDestination,
              selectedTab == transition.destination else { return }
        traceRootTabTransition(
            "destination-displayed token=\(token) decision=\(String(describing: transition.endDecision))"
        )

        guard snapshotter.hasConfirmedSelectedAnchor(
            for: transition.destination,
            matching: transition.viewportFrame
        ) else {
            snapshotter.waitForSelectedAnchor(
                for: transition.destination,
                token: token,
                matching: transition.viewportFrame,
                completion: destinationAnchorDidBecomeReady
            )
            return
        }

        let action = RootTabTransitionPreparationPolicy.destinationReadyAction(
            endDecision: transition.endDecision
        )
        guard action != .restoreSourceWithoutReveal else {
            restoreSourceWithoutReveal(transition)
            return
        }

        guard let destinationSnapshot = snapshotter.selectedContentSnapshot(
            for: transition.destination,
            matching: transition.viewportFrame,
            backgroundColor: UIColor(appearance.background(for: colorScheme))
        ) else {
            // A transition without a confirmed destination image is exactly
            // what produced the old-page flash. Keep the source opaque and
            // safely cancel this physical gesture instead of guessing.
            restoreSourceWithoutReveal(transition)
            return
        }

        transition.destinationView = destinationSnapshot.contentView
        transition.destinationOffset = transition.destinationBaseOffset
        transition.phase = .installingDestinationSnapshot
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            interactiveTransition = transition
            visualTransition.incomingOffset = transition.destinationBaseOffset
        }
        traceRootTabTransition("destination-captured token=\(token)")
    }

    private func destinationSnapshotDidInstall(_ token: UUID) {
        guard let transition = interactiveTransition,
              transition.token == token,
              transition.phase == .installingDestinationSnapshot,
              transition.destinationView != nil else { return }
        traceRootTabTransition("destination-snapshot-installed token=\(token)")

        displayRefreshGate.waitForNextRefresh(token: token) {
            destinationSnapshotDidReachDisplay(token)
        }
    }

    private func destinationSnapshotDidReachDisplay(_ token: UUID) {
        guard var transition = interactiveTransition,
              transition.token == token,
              transition.phase == .installingDestinationSnapshot,
              transition.destinationView != nil,
              selectedTab == transition.destination else { return }

        transition.phase = .interactive
        transition.sourceOffset = transition.pendingSourceOffset
        transition.destinationOffset = transition.destinationBaseOffset
            + transition.pendingSourceOffset
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            interactiveTransition = transition
        }
        traceRootTabTransition("two-page-interactive token=\(token)")

        switch transition.endDecision {
        case true:
            commitInteractiveTransition(transition)
        case false:
            cancelInteractiveTransition(transition)
        case nil:
            break
        }
    }

    private func commitInteractiveTransition(_ transition: RootTabInteractiveTransition) {
        guard var current = interactiveTransition,
              current.token == transition.token,
              current.phase == .interactive else { return }
        isSettlingRootTransition = true
        current.phase = .settling
        current.endDecision = true
        interactiveTransition = current
        let overlap = RootTabSnapshotPolicy.seamOverlap(
            screenScale: transition.sourceScale
        )
        // Move the deliberately overlapped edge completely offscreen at the
        // end, so it cannot leave a stale sub-pixel strip over the destination.
        let outgoingOffset = -transition.destinationBaseOffset
            - copysign(overlap, transition.destinationBaseOffset)
        withAnimation(
            .spring(response: 0.30, dampingFraction: 0.90),
            completionCriteria: .removed
        ) {
            guard var current = interactiveTransition, current.token == transition.token else { return }
            current.sourceOffset = outgoingOffset
            current.destinationOffset = 0
            interactiveTransition = current
        } completion: {
            installCommittedDestination(token: transition.token)
        }
    }

    private func cancelInteractiveTransition(_ transition: RootTabInteractiveTransition) {
        guard var current = interactiveTransition,
              current.token == transition.token,
              current.phase == .interactive else { return }
        traceRootTabTransition("cancel-two-page token=\(transition.token)")
        isSettlingRootTransition = true
        current.phase = .settling
        current.endDecision = false
        interactiveTransition = current

        // Both page images remain stable for the complete return animation.
        // Only after the source snapshot again covers the viewport do we
        // restore the real source hierarchy underneath it.
        withAnimation(
            .spring(response: 0.30, dampingFraction: 0.90),
            completionCriteria: .removed
        ) {
            guard var current = interactiveTransition,
                  current.token == transition.token,
                  current.phase == .settling,
                  current.endDecision == false else { return }
            current.sourceOffset = 0
            current.destinationOffset = current.destinationBaseOffset
            interactiveTransition = current
        } completion: {
            restoreSourceSelectionKeepingSnapshot(transition)
        }
    }

    private func restoreSourceWithoutReveal(_ transition: RootTabInteractiveTransition) {
        guard interactiveTransition?.token == transition.token else { return }
        traceRootTabTransition("cancel-before-reveal token=\(transition.token)")
        isSettlingRootTransition = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            guard var current = interactiveTransition,
                  current.token == transition.token else { return }
            current.sourceOffset = 0
            current.destinationOffset = current.destinationBaseOffset
            current.pendingSourceOffset = 0
            current.phase = .settling
            current.endDecision = false
            interactiveTransition = current
            visualTransition.incomingOffset = transition.destinationBaseOffset
        }
        restoreSourceSelectionKeepingSnapshot(transition)
    }

    private func installCommittedDestination(token: UUID) {
        guard var transition = interactiveTransition,
              transition.token == token,
              transition.phase == .settling,
              transition.endDecision == true,
              selectedTab == transition.destination else { return }
        transition.phase = .installingCommittedDestination
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            interactiveTransition = transition
            visualTransition.incomingOffset = 0
        }
        displayRefreshGate.waitForNextRefresh(token: token) {
            committedDestinationDidReachDisplay(token)
        }
    }

    private func committedDestinationDidReachDisplay(_ token: UUID) {
        guard let transition = interactiveTransition,
              transition.token == token,
              transition.phase == .installingCommittedDestination,
              transition.endDecision == true,
              selectedTab == transition.destination else { return }

        guard snapshotter.hasConfirmedSelectedAnchor(
            for: transition.destination,
            matching: transition.viewportFrame
        ) else {
            snapshotter.waitForSelectedAnchor(
                for: transition.destination,
                token: token,
                matching: transition.viewportFrame,
                completion: committedDestinationAnchorDidBecomeReady
            )
            return
        }
        completeCommittedTransition(transition)
    }

    private func committedDestinationAnchorDidBecomeReady(_ token: UUID) {
        guard let transition = interactiveTransition,
              transition.token == token,
              transition.phase == .installingCommittedDestination,
              selectedTab == transition.destination else { return }
        displayRefreshGate.waitForNextRefresh(token: token) {
            committedDestinationDidReachDisplay(token)
        }
    }

    private func completeCommittedTransition(_ transition: RootTabInteractiveTransition) {
        guard let current = interactiveTransition,
              current.token == transition.token,
              current.phase == .installingCommittedDestination,
              current.endDecision == true,
              selectedTab == transition.destination else { return }
        snapshotter.cancelAnchorWait(token: transition.token)
        displayRefreshGate.cancel(token: transition.token)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            interactiveTransition = nil
            visualTransition = RootTabVisualTransition()
            isSettlingRootTransition = false
        }
        selectionMutationGate.clear()
        gestureLifecycle.end()
    }

    /// Keep the opaque source snapshot installed while TabView restores its
    /// real source hosting view. Snapshot teardown happens on a later render
    /// turn, never in the same transaction as the selection rollback.
    private func restoreSourceSelectionKeepingSnapshot(
        _ transition: RootTabInteractiveTransition
    ) {
        guard let current = interactiveTransition,
              current.token == transition.token,
              current.phase == .settling else { return }
        traceRootTabTransition("select-source token=\(transition.token)")
        snapshotter.cancelAnchorWait(token: transition.token)
        snapshotter.waitForSelectedAnchor(
            for: transition.source,
            token: transition.token,
            matching: transition.viewportFrame,
            completion: sourceAnchorDidRestore
        )
        setSelectedTabInternally(transition.source)
    }

    private func sourceAnchorDidRestore(_ token: UUID) {
        guard let transition = interactiveTransition,
              transition.token == token,
              transition.phase == .settling,
              transition.endDecision == false,
              selectedTab == transition.source else { return }
        traceRootTabTransition("source-anchor token=\(token)")
        waitForStableSourceRefresh(token: token, remainingRefreshes: 2)
    }

    private func waitForStableSourceRefresh(
        token: UUID,
        remainingRefreshes: Int
    ) {
        guard let transition = interactiveTransition,
              transition.token == token,
              transition.phase == .settling,
              transition.endDecision == false,
              selectedTab == transition.source else { return }

        displayRefreshGate.waitForNextRefresh(token: token) {
            guard let current = interactiveTransition,
                  current.token == token,
                  current.phase == .settling,
                  current.endDecision == false,
                  selectedTab == current.source else { return }

            traceRootTabTransition(
                "source-refresh token=\(token) remaining=\(remainingRefreshes)"
            )

            guard snapshotter.hasConfirmedSelectedAnchor(
                for: current.source,
                matching: current.viewportFrame
            ) else {
                snapshotter.waitForSelectedAnchor(
                    for: current.source,
                    token: token,
                    matching: current.viewportFrame,
                    completion: sourceAnchorDidRestore
                )
                return
            }

            if remainingRefreshes > 1 {
                waitForStableSourceRefresh(
                    token: token,
                    remainingRefreshes: remainingRefreshes - 1
                )
            } else {
                completeCancelledTransition(token: token)
            }
        }
    }

    private func completeCancelledTransition(token: UUID) {
        guard let transition = interactiveTransition,
              transition.token == token,
              transition.phase == .settling,
              transition.endDecision == false,
              selectedTab == transition.source else { return }
        traceRootTabTransition("cancel-cleanup token=\(token)")
        snapshotter.cancelAnchorWait(token: token)
        displayRefreshGate.cancel(token: token)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            interactiveTransition = nil
            visualTransition = RootTabVisualTransition()
            isSettlingRootTransition = false
        }
        selectionMutationGate.clear()
        gestureLifecycle.end()
    }

    private func completeUnselectedCancelledTransition(token: UUID) {
        guard let transition = interactiveTransition,
              transition.token == token,
              transition.phase == .installingSourceSnapshot,
              selectedTab == transition.source else { return }
        traceRootTabTransition("cancel-before-selection token=\(token)")
        snapshotter.cancelAnchorWait(token: token)
        displayRefreshGate.cancel(token: token)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            interactiveTransition = nil
            visualTransition = RootTabVisualTransition()
            isSettlingRootTransition = false
        }
        selectionMutationGate.clear()
        gestureLifecycle.end()
    }

    private func setSelectedTabInternally(_ tab: RootTab) {
        guard selectedTab != tab else { return }
        selectionMutationGate.expect(tab)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedTab = tab
        }
    }

    private func rootFrameChangedSignificantly(_ old: CGRect, _ new: CGRect) -> Bool {
        guard old.width > 1, old.height > 1 else { return false }
        return abs(old.minX - new.minX) > 1
            || abs(old.minY - new.minY) > 1
            || abs(old.width - new.width) > 1
            || abs(old.height - new.height) > 1
    }

    private func cancelTransitionForGeometryChange(
        _ transition: RootTabInteractiveTransition
    ) {
        guard interactiveTransition?.token == transition.token else { return }
        traceRootTabTransition("geometry-cancel token=\(transition.token)")
        if transition.phase == .installingSourceSnapshot,
           selectedTab == transition.source {
            completeUnselectedCancelledTransition(token: transition.token)
            return
        }
        isSettlingRootTransition = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            guard var current = interactiveTransition,
                  current.token == transition.token else { return }
            current.sourceOffset = 0
            current.destinationOffset = current.destinationBaseOffset
            current.pendingSourceOffset = 0
            current.phase = .settling
            current.endDecision = false
            interactiveTransition = current
            visualTransition.incomingOffset = transition.destinationBaseOffset
        }
        if selectedTab == transition.destination || selectedTab == transition.source {
            restoreSourceSelectionKeepingSnapshot(transition)
        } else {
            invalidateInteractiveTransition()
        }
    }

    private func invalidateInteractiveTransition() {
        traceRootTabTransition("invalidate token=\(String(describing: interactiveTransition?.token))")
        if let token = interactiveTransition?.token {
            snapshotter.cancelAnchorWait(token: token)
            displayRefreshGate.cancel(token: token)
        }
        interactiveTransition = nil
        visualTransition = RootTabVisualTransition()
        isSettlingRootTransition = false
        selectionMutationGate.clear()
        gestureLifecycle.end()
    }

    private func traceRootTabTransition(_ message: String) {
#if DEBUG
        rootTabTransitionLogger.notice("\(message, privacy: .public)")
#endif
    }
}

// MARK: - Resident root pages

/// All five root pages live in this one state object and one SwiftUI hierarchy.
/// A system tab selection therefore never creates, swaps or reparents a feature
/// page. It only changes which already-rendered page is visible.
@MainActor
private final class RootResidentState: ObservableObject {
    @Published var selectedTab: RootTab = .explore
    @Published var readerIsPresented = false
    @Published var exploreNavigationPath: [AppNavigationRoute] = []
    @Published var searchNavigationPath: [AppNavigationRoute] = []
    @Published var downloadsNavigationPath = NavigationPath()
    @Published var accountNavigationPath: [AppNavigationRoute] = []

    var selectedTabBinding: Binding<RootTab> {
        Binding(
            get: { [weak self] in self?.selectedTab ?? .explore },
            set: { [weak self] in self?.selectedTab = $0 }
        )
    }

    var readerPresentationBinding: Binding<Bool> {
        Binding(
            get: { [weak self] in self?.readerIsPresented ?? false },
            set: { [weak self] in self?.readerIsPresented = $0 }
        )
    }
}

private struct RootResidentTransition: Equatable {
    let token: UUID
    let source: RootTab
    let destination: RootTab
    let viewportWidth: CGFloat
    var offset: CGFloat
    var isSettling = false
}

/// One stable hosting controller owns the real page deck. The native TabView
/// below still owns iPhone's liquid-glass tab bar and iPad's adaptive top/sidebar
/// chrome, but its lazily-created tab children are only zero-cost locators.
///
/// The host is installed once above UITabBarController's persistent content
/// transition view. Its layer remains above every placeholder tab child, so a
/// system selection change can never expose a stale, blank or recycled page.
@MainActor
private final class RootResidentPageHostStore: ObservableObject {
    private var hostingController: UIHostingController<AnyView>?
    private weak var contentContainer: UIView?

    func install(from locator: UIView, content: AnyView) {
        guard locator.window != nil,
              let tabBarController = Self.tabBarController(from: locator) else { return }

        tabBarController.loadViewIfNeeded()
        guard let selectedController = tabBarController.selectedViewController else { return }
        selectedController.loadViewIfNeeded()
        tabBarController.view.layoutIfNeeded()

        guard let selectedView = selectedController.view,
              let container = Self.persistentContentContainer(
                for: selectedView,
                in: tabBarController
              ) else { return }

        let host: UIHostingController<AnyView>
        if let hostingController {
            host = hostingController
        } else {
            let created = UIHostingController(rootView: content)
            created.view.backgroundColor = .clear
            created.view.clipsToBounds = true
            created.view.translatesAutoresizingMaskIntoConstraints = true
            hostingController = created
            host = created
        }

        let hostView = host.view!
        if hostView.superview !== container {
            hostView.removeFromSuperview()
            container.addSubview(hostView)
            contentContainer = container
        }

        // UIKit may insert a newly-selected placeholder above existing
        // siblings. A stable layer level inside the content-only transition
        // container keeps the resident pages visible without covering the
        // system tab/sidebar chrome, which lives outside this container.
        hostView.layer.zPosition = 100
        hostView.frame = container.bounds
        hostView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostView.isHidden = false
        hostView.setNeedsLayout()
    }

    private static func persistentContentContainer(
        for selectedView: UIView,
        in tabBarController: UITabBarController
    ) -> UIView? {
        var candidate = selectedView.superview
        var highestBelowTabRoot: UIView?
        while let current = candidate, current !== tabBarController.view {
            highestBelowTabRoot = current
            candidate = current.superview
        }

        // UITabBarController's direct content transition view persists while
        // its selected child changes. Installing here avoids moving the real
        // SwiftUI hierarchy between lazy tab controllers.
        return highestBelowTabRoot ?? selectedView.superview
    }

    private static func tabBarController(from view: UIView) -> UITabBarController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController,
               let tabBarController = (controller as? UITabBarController)
                ?? controller.tabBarController {
                return tabBarController
            }
            responder = current.next
        }
        return nil
    }
}

@MainActor
private struct RootResidentHostLocator: UIViewRepresentable {
    let store: RootResidentPageHostStore
    let content: AnyView

    func makeUIView(context: Context) -> LocatorView {
        let view = LocatorView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.windowDidChange = { [weak store] locator in
            store?.install(from: locator, content: content)
        }
        return view
    }

    func updateUIView(_ uiView: LocatorView, context: Context) {
        uiView.windowDidChange = { [weak store] locator in
            store?.install(from: locator, content: content)
        }
        store.install(from: uiView, content: content)
    }

    final class LocatorView: UIView {
        var windowDidChange: ((UIView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            windowDidChange?(self)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil else { return }
            windowDidChange?(self)
        }
    }
}

/// The real five-page pager. Every NavigationStack and every feature-owned
/// StateObject is constructed exactly once in this non-lazy HStack.
private struct RootResidentPages: View {
    @ObservedObject var state: RootResidentState
    @EnvironmentObject private var appearance: AppAppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var transition: RootResidentTransition?
    @State private var swipeRegistry = RootTabSwipeRegistry()
    @State private var gestureLifecycle = RootTabGestureLifecycle()

    var body: some View {
        GeometryReader { proxy in
            let pageWidth = max(1, proxy.size.width)
            let pageHeight = max(1, proxy.size.height)

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    explorePage
                        .frame(width: pageWidth, height: pageHeight)
                    searchPage
                        .frame(width: pageWidth, height: pageHeight)
                    favoritesPage
                        .frame(width: pageWidth, height: pageHeight)
                    downloadsPage
                        .frame(width: pageWidth, height: pageHeight)
                    accountPage
                        .frame(width: pageWidth, height: pageHeight)
                }
                .frame(
                    width: pageWidth * CGFloat(RootTab.allCases.count),
                    height: pageHeight,
                    alignment: .leading
                )
                .offset(x: deckOffset(pageWidth: pageWidth))
            }
            .frame(width: pageWidth, height: pageHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .clipped()
            .simultaneousGesture(rootDragGesture(pageWidth: pageWidth))
            .background {
                rootTrackpadBridge(pageWidth: pageWidth)
            }
        }
        .background(appearance.background(for: colorScheme).ignoresSafeArea())
        .environment(\.readerIsPresented, state.readerPresentationBinding)
        .environment(\.rootTabSelection, state.selectedTabBinding)
        .environment(\.rootTabSwipeRegistry, swipeRegistry)
        .onChange(of: state.selectedTab) { oldValue, newValue in
            guard oldValue != newValue,
                  let transition,
                  transition.source != newValue else { return }
            // A native tab/sidebar tap wins over an unfinished physical drag.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.transition = nil
            }
            gestureLifecycle.end()
        }
    }

    private var explorePage: some View {
        NavigationStack(path: $state.exploreNavigationPath) {
            ExploreView()
                .appNavigationDestinations()
                .rootTabSwipe(
                    selection: state.selectedTabBinding,
                    from: .explore,
                    isEnabled: RootNavigationPathPolicy.allowsRootTabSwipe(
                        path: state.exploreNavigationPath
                    )
                )
        }
    }

    private var searchPage: some View {
        NavigationStack(path: $state.searchNavigationPath) {
            SearchView()
                .appNavigationDestinations()
                .rootTabSwipe(
                    selection: state.selectedTabBinding,
                    from: .search,
                    isEnabled: RootNavigationPathPolicy.allowsRootTabSwipe(
                        path: state.searchNavigationPath
                    )
                )
        }
    }

    private var favoritesPage: some View {
        FavoritesView()
    }

    private var downloadsPage: some View {
        NavigationStack(path: $state.downloadsNavigationPath) {
            DownloadsView(navigationPath: $state.downloadsNavigationPath)
                .rootTabSwipe(
                    selection: state.selectedTabBinding,
                    from: .downloads,
                    isEnabled: DownloadsNavigationPolicy.allowsRootTabSwipe(
                        pathCount: state.downloadsNavigationPath.count
                    )
                )
        }
    }

    private var accountPage: some View {
        NavigationStack(path: $state.accountNavigationPath) {
            AccountView()
                .appNavigationDestinations()
                .rootTabSwipe(
                    selection: state.selectedTabBinding,
                    from: .account,
                    isEnabled: RootNavigationPathPolicy.allowsRootTabSwipe(
                        path: state.accountNavigationPath
                    )
                )
        }
    }

    private func deckOffset(pageWidth: CGFloat) -> CGFloat {
        -CGFloat(state.selectedTab.rawValue) * pageWidth
            + (transition?.offset ?? 0)
    }

    private func rootDragGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                if transition == nil {
                    beginTransition(
                        startLocation: value.startLocation,
                        translation: value.translation,
                        pageWidth: pageWidth
                    )
                } else {
                    updateTransition(translation: value.translation)
                }
            }
            .onEnded { value in
                finishTransition(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                )
            }
    }

    @ViewBuilder
    private func rootTrackpadBridge(pageWidth: CGFloat) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            RootTabTrackpadPanBridge(
                shouldBegin: { startLocation, velocity in
                    guard !state.readerIsPresented,
                          transition == nil,
                          !gestureLifecycle.isActive,
                          RootTabTrackpadPolicy.isHorizontal(velocity: velocity),
                          RootTabSwipePolicy.adjacentTab(
                            from: state.selectedTab,
                            horizontalTranslation: velocity.x
                          ) != nil,
                          activeSwipeSurface(at: startLocation) != nil else { return false }
                    return true
                },
                onChanged: { startLocation, translation in
                    if transition == nil {
                        beginTransition(
                            startLocation: startLocation,
                            translation: translation,
                            pageWidth: pageWidth
                        )
                    } else {
                        updateTransition(translation: translation)
                    }
                },
                onEnded: { _, translation, predictedEndTranslation in
                    finishTransition(
                        translation: translation,
                        predictedEndTranslation: predictedEndTranslation
                    )
                },
                onCancelled: {
                    finishTransition(
                        translation: .zero,
                        predictedEndTranslation: .zero
                    )
                }
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }

    private func activeSwipeSurface(at startLocation: CGPoint) -> RootTabSwipeSurface? {
        swipeRegistry.activeSurface(for: state.selectedTab, at: startLocation)
    }

    private func beginTransition(
        startLocation: CGPoint,
        translation: CGSize,
        pageWidth: CGFloat
    ) {
        guard !state.readerIsPresented,
              transition == nil,
              abs(translation.width) >= RootTabSwipePolicy.activationTranslation,
              abs(translation.width) > abs(translation.height)
                * RootTabSwipePolicy.horizontalDominance,
              activeSwipeSurface(at: startLocation) != nil,
              let destination = RootTabSwipePolicy.adjacentTab(
                from: state.selectedTab,
                horizontalTranslation: translation.width
              ),
              gestureLifecycle.begin() else { return }

        let source = state.selectedTab
        let proposed = RootTabSwipePolicy.interactiveOffset(
            from: source,
            translation: translation,
            viewportWidth: pageWidth
        )
        let directionalOffset = destination.rawValue > source.rawValue
            ? min(0, proposed) : max(0, proposed)
        transition = RootResidentTransition(
            token: UUID(),
            source: source,
            destination: destination,
            viewportWidth: pageWidth,
            offset: directionalOffset
        )
    }

    private func updateTransition(translation: CGSize) {
        guard var current = transition, !current.isSettling else { return }
        let proposed = RootTabSwipePolicy.interactiveOffset(
            from: current.source,
            translation: translation,
            viewportWidth: current.viewportWidth
        )
        current.offset = current.destination.rawValue > current.source.rawValue
            ? min(0, proposed) : max(0, proposed)
        transition = current
    }

    private func finishTransition(
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) {
        guard var current = transition, !current.isSettling else {
            if transition == nil { gestureLifecycle.end() }
            return
        }

        let destination = RootTabSwipePolicy.destination(
            from: current.source,
            translation: translation,
            predictedEndTranslation: predictedEndTranslation
        )
        let shouldCommit = destination == current.destination
        current.isSettling = true
        transition = current

        let token = current.token
        let finalOffset: CGFloat
        if shouldCommit {
            finalOffset = current.destination.rawValue > current.source.rawValue
                ? -current.viewportWidth : current.viewportWidth
        } else {
            finalOffset = 0
        }

        withAnimation(
            .spring(response: 0.30, dampingFraction: 0.90),
            completionCriteria: .removed
        ) {
            guard var settling = transition, settling.token == token else { return }
            settling.offset = finalOffset
            transition = settling
        } completion: {
            guard let settling = transition, settling.token == token else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if shouldCommit {
                    state.selectedTab = settling.destination
                }
                transition = nil
            }
            gestureLifecycle.end()
        }
    }
}

/// Public app root. Native adaptive tab chrome remains system-owned; feature
/// pages are rendered by RootResidentPages exactly once in the persistent host.
struct RootView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var readingProgress: ReadingProgressStore
    @EnvironmentObject private var readingHistory: ReadingHistoryStore
    @EnvironmentObject private var appearance: AppAppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var state = RootResidentState()
    @StateObject private var pageHost = RootResidentPageHostStore()

    var body: some View {
        TabView(selection: $state.selectedTab) {
            rootTab("发现", systemImage: "sparkles", value: .explore)
            rootTab("搜索", systemImage: "magnifyingglass", value: .search)
            rootTab("收藏", systemImage: "heart", value: .favorites)
            rootTab("下载", systemImage: "arrow.down.circle", value: .downloads)
            rootTab("我的", systemImage: "person.crop.circle", value: .account)
        }
        .tabViewStyle(.sidebarAdaptable)
        .toolbar(state.readerIsPresented ? .hidden : .visible, for: .tabBar)
        .tint(.accentColor)
        .background(appearance.background(for: colorScheme).ignoresSafeArea())
        .rootTabBarChromeFallback(appearance.background(for: colorScheme))
    }

    private var residentContent: AnyView {
        AnyView(
            RootResidentPages(state: state)
                .environmentObject(api)
                .environmentObject(downloads)
                .environmentObject(readingProgress)
                .environmentObject(readingHistory)
                .environmentObject(appearance)
        )
    }

    private func rootTab(
        _ title: String,
        systemImage: String,
        value: RootTab
    ) -> some TabContent<RootTab> {
        Tab(title, systemImage: systemImage, value: value) {
            RootResidentHostLocator(store: pageHost, content: residentContent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(appearance.background(for: colorScheme).ignoresSafeArea())
        }
    }
}

extension View {
    @ViewBuilder
    func glassCard() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }
}
