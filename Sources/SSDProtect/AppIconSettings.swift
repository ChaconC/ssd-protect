import AppKit
import Combine

enum AppIconChoice: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light Cradle"
        case .dark: "Dark Cradle"
        }
    }
}

final class AppIconSettings: ObservableObject {
    private static let key = "appIconAppearance"
    private let defaults: UserDefaults
    private let load: (AppIconChoice) -> NSImage?
    private let apply: (NSImage?) -> Void
    @Published private(set) var choice: AppIconChoice
    @Published private(set) var errorMessage: String?

    init(defaults: UserDefaults = .standard,
         load: @escaping (AppIconChoice) -> NSImage? = AppIconSettings.bundledImage,
         apply: @escaping (NSImage?) -> Void = { NSApp.applicationIconImage = $0 }) {
        self.defaults = defaults
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
