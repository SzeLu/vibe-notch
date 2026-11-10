//
//  NotchWindow.swift
//  VibeNotch
//
//  Transparent window that overlays the notch area
//  Following NotchDrop's approach: window ignores mouse events,
//  we use global event monitors to detect clicks/hovers
//

import AppKit

// Use NSPanel subclass for non-activating behavior
class NotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Floating panel behavior
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        // Transparent configuration
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false

        // CRITICAL: Prevent window from moving during space switches
        isMovable = false

        // Window behavior - stays on all spaces, above menu bar
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        // Above the menu bar
        level = .mainMenu + 3

        // Enable tooltips even when app is inactive (needed for panel windows)
        allowsToolTipsWhenApplicationIsInactive = true

        // CRITICAL: Window ignores ALL mouse events
        // This allows clicks to pass through to the menu bar
        // We use global event monitors to detect hover/clicks on the notch area
        ignoresMouseEvents = true

        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Click-through for areas outside the panel content

    override func sendEvent(_ event: NSEvent) {
        // For mouse events, check if we should pass through
        if event.type == .leftMouseDown || event.type == .leftMouseUp ||
           event.type == .rightMouseDown || event.type == .rightMouseUp ||
           event.type == .leftMouseDragged || event.type == .rightMouseDragged {
            // Get the location in window coordinates
            let locationInWindow = event.locationInWindow

            // Check if any view wants to handle this event
            if let contentView = self.contentView,
               contentView.hitTest(locationInWindow) == nil {
                // No view wants this event - pass it through to windows behind
                // by momentarily ignoring mouse events, re-posting, then
                // restoring. Restoring is critical: without it the window would
                // stay deaf to all mouse input after the first pass-through.
                let screenLocation = convertPoint(toScreen: locationInWindow)
                let wasIgnoring = ignoresMouseEvents
                ignoresMouseEvents = true
                repostMouseEvent(event, at: screenLocation)
                ignoresMouseEvents = wasIgnoring
                return
            }
        }

        super.sendEvent(event)
    }

    private func repostMouseEvent(_ event: NSEvent, at screenLocation: NSPoint) {
        // Convert to CGEvent coordinate system (Y from top of screen).
        // The NSScreen global coordinate space is anchored to the PRIMARY
        // display (screens[0], the one with the menu bar) whose bottom-left
        // corner is (0,0). Flipping against NSScreen.main is wrong here:
        // NSScreen.main is the display holding the key window, which on a
        // multi-monitor setup can be a secondary display of a different height.
        // That offset makes the re-posted event land at the wrong Y, so the
        // window under the cursor never receives the mouse-down and a drag
        // (e.g. moving a TextEdit window) fails on the secondary display.
        guard let primaryScreen = NSScreen.screens.first else { return }
        let primaryHeight = primaryScreen.frame.height
        let cgPoint = CGPoint(x: screenLocation.x, y: primaryHeight - screenLocation.y)

        let mouseType: CGEventType
        switch event.type {
        case .leftMouseDown: mouseType = .leftMouseDown
        case .leftMouseUp: mouseType = .leftMouseUp
        case .rightMouseDown: mouseType = .rightMouseDown
        case .rightMouseUp: mouseType = .rightMouseUp
        case .leftMouseDragged: mouseType = .leftMouseDragged
        case .rightMouseDragged: mouseType = .rightMouseDragged
        default: return
        }

        let mouseButton: CGMouseButton = event.type == .rightMouseDown || event.type == .rightMouseUp ? .right : .left

        if let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: cgPoint,
            mouseButton: mouseButton
        ) {
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}
