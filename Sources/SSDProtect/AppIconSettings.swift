import AppKit
import Combine

enum AppIconChoice: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

final class AppIconSettings: ObservableObject {
    // Existing icon choices use the same raw values as the app appearance.
    private static let key = "appIconAppearance"
    private let defaults: UserDefaults
    private let load: (AppIconChoice) -> NSImage?
    private let apply: (NSImage?) -> Void
    private let applyAppearance: (NSAppearance?) -> Void
    @Published private(set) var choice: AppIconChoice
    @Published private(set) var errorMessage: String?

    init(defaults: UserDefaults = .standard,
         load: @escaping (AppIconChoice) -> NSImage? = AppIconSettings.bundledImage,
         apply: @escaping (NSImage?) -> Void = { NSApp.applicationIconImage = $0 },
         applyAppearance: @escaping (NSAppearance?) -> Void = { NSApp.appearance = $0 }) {
        self.defaults = defaults
        self.applyAppearance = applyAppearance
        self.load = load
        self.apply = apply
        choice = defaults.string(forKey: Self.key).flatMap(AppIconChoice.init(rawValue:)) ?? .system
    }

    func applySavedAppearance() { select(choice) }

    func select(_ newChoice: AppIconChoice) {
        let icon = newChoice == .system ? nil : load(newChoice)
        guard newChoice == .system || icon != nil else {
            errorMessage = "This app copy is missing the selected icon."
            return
        }
        switch newChoice {
        case .system: applyAppearance(nil)
        case .light: applyAppearance(NSAppearance(named: .aqua))
        case .dark: applyAppearance(NSAppearance(named: .darkAqua))
        }
        apply(icon)
        errorMessage = nil
        choice = newChoice
        if newChoice == .system { defaults.removeObject(forKey: Self.key) }
        else { defaults.set(newChoice.rawValue, forKey: Self.key) }
    }

    func preview(_ choice: AppIconChoice) -> NSImage {
        if choice != .system, let image = load(choice) { return image }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    static func bundledImage(_ choice: AppIconChoice) -> NSImage? {
        let name: String
        switch choice {
        case .system: return nil
        case .light: name = "LightCradle"
        case .dark: name = "DarkCradle"
        }
        return Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
}
