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
        clickWindow.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces]
        clickWindow.ignoresMouseEvents = false

        // Must be a floating panel so it can receive mouse events while the app
        // is inactive (VibeNotch runs as an accessory app in the background).
        clickWindow.isFloatingPanel = true
        clickWindow.allowsToolTipsWhenApplicationIsInactive = true
        // Keep the catcher on screen even though VibeNotch is an inactive
        // accessory app — otherwise it hides the moment the app loses focus and
        // stops catching clicks.
        clickWindow.hidesOnDeactivate = false

        // CRITICAL ORDERING: set the level AFTER isFloatingPanel. Setting
        // isFloatingPanel = true silently resets the window level back to
        // .floating (3). At level 3 the window sits BELOW the menu bar (24), so
        // the system status bar covers it and every click falls through to the
        // status bar. A low-level window is also nudged down below the menu bar
        // by the window server, so it no longer covers the notch. Setting the
        // level last (above the menu bar) fixes both.
        clickWindow.level = .mainMenu + 5

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
        // Re-assert the level right before showing (defensive: nothing above
        // should have reset it), then order front regardless of app activation
        // so the catcher sits above the menu bar while the app is inactive.
        clickWindow.level = .mainMenu + 5
        clickWindow.orderFrontRegardless()

        // Show the catcher only while the panel is collapsed; hide it once open
        // so the main panel receives every event.
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak clickWindow] status in
                switch status {
                case .opened:
                    clickWindow?.orderOut(nil)
                case .closed, .popping:
                    clickWindow?.level = .mainMenu + 5
                    clickWindow?.orderFrontRegardless()
                }
            }
            .store(in: &cancellables)

        // Keep the catcher's width in sync with the collapsed notch content so
        // clicks on the activity-expanded sides (processing spinner, pending
        // indicator, waiting-for-input checkmark) are still captured instead of
        // falling through to the status bar.
        viewModel.$collapsedContentWidth
            .receive(on: DispatchQueue.main)
            .sink { [weak self] width in
                self?.updateCatcherWidth(contentWidth: width)
            }
            .store(in: &cancellables)
    }

    /// Size the catcher to the collapsed notch content width (device notch + any
    /// activity expansion), keeping it centered and pinned to the screen's top
    /// edge. Falls back to the bare notch width before the view reports a width.
    private func updateCatcherWidth(contentWidth: CGFloat) {
        guard let clickWindow = notchClickWindow else { return }
        let notch = screen.notchSize
        let height = notch.height + 16
        // `contentWidth` is the notch + expansion content width reported by the
        // view; add horizontal padding so the catcher fully covers the rendered
        // pill (which carries its own horizontal padding plus a transient bounce).
        let width = max(notch.width + 28, contentWidth + 48)
        guard abs(clickWindow.frame.width - width) > 0.5 else { return }

        let screenFrame = screen.frame
        let origin = NSPoint(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height)
        clickWindow.setFrame(
            NSRect(origin: origin, size: NSSize(width: width, height: height)),
            display: false
        )
        // Re-assert the level after a frame change and keep it front while
        // collapsed (the window stays ordered out while the panel is open).
        clickWindow.level = .mainMenu + 5
        if viewModel.status != .opened {
            clickWindow.orderFrontRegardless()
        }
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
