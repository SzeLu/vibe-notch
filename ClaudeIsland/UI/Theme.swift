//
//  Theme.swift
//  ClaudeIsland
//
//  Adaptive surface colors so the notch UI follows the system appearance.
//  Text/surfaces elsewhere use `Color.primary` (auto-adapts: white in dark,
//  black in light); these are the larger structural surfaces.
//

import AppKit
import SwiftUI

enum Theme {
    /// The notch panel surface: pure black in dark mode, a soft light gray in light mode.
    static let panel: Color = adaptive(
        dark: NSColor(calibratedWhite: 0.0, alpha: 1.0),
        light: NSColor(calibratedRed: 0.957, green: 0.957, blue: 0.969, alpha: 1.0) // #F4F4F7
    )

    /// A raised surface for cards, code blocks and inputs.
    static let surface: Color = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.06),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.05)
    )

    /// A slightly stronger surface (hover, headers).
    static let surfaceStrong: Color = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.08)
    )

    /// Hairline border / divider.
    static let border: Color = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.10)
    )

    /// Drop shadow for the floating panel.
    static let shadow: Color = adaptive(
        dark: NSColor(calibratedWhite: 0.0, alpha: 0.70),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.16)
    )

    /// Builds a Color that resolves differently for dark and light appearances.
    static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        })
    }
}
