import SwiftUI
import AppKit

struct ScrollChromeConfigurator: NSViewRepresentable {
    var colorScheme: ColorScheme

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let root = nsView.window?.contentView else { return }
            Self.configureScrollViews(in: root, colorScheme: colorScheme)
        }
    }

    private static func configureScrollViews(in root: NSView, colorScheme: ColorScheme) {
        for scrollView in allScrollViews(in: root) {
            scrollView.scrollerStyle = .overlay
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.verticalScroller?.controlSize = .small
            scrollView.verticalScroller?.knobStyle = colorScheme == .dark ? .light : .dark
        }
    }

    private static func allScrollViews(in root: NSView) -> [NSScrollView] {
        var views: [NSScrollView] = []
        if let scroll = root as? NSScrollView {
            views.append(scroll)
        }
        for child in root.subviews {
            views.append(contentsOf: allScrollViews(in: child))
        }
        return views
    }
}
