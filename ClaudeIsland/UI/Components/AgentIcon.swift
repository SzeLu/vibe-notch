//
//  AgentIcon.swift
//  ClaudeIsland
//
//  Per-provider marks shown next to every session, so the conversation list
//  tells you at a glance which agent a session belongs to.
//
//  WorkBuddy and OpenCode use their official favicons (from workbuddy.ai and
//  opencode.ai) bundled as asset-catalog imagesets. Claude Code keeps the pixel
//  crab mascot, drawn as a vector so it stays crisp and tintable.
//

import SwiftUI

extension AgentKind {
    /// Provider accent, used by the Claude Code crab chip.
    var accent: Color {
        switch self {
        case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.34)  // #D97757 copper
        case .workBuddy:  return Color(red: 0.49, green: 0.55, blue: 0.97)  // #7C8CF8 violet
        case .openCode:   return Color(red: 0.31, green: 0.82, blue: 0.65)  // #4FD1A5 mint
        }
    }

    /// Asset-catalog name for providers that ship a real favicon.
    var faviconAsset: String? {
        switch self {
        case .claudeCode: return nil
        case .workBuddy:  return "AgentWorkBuddy"
        case .openCode:   return "AgentOpenCode"
        }
    }
}

/// Compact provider badge shown in session, shell, and monitor rows.
struct AgentIcon: View {
    let kind: AgentKind
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let asset = kind.faviconAsset {
                favicon(asset)
            } else {
                crabChip
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(kind.displayName)
        .help(kind.displayName)
    }

    // MARK: - Favicon (WorkBuddy / OpenCode)

    private func favicon(_ asset: String) -> some View {
        Image(asset)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }

    // MARK: - Claude Code crab chip

    private var crabChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(kind.accent.opacity(0.16))
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .strokeBorder(kind.accent.opacity(0.40), lineWidth: max(0.6, size * 0.05))

            Canvas { context, canvasSize in
                drawCrab(in: context, size: canvasSize.width, color: kind.accent)
            }
            .frame(width: size, height: size)
        }
    }

    /// Pixel crab mascot on a 24x24 design grid.
    private func drawCrab(in ctx: GraphicsContext, size: CGFloat, color: Color) {
        let u = size / 24
        var p = Path()
        p.addRect(CGRect(x: 1.4 * u, y: 9.0 * u, width: 2.6 * u, height: 4.0 * u))
        p.addRect(CGRect(x: 20.0 * u, y: 9.0 * u, width: 2.6 * u, height: 4.0 * u))
        for lx in [CGFloat(4.6), 7.6, 13.8, 16.8] {
            p.addRect(CGRect(x: lx * u, y: 15.8 * u, width: 2.2 * u, height: 5.0 * u))
        }
        p.addRect(CGRect(x: 4.0 * u, y: 5.6 * u, width: 16.0 * u, height: 10.2 * u))
        p.addRect(CGRect(x: 6.9 * u, y: 9.0 * u, width: 2.4 * u, height: 2.6 * u))
        p.addRect(CGRect(x: 14.7 * u, y: 9.0 * u, width: 2.4 * u, height: 2.6 * u))
        ctx.fill(p, with: .color(color), style: FillStyle(eoFill: true))
    }
}
