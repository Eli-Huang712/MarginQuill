import AppKit
import SwiftUI

enum PreferenceKey {
    static let language = "paperNotes.language"
    static let appearance = "paperNotes.appearance"
    static let accent = "paperNotes.accent"
    static let model = "paperNotes.defaultModel"
}

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, chinese, english

    var id: Self { self }
    var label: String {
        switch self {
        case .system: L("跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }

    static let active: InterfaceLanguage = {
        let saved = UserDefaults.standard.string(forKey: PreferenceKey.language).flatMap(Self.init(rawValue:))
        if let saved, saved != .system { return saved }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .chinese : .english
    }()

    static let locale = Locale(identifier: active == .english ? "en" : "zh-Hans")
    fileprivate static let englishBundle = Bundle.main.path(forResource: "en", ofType: "lproj")
        .flatMap(Bundle.init(path:))
}

func L(_ key: String, _ values: any CustomStringConvertible...) -> String {
    let format = InterfaceLanguage.active == .english ?
        InterfaceLanguage.englishBundle?.localizedString(forKey: key, value: key, table: nil) ?? key : key
    guard !values.isEmpty else { return format }
    return String(format: format, locale: InterfaceLanguage.locale, arguments: values.map { $0.description })
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }
    static var saved: Self {
        UserDefaults.standard.string(forKey: PreferenceKey.appearance).flatMap(Self.init(rawValue:)) ?? .system
    }
    var label: String {
        switch self {
        case .system: L("跟随系统")
        case .light: L("浅色")
        case .dark: L("深色")
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum AppAccent: String, CaseIterable, Identifiable {
    case purple, blue, teal, rose

    var id: Self { self }
    var label: String {
        switch self {
        case .purple: L("紫色")
        case .blue: L("蓝色")
        case .teal: L("青绿色")
        case .rose: L("玫红色")
        }
    }

    func hex(dark: Bool) -> String {
        switch self {
        case .purple: dark ? "#B09EFF" : "#633FCA"
        case .blue: dark ? "#87B9FF" : "#245FB7"
        case .teal: dark ? "#64D8C3" : "#087767"
        case .rose: dark ? "#F3A0BB" : "#AD3561"
        }
    }

    var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let raw = UInt32(hex(dark: dark).dropFirst(), radix: 16) ?? 0x633FCA
            return NSColor(srgbRed: CGFloat((raw >> 16) & 255) / 255, green: CGFloat((raw >> 8) & 255) / 255,
                           blue: CGFloat(raw & 255) / 255, alpha: 1)
        })
    }
}

private struct AccentPreference: EnvironmentKey {
    static let defaultValue = AppAccent.purple
}

extension EnvironmentValues {
    var paperAccent: AppAccent {
        get { self[AccentPreference.self] }
        set { self[AccentPreference.self] = newValue }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, recognition, integrations

    var id: Self { self }

    var title: String {
        switch self {
        case .general: L("通用")
        case .appearance: L("外观")
        case .recognition: L("AI 与识别")
        case .integrations: L("集成")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .recognition: "sparkles"
        case .integrations: "arrow.triangle.branch"
        }
    }
}
