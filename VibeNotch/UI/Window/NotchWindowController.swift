//
//  NotchWindowController.swift
//  VibeNotch
//
//  Controls the notch window positioning and lifecycle
//

import AppKit
import Combine
import SwiftUI

class NotchWindowController: NSWindowController {
    let viewModel: NotchViewModel
    private let screen: NSScreen
    private var cancellables = Set<AnyCancellable>()
    /// Tiny transparent, always-on-top window that captures clicks on the
    /// collapsed notch so the panel can be expanded without relying on global
    /// event monitors (which need Accessibility permission and let the click
    /// fall through to the app behind). The main window keeps ignoring all
    /// mouse events when closed, so the rest of the screen still passes through
    /// to whatever is behind it — menu bar, drags, everything.
    private var notchClickWindow: NSPanel?

    init(screen: NSScreen, animateOnLaunch: Bool = true) {
        self.screen = screen

        let screenFrame = screen.frame
        let notchSize = screen.notchSize

        // Window covers full width at top, tall enough for largest content (chat view)
        let windowHeight: CGFloat = 750
        let windowFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )

        // Device notch rect - positioned at center
        let deviceNotchRect = CGRect(
            x: (screenFrame.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height
        )

        // Create view model
        self.viewModel = NotchViewModel(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenFrame,
            windowHeight: windowHeight,
            hasPhysicalNotch: screen.hasPhysicalNotch
        )

        // Create the window
        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: notchWindow)

        // Create the SwiftUI view with pass-through hosting
        let hostingController = NotchViewController(viewModel: viewModel)
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(windowFrame, display: true)

        // Dynamically toggle mouse event handling based on notch state:
        // - Closed: ignoresMouseEvents = true (clicks pass through to menu bar/apps)
        // - Opened: ignoresMouseEvents = false (buttons inside panel work)
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak notchWindow, weak viewModel] status in
                switch status {
                case .opened:
                    // Accept mouse events when opened so buttons work
                    notchWindow?.ignoresMouseEvents = false
                    // Don't steal focus when opened by notification (task finished)
                    if viewModel?.openReason != .notification {
                        NSApp.activate(ignoringOtherApps: false)
                        notchWindow?.makeKey()
                    }
                case .closed, .popping:
                    // Ignore mouse events when closed so clicks pass through
                    notchWindow?.ignoresMouseEvents = true
                }
            }
            .store(in: &cancellables)

        // Start with ignoring mouse events (closed state)
        notchWindow.ignoresMouseEvents = true

        // Perform boot animation after a brief delay (only on initial launch)
        if animateOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.viewModel.performBootAnimation()
            }
        }

        // A small click target over the collapsed notch so a click expands the
        // panel instead of passing through to the window behind.
        setupNotchClickWindow()
    }

    /// A minimal, transparent, top-most window pinned over the physical notch.
    /// It only exists to catch mouse-down on the collapsed notch and open the
    /// panel; it is hidden while the panel is open so the main window fully
    /// owns interaction then.
    private func setupNotchClickWindow() {
        let notchSize = screen.notchSize
        let width = notchSize.width + 28
        let height = notchSize.height + 16

        let clickWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        clickWindow.isOpaque = false
        clickWindow.backgroundColor = .clear
        clickWindow.hasShadow = false
        clickWindow.isMovable = false
        clickWindow.isReleasedWhenClosed = false
        clickWindow.level = .mainMenu + 5
        clickWindow.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces]
        clickWindow.ignoresMouseEvents = false

        // CRITICAL: must be a floating panel so it can receive mouse events
        // while the app is inactive (VibeNotch runs as an accessory app in the
        // background). Without this the window is not eligible as the hit window
        // over the menu bar, so clicks fall through to the system status bar
        // behind it instead of opening the panel.
        clickWindow.isFloatingPanel = true
        clickWindow.allowsToolTipsWhenApplicationIsInactive = true

        let clickView = NotchClickCatcherView()
        clickView.onTap = { [weak self] in
            self?.viewModel.notchOpen(reason: .click)
        }
        clickView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        clickWindow.contentView = clickView

        // Center the catcher over the physical notch at the top of the screen.
        let screenFrame = screen.frame
        clickWindow.setFrameOrigin(NSPoint(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height))

        self.notchClickWindow = clickWindow
        clickWindow.orderFront(nil)

        // Show the catcher only while the panel is collapsed; hide it once open
        // so the main panel receives every event.
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak clickWindow] status in
                switch status {
                case .opened:
                    clickWindow?.orderOut(nil)
                case .closed, .popping:
                    clickWindow?.orderFront(nil)
                }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Transparent view whose only job is to report a click on the collapsed notch.
final class NotchClickCatcherView: NSView {
    var onTap: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    // Claim every hit within the catcher's bounds. The catcher is a tiny window
    // pinned over the physical notch; we want the entire area to be clickable so
    // the click is consumed and opens the panel instead of falling through to
    // the system status bar behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return self
    }

    // Clicks must not be forwarded anywhere else — the point is to consume the
    // click so it opens the panel instead of reaching the app behind.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
