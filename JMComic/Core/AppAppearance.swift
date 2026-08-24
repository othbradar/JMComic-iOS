import SwiftUI

enum InterfacePreferences {
    /// Controls optional implementation/synchronization explanations. Error
    /// messages, destructive-action warnings and live progress stay visible.
    static let showExplanatoryTextKey = "jm.interface.show-explanatory-text"
}

enum AppPalette: String, CaseIterable, Identifiable {
    case ivory
    case lightGray
    case lightGreen
    case lightPink
    case paleYellow
    case deepGray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ivory: "米白色"
        case .lightGray: "浅灰"
        case .lightGreen: "浅绿"
        case .lightPink: "浅粉"
        case .paleYellow: "淡黄"
        case .deepGray: "深灰"
        }
    }

    func background(for scheme: ColorScheme) -> Color {
        switch (self, scheme) {
        case (.ivory, .light): Color(red: 0.973, green: 0.957, blue: 0.914)
        case (.lightGray, .light): Color(red: 0.925, green: 0.933, blue: 0.945)
        case (.lightGreen, .light): Color(red: 0.914, green: 0.957, blue: 0.918)
        case (.lightPink, .light): Color(red: 0.976, green: 0.925, blue: 0.937)
        case (.paleYellow, .light): Color(red: 0.984, green: 0.961, blue: 0.855)
        case (.deepGray, .light): Color(red: 0.820, green: 0.831, blue: 0.851)
        case (.ivory, .dark): Color(red: 0.137, green: 0.129, blue: 0.106)
        case (.lightGray, .dark): Color(red: 0.118, green: 0.129, blue: 0.145)
        case (.lightGreen, .dark): Color(red: 0.098, green: 0.145, blue: 0.110)
        case (.lightPink, .dark): Color(red: 0.153, green: 0.106, blue: 0.122)
        case (.paleYellow, .dark): Color(red: 0.157, green: 0.137, blue: 0.082)
        case (.deepGray, .dark): Color(red: 0.075, green: 0.078, blue: 0.086)
        @unknown default: Color(.systemBackground)
        }
    }

    func swatch(for scheme: ColorScheme) -> Color {
        background(for: scheme)
    }
}

enum AppColorMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppAppearanceStore: ObservableObject {
    private enum Key {
        static let palette = "jm.appearance.palette"
        static let colorMode = "jm.appearance.color-mode"
    }

    @Published var palette: AppPalette {
        didSet { defaults.set(palette.rawValue, forKey: Key.palette) }
    }

    @Published var colorMode: AppColorMode {
        didSet { defaults.set(colorMode.rawValue, forKey: Key.colorMode) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        palette = AppPalette(rawValue: defaults.string(forKey: Key.palette) ?? "") ?? .ivory
        colorMode = AppColorMode(rawValue: defaults.string(forKey: Key.colorMode) ?? "") ?? .system
    }

    var preferredColorScheme: ColorScheme? { colorMode.preferredColorScheme }

    func background(for scheme: ColorScheme) -> Color {
        palette.background(for: scheme)
    }
}

/// Shared full-page loading state. Keeping this as one component prevents
/// feature screens from reintroducing text, cards, mismatched spinner sizes,
/// or an intrinsic-size background that exposes the system's white host view.
struct AppLoadingView: View {
    let accessibilityText: String

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(accessibilityText)
    }
}

private struct AppPageBackgroundModifier: ViewModifier {
    @EnvironmentObject private var appearance: AppAppearanceStore
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(appearance.background(for: colorScheme).ignoresSafeArea())
            .toolbarBackground(appearance.background(for: colorScheme), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

extension View {
    func appPageBackground() -> some View {
        modifier(AppPageBackgroundModifier())
    }
}
