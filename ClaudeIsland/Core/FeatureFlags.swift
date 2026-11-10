//
//  FeatureFlags.swift
//  ClaudeIsland
//
//  Central place for build/runtime feature toggles.
//

import Foundation

enum FeatureFlags {
    /// Sparkle auto-update is currently disabled. When false, the updater is
    /// never started, never auto-checks, and the "Check for Updates" row is
    /// hidden from the menu.
    static let updatesEnabled = false
}
