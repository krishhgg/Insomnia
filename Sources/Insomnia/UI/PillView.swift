import SwiftUI

/// One of the Days / Hours / Minutes fields in the menu bar. Flat dark
/// rounded rectangle, unit name as placeholder, a crisp blue-grey ring when
/// focused, snappy bounce on focus and on a rejected key.
///
/// The pill is a fixed slot: its width is the placeholder's at the typed
/// weight and padding, and the visible text is centred in it. Typing never
/// changes the layout, which is what keeps the status item's width still.
///
/// Nothing here blurs or uses a material: every frame of this view is
/// composited inside the menu bar, so the cheap drawing is the point.
struct PillView: View {
    let field: DurationInput.Field
    let text: String?
    let focused: Bool
    let valid: Bool
    let glowVisible: Bool
    let focusBounce: Int
    let rejectBounce: Int
    let reduceMotion: Bool
    /// `Config.maxDuration`, for the Days tooltip.
    let maxDuration: TimeInterval
    let onTap: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }
    private var isPlaceholder: Bool { text == nil }
    /// The ring only appears once the pills have landed.
    private var ringVisible: Bool { focused && glowVisible }

    var body: some View {
        ZStack {
            // The slot: the placeholder laid out invisibly at the typed weight
            // and padding, so no digit, weight or padding change can alter
            // the pill's width and the menu bar never re-lays out on a key.
            Text(field.placeholder)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .hidden()
            Text(text ?? field.placeholder)
                .font(.system(size: 12, weight: isPlaceholder ? .regular : .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isPlaceholder ? Color.white.opacity(0.42) : Color.white)
                .contentTransition(.numericText())
                .animation(Motion.base(reduceMotion: reduceMotion), value: text)
        }
        .frame(minWidth: 28)
        .frame(height: 19)
        .background(shape.fill(Color(brand: BrandPalette.charcoal).opacity(0.92)))
        .overlay {
            shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .overlay {
            shape
                .strokeBorder(Color(brand: BrandPalette.violet).opacity(ringVisible ? 1 : 0), lineWidth: 1.5)
                .animation(Motion.base(reduceMotion: reduceMotion), value: ringVisible)
        }
        .overlay {
            shape.strokeBorder(Color.red.opacity(valid ? 0 : 0.8), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .help(field.help(maxDuration: maxDuration))
        .onTapGesture(perform: onTap)
        .phaseAnimator([CGFloat(1), Motion.bounceScale(reduceMotion: reduceMotion), 1], trigger: focused ? focusBounce : 0) { content, scale in
            content.scaleEffect(scale)
        } animation: { _ in
            Motion.snappy(reduceMotion: reduceMotion)
        }
        .phaseAnimator([CGFloat(0), reduceMotion ? 0 : -3, reduceMotion ? 0 : 3, 0], trigger: focused ? rejectBounce : 0) { content, dx in
            content.offset(x: dx)
        } animation: { _ in
            Motion.snappy(reduceMotion: reduceMotion)
        }
    }
}
