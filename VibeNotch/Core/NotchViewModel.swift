//
//  NotchViewModel.swift
//  VibeNotch
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(SessionState)
    case shell
    case monitor

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .chat(let session): return "chat-\(session.sessionId)"
        case .shell: return "shell"
        case .monitor: return "monitor"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances

    /// Optional session scope for the Shell / Monitor panels.
    /// `nil` means "all sessions" (opened from the header); a session id means
    /// the panel was opened from that session's row.
    @Published var shellSessionFilter: String?
    @Published var monitorSessionFilter: String?

    /// Width of the collapsed notch content (device notch + any activity
    /// expansion such as the processing spinner, pending-permission indicator or
    /// waiting-for-input checkmark), as reported by `NotchView`. The click
    /// catcher window sizes itself to this so clicks on the expanded sides are
    /// still captured instead of falling through to the system status bar.
    @Published var collapsedContentWidth: CGFloat = 0

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared
    private let claudeDirSelector = ClaudeDirSelector.shared

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }

    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        switch contentType {
        case .chat:
            // Large size for chat view
            return CGSize(
                width: min(screenRect.width * 0.5, 600),
                height: 580
            )
        case .menu:
            // Base height hugs the collapsed content (Back, Appearance, 3 picker
            // rows, 2 toggles, Accessibility, Update, GitHub, Quit + dividers +
            // padding) within the panel's header + bottom padding. Picker
            // expansion deltas are added on top when a picker is expanded.
            // Tuned so there's only a small gap below "Quit" and no scroll in
            // the collapsed state.
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 560
                    + screenSelector.expandedPickerHeight
                    + soundSelector.expandedPickerHeight
                    + claudeDirSelector.expandedPickerHeight
            )
        case .instances:
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 320
            )
        case .shell, .monitor:
            return CGSize(
                width: min(screenRect.width * 0.45, 520),
                height: 460
            )
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared

    /// Timestamp of the most recent click-driven open. Used to ignore the same
    /// physical click's close handler (see `handleMouseDown`), so a single click
    /// on the collapsed notch opens the panel instead of opening then closing.
    private var lastClickOpenTime: Date = .distantPast

    /// Timestamp of the most recent close. Used to ignore the same physical
    /// click's open handler, so clicking the notch to close the panel doesn't
    /// get immediately reopened by the duplicate monitor callback.
    private var lastCloseTime: Date = .distantPast

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        setupEventHandlers()
        observeSelectors()
    }

    private func observeSelectors() {
        screenSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        soundSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        claudeDirSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMouseDown()
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        return false
    }

    /// The chat session we're viewing (persists across close/open)
    private var currentChatSession: SessionState?

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        switch status {
        case .opened:
            if geometry.isPointOutsidePanel(location, size: openedSize) {
                notchClose()
                // Re-post the click so it reaches the window/app behind us
                repostClickAt(location)
            } else if geometry.notchScreenRect.contains(location) {
                // Clicking the notch while opened closes it — but NOT on the same
                // click that just opened it. Opening and closing are driven by
                // separate event paths (the catcher window's mouseDown and the
                // global/local mouse monitor) that both fire for one physical
                // click, so guard with a short grace period; otherwise the panel
                // would open and be closed again within the same event.
                if !isInChatMode && Date().timeIntervalSince(lastClickOpenTime) > 0.4 {
                    notchClose()
                }
            }
        case .closed, .popping:
            // Guard against the same click that just closed the panel reopening
            // it: the local and global mouse monitors each fire once per click,
            // so without this a click-to-close would close then immediately
            // reopen via the duplicate callback.
            if geometry.isPointInNotch(location),
               Date().timeIntervalSince(lastCloseTime) > 0.4 {
                notchOpen(reason: .click)
            }
        }
    }

    /// Re-posts a mouse click at the given screen location so it reaches windows behind us
    private func repostClickAt(_ location: CGPoint) {
        // Small delay to let the window's ignoresMouseEvents update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Convert to CGEvent coordinate system (screen coordinates with Y from top-left).
            // Flip against the PRIMARY display's height (screens[0]), NOT NSScreen.main:
            // NSScreen.main is the display holding the key window and may be a secondary
            // display of a different height, which would offset the re-posted click's Y
            // and cause it to land on the wrong window (see issue #116).
            guard let primaryScreen = NSScreen.screens.first else { return }
            let primaryHeight = primaryScreen.frame.height
            let cgPoint = CGPoint(x: location.x, y: primaryHeight - location.y)

            // Create and post mouse down event
            if let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseDown.post(tap: .cghidEventTap)
            }

            // Create and post mouse up event
            if let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        status = .opened

        if reason == .click {
            lastClickOpenTime = Date()
        }

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case .chat(let current) = contentType, current.sessionId == chatSession.sessionId {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func notchClose() {
        lastCloseTime = Date()
        // Save chat session before closing if in chat mode
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
        status = .closed
        contentType = .instances
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func toggleMenu() {
        contentType = contentType == .menu ? .instances : .menu
    }

    func showChat(for session: SessionState) {
        // Avoid unnecessary updates if already showing this chat
        if case .chat(let current) = contentType, current.sessionId == session.sessionId {
            return
        }
        contentType = .chat(session)
    }

    /// Toggle the global Shell panel (header button — all sessions).
    func toggleShell() {
        if contentType == .shell {
            contentType = .instances
        } else {
            shellSessionFilter = nil
            contentType = .shell
        }
    }

    /// Open the Shell panel, optionally scoped to one session (row button).
    func showShell(sessionId: String?) {
        shellSessionFilter = sessionId
        contentType = .shell
    }

    /// Toggle the global Monitor panel (header button — all sessions).
    func toggleMonitor() {
        if contentType == .monitor {
            contentType = .instances
        } else {
            monitorSessionFilter = nil
            contentType = .monitor
        }
    }

    /// Open the Monitor panel, optionally scoped to one session (row button).
    func showMonitor(sessionId: String?) {
        monitorSessionFilter = sessionId
        contentType = .monitor
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSession = nil
        contentType = .instances
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }
}
