//
//  EventMonitors.swift
//  VibeNotch
//
//  Singleton that aggregates all event monitors
//

import AppKit
import Combine

class EventMonitors {
    static let shared = EventMonitors()

    let mouseDown = PassthroughSubject<NSEvent, Never>()

    private var mouseDownMonitor: EventMonitor?

    private init() {
        setupMonitors()
    }

    private func setupMonitors() {
        mouseDownMonitor = EventMonitor(mask: .leftMouseDown) { [weak self] event in
            self?.mouseDown.send(event)
        }
        mouseDownMonitor?.start()
    }

    deinit {
        mouseDownMonitor?.stop()
    }
}
