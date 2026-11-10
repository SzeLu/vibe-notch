//
//  MonitorView.swift
//  ClaudeIsland
//
//  Global Monitor panel — background / detached tasks the monitored agents
//  have spawned, newest first. Completion is surfaced with a notch bounce and
//  sound (see NotchView.handleBackgroundTaskCompleted).
//

import SwiftUI

struct MonitorView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    @State private var expandedId: String?

    /// Sessions in scope: a single session when opened from a row, else all.
    private var scopedInstances: [SessionState] {
        if let sid = viewModel.monitorSessionFilter {
            return sessionMonitor.instances.filter { $0.sessionId == sid }
        }
        return sessionMonitor.instances
    }

    /// Title of the scoped session (nil = all sessions).
    private var filterTitle: String? {
        guard let sid = viewModel.monitorSessionFilter else { return nil }
        return sessionMonitor.instances.first { $0.sessionId == sid }?.displayTitle ?? "Session"
    }

    private var allTasks: [BackgroundTaskRecord] {
        scopedInstances
            .flatMap { $0.backgroundTasks }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var runningCount: Int {
        allTasks.filter { $0.isActive }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            if allTasks.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(allTasks) { record in
                            BackgroundTaskRow(
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
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary.opacity(0.5))

            Text("Monitor")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary.opacity(0.85))

            if let filterTitle {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.3))
                Text(filterTitle)
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.45))
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
                    viewModel.showMonitor(sessionId: nil)
                } label: {
                    Text("All")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Text("\(allTasks.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.primary.opacity(0.35))
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No background tasks")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.4))
            Text("Detached tasks agents spawn will appear here")
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Background Task Row

struct BackgroundTaskRow: View {
    let record: BackgroundTaskRecord
    let sessionTitle: String
    let isExpanded: Bool
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var pulse = false

    private var statusColor: Color {
        switch record.status {
        case .running: return TerminalColors.amber
        case .success: return TerminalColors.green
        case .error: return TerminalColors.red
        }
    }

    private var statusSymbol: String {
        switch record.status {
        case .running: return "circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var statusText: String {
        switch record.status {
        case .running: return "Running"
        case .success: return "Done"
        case .error: return "Failed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                AgentIcon(kind: record.agentKind, size: 14)

                Image(systemName: statusSymbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(statusColor)
                    .opacity(record.status == .running && !pulse ? 0.45 : 1)
                    .frame(width: 12)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.label.isEmpty ? "Background task" : record.label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.85))
                        .lineLimit(isExpanded ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Text(L(statusText))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(statusColor)

                        if !sessionTitle.isEmpty {
                            Text(sessionTitle)
                                .font(.system(size: 10))
                                .foregroundColor(.primary.opacity(0.35))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        Text(RelativeTimeFormatter.duration(from: record.startedAt, to: record.finishedAt))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.3))
                    }
                }
            }

            if isExpanded, let output = record.output, !output.isEmpty {
                Text(output)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.5))
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
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onTap)
        .onAppear {
            guard record.status == .running else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
