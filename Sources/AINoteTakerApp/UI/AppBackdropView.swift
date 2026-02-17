import SwiftUI
import AppKit

private struct VisualEffectGlassView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // Keep backdrop behavior stable between windowed and fullscreen.
        view.blendingMode = .withinWindow
        view.material = .windowBackground
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.blendingMode = .withinWindow
        nsView.material = .windowBackground
        nsView.state = .active
        nsView.isEmphasized = false
    }
}

struct AppBackdropView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            VisualEffectGlassView()
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.06),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 80,
                endRadius: 720
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [
                    colorScheme == .dark
                    ? Color(red: 0.09, green: 0.10, blue: 0.16)
                    : Color(red: 0.98, green: 0.98, blue: 0.99),
                    colorScheme == .dark
                    ? Color(red: 0.05, green: 0.06, blue: 0.11)
                    : Color(red: 0.96, green: 0.96, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(colorScheme == .dark ? 0.42 : 0.20)
            .ignoresSafeArea()

            if colorScheme == .dark {
                Color.black.opacity(0.10)
                    .ignoresSafeArea()
            } else {
                Color.white.opacity(0.02)
                    .ignoresSafeArea()
            }
        }
    }
}
