import SwiftUI

/// A physical-pixel rim over system glass. The material supplies the blur
/// and refraction; this only gives the edge a quiet directional highlight.
struct GlassRim: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: scheme == .dark
                        ? [.white.opacity(0.38), .white.opacity(0.06), .white.opacity(0.16)]
                        : [.white.opacity(0.95), .black.opacity(0.08), .white.opacity(0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1 / displayScale
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    func glassRim(radius: CGFloat) -> some View {
        modifier(GlassRim(radius: radius))
    }
}
