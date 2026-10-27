import SwiftUI

/// The one button style in the popover. AppKit's bordered buttons there
/// carry their own hover, and an effect layered over it read as two hovers
/// in a row; this draws the whole button itself, so each button has one
/// hover state, shown at once with no animation, and a pressed state.
struct PopoverButtonStyle: ButtonStyle {
    enum Kind {
        /// The preset and extend chips and the warning rows' buttons: a
        /// soft rounded fill, a little stronger under the pointer.
        case chip
        /// Start / Extend: the accent fill, lighter under the pointer.
        case prominent
        /// Settings and Quit: no fill until the pointer is over them.
        case plain
    }

    var kind: Kind
    /// A chip that stands for something switched on (Custom with the fields
    /// out): its fill at rest is the pressed one.
    var selected = false

    /// The space between a button's label and its edge. A plain button's
    /// row is outset by its `leading`, so the labels line up with the rest
    /// of the popover while the hover fill reaches past them.
    static func insets(_ kind: Kind) -> EdgeInsets {
        switch kind {
        case .chip: EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
        case .prominent: EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        case .plain: EdgeInsets(top: DesignTokens.Space.xxs, leading: DesignTokens.Space.s, bottom: DesignTokens.Space.xxs, trailing: DesignTokens.Space.s)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        PopoverButtonBody(kind: kind, selected: selected, configuration: configuration)
    }
}

private struct PopoverButtonBody: View {
    let kind: PopoverButtonStyle.Kind
    let selected: Bool
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private enum Look { case rest, hover, pressed }

    private var look: Look {
        guard isEnabled else { return .rest }
        if configuration.isPressed { return .pressed }
        return hovering ? .hover : .rest
    }

    private var font: Font {
        switch kind {
        case .chip: .system(size: NSFont.systemFontSize(for: .small))
        case .prominent: .body.weight(.medium)
        case .plain: .subheadline
        }
    }

    private var fill: AnyShapeStyle {
        let hover = DesignTokens.Hover.self
        let chipBase = hover.chipFill + (selected ? hover.pressedFill : 0)
        switch (kind, look) {
        case (.chip, .rest): return AnyShapeStyle(Color.primary.opacity(chipBase))
        case (.chip, .hover): return AnyShapeStyle(Color.primary.opacity(chipBase + hover.fill))
        case (.chip, .pressed): return AnyShapeStyle(Color.primary.opacity(chipBase + hover.pressedFill))
        case (.prominent, .rest): return AnyShapeStyle(Color.accentColor)
        case (.prominent, .hover): return AnyShapeStyle(Color.accentColor.mix(with: .white, by: hover.prominentLift))
        case (.prominent, .pressed): return AnyShapeStyle(Color.accentColor.mix(with: .black, by: hover.prominentPress))
        case (.plain, .rest): return AnyShapeStyle(Color.clear)
        case (.plain, .hover): return AnyShapeStyle(Color.primary.opacity(hover.fill))
        case (.plain, .pressed): return AnyShapeStyle(Color.primary.opacity(hover.pressedFill))
        }
    }

    private var foreground: AnyShapeStyle {
        if kind == .prominent { return AnyShapeStyle(Color.white.opacity(isEnabled ? 1 : 0.6)) }
        return isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
    }

    /// One line, always: Start / Extend, Settings and Quit take the width
    /// their label needs ("Extend" never breaks into "Ex-tend"). A chip's
    /// label sizes itself, since it fills its cell.
    @ViewBuilder private var label: some View {
        if kind == .chip {
            configuration.label
        } else {
            configuration.label.lineLimit(1).fixedSize()
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Hover.radius, style: .continuous)
        label
            .font(font)
            .foregroundStyle(foreground)
            .padding(PopoverButtonStyle.insets(kind))
            .background(shape.fill(fill))
            .opacity(kind == .prominent && !isEnabled ? 0.5 : 1)
            .contentShape(shape)
            .onHover { hovering = $0 }
            // One state at a time, switched at once: nothing fades.
            .transaction { $0.animation = nil }
    }
}
