//
//  Localization.swift
//  ClaudeIsland
//
//  Runtime string lookup backed by the Localizable string catalog.
//  Matches the system language automatically and falls back to English
//  (the source language) when a translation is missing.
//

import Foundation

/// Looks up `key` in the main bundle's localized resources.
/// Returns the English key unchanged when no translation exists.
func L(_ key: String, comment: String = "") -> String {
    NSLocalizedString(key, comment: comment)
}
