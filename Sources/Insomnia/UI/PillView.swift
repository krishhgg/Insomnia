import SwiftUI

/// One of the Days / Hours / Minutes fields in the menu bar. Native glass
/// rounded rectangle, unit name as placeholder, a crisp accent ring when
/// focused, snappy bounce on focus and on a rejected key.
///
/// The pill is a fixed slot: its width is the placeholder's at the typed
/// weight and padding, and the visible text is centred in it. Typing never
/// changes the layout, which is what keeps the status item's width still.
///
struct PillView: View {
    let field: DurationInput.Field
    let text: String?
    let focused: Bool
    let valid: Bool
    let glowVisible: Bool
    let focusBounce: Int
    let rejectBounce: Int
    let reduceMotion: Bool
    let onTap: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }
    private var isPlaceholder: Bool { text == nil }
    /// The ring only appears once the pills have landed.
    private var ringVisible: Bool { focused && glowVisible }

    var body: some View {
        Button(action: onTap) { animatedPill }
            .buttonStyle(.plain)
            .help(field.help)
            .accessibilityLabel(field.placeholder)
            .accessibilityValue(text ?? "Empty")
    }

    private var animatedPill: some View {
        glassPill
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

    private var glassPill: some View {
        pillContent
            .glassEffect(.regular.interactive(), in: shape)
            .overlay { focusRing }
            .overlay { shape.strokeBorder(Color.red.opacity(valid ? 0 : 0.8), lineWidth: 1) }
            .contentShape(Rectangle())
    }

    private var focusRing: some View {
        shape
            .strokeBorder(Color.accentColor.opacity(ringVisible ? 1 : 0), lineWidth: 1.5)
            .animation(Motion.base(reduceMotion: reduceMotion), value: ringVisible)
    }

    private var pillContent: some View {
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
                .foregroundStyle(isPlaceholder ? Color.secondary : Color.primary)
                .contentTransition(.numericText())
                .animation(Motion.base(reduceMotion: reduceMotion), value: text)
        }
        .frame(minWidth: 28)
        .frame(height: 19)
    }
}
