//
//  ShellView.swift
//  ClaudeIsland
//
//  Global Shell panel — every shell command the monitored agents have run,
//  newest first. Read-only: this surfaces activity, it never executes anything.
//

import SwiftUI

// MARK: - Shared relative-time helpers

enum RelativeTimeFormatter {
    static func since(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    static func duration(from start: Date, to end: Date?) -> String {
        let s = max(0, Int((end ?? Date()).timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

// MARK: - ShellView

struct ShellView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    @State private var expandedId: String?

    /// Sessions in scope: a single session when opened from a row, else all.
    private var scopedInstances: [SessionState] {
        if let sid = viewModel.shellSessionFilter {
            return sessionMonitor.instances.filter { $0.sessionId == sid }
        }
        return sessionMonitor.instances
    }

    /// Title of the scoped session (nil = all sessions).
    private var filterTitle: String? {
        guard let sid = viewModel.shellSessionFilter else { return nil }
        return sessionMonitor.instances.first { $0.sessionId == sid }?.displayTitle ?? "Session"
    }

    private var allCommands: [ShellCommandRecord] {
        scopedInstances
            .flatMap { $0.shellCommands }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var runningCount: Int {
        allCommands.filter { $0.isActive }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            if allCommands.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(allCommands) { record in
                            ShellCommandRow(
                                record: record,
                                sessionTitle: title(for: record.sessionId),
                                isExpanded: expandedId == record.id,
                                onTap: {
                                    expandedId = (expandedId == record.id) ? nil : record.id
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func title(for sessionId: String) -> String {
        sessionMonitor.instances.first { $0.sessionId == sessionId }?.displayTitle ?? ""
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            Text("Shell")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

            if let filterTitle {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                Text(filterTitle)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
            }

            if runningCount > 0 {
                Text("\(runningCount) running")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
            }

            Spacer()

            if filterTitle != nil {
                Button {
                    viewModel.showShell(sessionId: nil)
                } label: {
                    Text("All")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Text("\(allCommands.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No shell commands yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
            Text("Commands agents run will appear here")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shell Command Row

struct ShellCommandRow: View {
    let record: ShellCommandRecord
    let sessionTitle: String
    let isExpanded: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    private var statusColor: Color {
        switch record.status {
        case .running: return TerminalColors.amber
        case .success: return TerminalColors.green
        case .error: return TerminalColors.red
        case .interrupted: return .white.opacity(0.4)
        }
    }

    private var statusSymbol: String {
        switch record.status {
        case .running: return "circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .interrupted: return "minus.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                AgentIcon(kind: record.agentKind, size: 14)

                Image(systemName: statusSymbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(statusColor)
                    .frame(width: 12)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.commandPreview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(isExpanded ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        if !sessionTitle.isEmpty {
                            Text(sessionTitle)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.35))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        Text(RelativeTimeFormatter.since(record.finishedAt ?? record.startedAt))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }

            if isExpanded, let output = record.output, !output.isEmpty {
                Text(output)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.top, 2)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onTap)
    }
}
