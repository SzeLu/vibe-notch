//
//  TerminalAppRegistry.swift
//  VibeNotch
//
//  Centralized registry of known terminal applications
//

import Foundation

/// Registry of known terminal application names and bundle identifiers
struct TerminalAppRegistry: Sendable {
    /// Terminal app names for process matching
    nonisolated static let appNames: Set<String> = [
        "Terminal",
        "iTerm2",
        "iTerm",
        "Ghostty",
        "Alacritty",
        "kitty",
        "Hyper",
        "Warp",
        "WezTerm",
        "wezterm-gui",
        "Paseo",
        "Tabby",
        "Rio",
        "Contour",
        "foot",
        "st",
        "urxvt",
        "xterm",
        "Code",           // VS Code
        "Code - Insiders",
        "Cursor",
        "Windsurf",
        "zed"
    ]

    /// Bundle identifiers for terminal apps (for window enumeration)
    static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "sh.paseo.desktop",       // Paseo (Electron-based terminal)
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed"
    ]

    /// Names that are also ordinary English words / substrings. `ps comm`
    /// returns full executable paths, so a plain `contains("code")` would
    /// classify `.../@opencode/cli/bin/opencode.exe` as a terminal. These are
    /// matched exactly (against the whole string or the basename) instead.
    nonisolated private static let exactMatchNames: Set<String> = [
        "Hyper", "Warp", "Tabby", "Rio", "Contour", "foot", "st",
        "Code", "Code - Insiders", "zed"
    ]

    /// Check if an app name or command path is a known terminal.
    /// Pure string matching — safe to call from any actor.
    nonisolated static func isTerminal(_ appNameOrCommand: String) -> Bool {
        let lower = appNameOrCommand.lowercased()
        let basename = (appNameOrCommand as NSString).lastPathComponent.lowercased()

        for name in appNames {
            let candidate = name.lowercased()
            if exactMatchNames.contains(name) {
                if lower == candidate || basename == candidate { return true }
            } else if lower.contains(candidate) {
                return true
            }
        }

        // Additional checks for common patterns
        return lower.contains("terminal") || lower.contains("iterm")
    }

    /// Check if a bundle identifier is a known terminal
    static func isTerminalBundle(_ bundleId: String) -> Bool {
        bundleIdentifiers.contains(bundleId)
    }
}
