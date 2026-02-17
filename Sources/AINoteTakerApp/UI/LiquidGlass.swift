import SwiftUI

struct LiquidGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 16
    var contentPadding: CGFloat = 16
    var material: Material = .regularMaterial

    func body(content: Content) -> some View {
        content
            .padding(contentPadding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(material)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                colorScheme == .dark
                                ? Color.black.opacity(0.30)
                                : Color.white.opacity(0.22)
                            )
                    )
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.28),
                                Color.white.opacity(colorScheme == .dark ? 0.02 : 0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                        ? Color.white.opacity(0.12)
                        : Color.black.opacity(0.10),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.16 : 0.08),
                radius: colorScheme == .dark ? 10 : 8,
                x: 0,
                y: colorScheme == .dark ? 4 : 3
            )
    }
}

extension View {
    func liquidGlassCard(
        cornerRadius: CGFloat = 16,
        padding: CGFloat = 16,
        material: Material = .regularMaterial
    ) -> some View {
        modifier(
            LiquidGlassCardModifier(
                cornerRadius: cornerRadius,
                contentPadding: padding,
                material: material
            )
        )
    }

    func liquidGlassPanel(cornerRadius: CGFloat = 22, padding: CGFloat = 16) -> some View {
        modifier(
            LiquidGlassCardModifier(
                cornerRadius: cornerRadius,
                contentPadding: padding,
                material: .ultraThinMaterial
            )
        )
    }
}
