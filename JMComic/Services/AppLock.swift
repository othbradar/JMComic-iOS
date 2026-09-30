import SwiftUI
import LocalAuthentication

@MainActor
protocol OwnerAuthenticating: AnyObject {
    func authenticate(reason: String) async throws
    func invalidate()
}

@MainActor
final class SystemOwnerAuthentication: OwnerAuthenticating {
    private var context: LAContext?
    func authenticate(reason: String) async throws {
        let context = LAContext()
        self.context = context
        context.localizedCancelTitle = "取消"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? NSError(domain: "AppLock", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先在系统设置中启用设备密码或生物识别，然后重试"])
        }
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
            throw LAError(.authenticationFailed)
        }
    }
    func invalidate() { context?.invalidate(); context = nil }
}

/// Inactive shields the snapshot; only background retires authentication and
/// locks. The system's own authentication prompt therefore cannot loop.
struct AppLockState {
    var enabled: Bool
    var locked: Bool
    var inactive = true
    var generation = UUID()
    var attemptedActivation = false
    init(enabled: Bool) { self.enabled = enabled; locked = enabled }
    mutating func background() {
        generation = UUID(); inactive = true; locked = enabled; attemptedActivation = false
    }
    mutating func active() { inactive = false }
    mutating func accept(_ token: UUID) -> Bool {
        guard token == generation else { return false }
        locked = false
        return true
    }
}

@MainActor
final class AppLockSession: ObservableObject {
    static let key = "jm.app-lock.enabled"
    private static let changed = Notification.Name("JMComic.AppLockSettingsChanged")
    @Published private(set) var state: AppLockState
    @Published private(set) var authenticating = false
    @Published var error: String?
    private let defaults: UserDefaults
    private let auth: OwnerAuthenticating
    private var settingsObserver: NSObjectProtocol?
    init(defaults: UserDefaults = .standard, auth: OwnerAuthenticating? = nil) {
        self.defaults = defaults; self.auth = auth ?? SystemOwnerAuthentication()
        state = AppLockState(enabled: defaults.bool(forKey: Self.key))
        settingsObserver = NotificationCenter.default.addObserver(forName: Self.changed, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, (notification.object as? AppLockSession) !== self else { return }
                self.auth.invalidate(); self.authenticating = false
                let wasInactive = self.state.inactive
                self.state = AppLockState(enabled: self.defaults.bool(forKey: Self.key))
                if !wasInactive { self.active() }
            }
        }
    }
    deinit { if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) } }
    func inactive() { state.inactive = true }
    func background() { state.background(); auth.invalidate(); authenticating = false }
    func active() {
        state.active()
        if state.enabled && state.locked && !state.attemptedActivation {
            state.attemptedActivation = true
            Task { await unlock() }
        }
    }
    func unlock() async {
        guard state.enabled, state.locked, !authenticating, !state.inactive else { return }
        authenticating = true; error = nil
        let token = state.generation
        do {
            try await auth.authenticate(reason: "验证身份以打开 JMComic")
            _ = state.accept(token)
        } catch {
            if state.generation == token { self.error = "未解锁。可重试或在系统设置中检查设备密码/生物识别。" }
        }
        if state.generation == token { authenticating = false }
    }
    func setEnabled(_ enabled: Bool) async {
        guard enabled != state.enabled, !authenticating else { return }
        authenticating = true; error = nil
        let token = state.generation
        do {
            try await auth.authenticate(reason: enabled ? "验证设备身份并启用应用锁" : "验证身份以关闭应用锁")
            guard token == state.generation else { return }
            defaults.set(enabled, forKey: Self.key)
            state.enabled = enabled; state.locked = false
            state.attemptedActivation = true
            NotificationCenter.default.post(name: Self.changed, object: self)
        } catch {
            if state.generation == token { self.error = error.localizedDescription }
        }
        if state.generation == token { authenticating = false }
    }
}

struct AppLockCover: View {
    @ObservedObject var session: AppLockSession
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield").font(.largeTitle)
                Text("JMComic").font(.title2.bold())
                if !session.state.inactive && session.state.locked {
                    if session.authenticating { ProgressView("正在验证") }
                    else { Button("解锁") { Task { await session.unlock() } }.buttonStyle(.borderedProminent) }
                    if let error = session.error {
                        Text(error).font(.footnote).multilineTextAlignment(.center)
                        Button("打开系统设置") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    }
                }
            }.padding(30)
        }.accessibilityIdentifier("app.privacyShield")
    }
}

/// A scene-owned window also covers sheets, fullScreenCover readers and deep
/// links. It is never shared across windows and never replaces RootView.
struct AppPrivacyBridge: UIViewRepresentable {
    @ObservedObject var session: AppLockSession
    func makeUIView(context: Context) -> Marker { let view = Marker(); view.session = session; return view }
    func updateUIView(_ view: Marker, context: Context) { view.updateCover() }
    static func dismantleUIView(_ view: Marker, coordinator: ()) { view.tearDown() }
    final class Marker: UIView {
        weak var session: AppLockSession?
        private var cover: UIWindow?
        private var observers: [NSObjectProtocol] = []
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene, cover?.windowScene !== scene, let session else { return }
            removeObservers()
            let privacy = UIWindow(windowScene: scene)
            privacy.windowLevel = .alert + 1
            privacy.rootViewController = UIHostingController(rootView: AppLockCover(session: session))
            privacy.backgroundColor = .systemBackground
            cover = privacy
            observe(UIScene.willDeactivateNotification, scene: scene) { $0.inactive() }
            observe(UIScene.didEnterBackgroundNotification, scene: scene) { $0.background() }
            observe(UIScene.didActivateNotification, scene: scene) { $0.active() }
            if scene.activationState == .foregroundActive { session.active() }
            else if scene.activationState == .background { session.background() }
            updateCover()
        }
        private func observe(_ name: Notification.Name, scene: UIWindowScene, action: @escaping @MainActor (AppLockSession) -> Void) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let session = self.session else { return }
                    action(session)
                    self.updateCover() // synchronous, before snapshot capture
                }
            })
        }
        func updateCover() {
            guard let session else { return }
            cover?.isHidden = !session.state.inactive && !session.state.locked
        }
        func tearDown() { removeObservers() }
        private func removeObservers() { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll(); cover?.isHidden = true; cover = nil }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

struct ProtectedAppRoot: View {
    @StateObject private var lock = AppLockSession()
    var body: some View {
        RootView()
            .environmentObject(lock)
            .allowsHitTesting(!lock.state.locked)
            .accessibilityHidden(lock.state.locked)
            .background(AppPrivacyBridge(session: lock).frame(width: 0, height: 0))
    }
}
