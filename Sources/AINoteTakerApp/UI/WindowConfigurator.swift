import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.bind(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            context.coordinator.bind(to: window)
        }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var leftMouseDownMonitor: Any?
        private let fullscreenToggleZoneHeight: CGFloat = 44
        private let trafficLightsSafeWidth: CGFloat = 84

        deinit {
            removeMonitor()
        }

        func bind(to window: NSWindow) {
            configure(window)
            guard self.window !== window else { return }
            self.window = window
            installMonitor()
        }

        private func configure(_ window: NSWindow) {
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.collectionBehavior.insert(.fullScreenPrimary)
            let isFullscreen = window.styleMask.contains(.fullScreen)
            window.hasShadow = !isFullscreen

            if let frameView = window.contentView?.superview {
                frameView.wantsLayer = true
                frameView.layer?.cornerCurve = .continuous
                frameView.layer?.cornerRadius = isFullscreen ? 0 : 18
                frameView.layer?.masksToBounds = !isFullscreen
            }
        }

        private func installMonitor() {
            removeMonitor()
            leftMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self else { return event }
                return self.handleLeftMouseDown(event)
            }
        }

        private func handleLeftMouseDown(_ event: NSEvent) -> NSEvent? {
            guard event.clickCount == 2 else { return event }
            guard let window, event.window === window else { return event }
            guard let bounds = window.contentView?.bounds else { return event }

            let location = event.locationInWindow
            let isInTopZone = location.y >= (bounds.height - fullscreenToggleZoneHeight)
            guard isInTopZone else { return event }

            // Keep native traffic-light interactions untouched.
            guard location.x >= trafficLightsSafeWidth else { return event }

            DispatchQueue.main.async { [weak window] in
                window?.toggleFullScreen(nil)
            }
            return event
        }

        private func removeMonitor() {
            if let leftMouseDownMonitor {
                NSEvent.removeMonitor(leftMouseDownMonitor)
                self.leftMouseDownMonitor = nil
            }
        }
    }
}
