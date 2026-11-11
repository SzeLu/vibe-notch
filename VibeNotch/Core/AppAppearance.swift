//
//  AppAppearance.swift
//  VibeNotch
//
//  User-selectable appearance: follow the system, or force light / dark.
//

import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// UserDefaults key shared with `@AppStorage`.
    static let storageKey = "appAppearance"

    var id: String { rawValue }

    /// `nil` means "follow the system appearance".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// English source label (localized via the string catalog at call sites).
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
