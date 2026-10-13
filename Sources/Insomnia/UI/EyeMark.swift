import SwiftUI

/// The almond lens on its own, for stroking.
struct EyeLens: Shape {
    func path(in rect: CGRect) -> Path {
        Path(EyeMarkGeometry.lens(in: rect))
    }
}

struct EyeAperture: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func path(in rect: CGRect) -> Path {
        Path(EyeMarkGeometry.aperture(in: rect, progress: progress))
    }
}

/// The lid that shades the lens, for filling: nothing at 1, the whole lens at 0.
struct EyeLid: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(EyeMarkGeometry.lid(in: rect, progress: progress))
    }
}

/// The five lashes on one side of the lens, for stroking. They never move.
struct EyeLashes: Shape {
    let side: EyeMarkGeometry.Side

    func path(in rect: CGRect) -> Path {
        Path(EyeMarkGeometry.lashes(in: rect, side: side))
    }
}

/// Fades one set of lashes with the blink: the lower set is gone by half
/// way, the upper set only starts to show from there, so no lash is ever
/// seen while the lid edge passes its side of the lens. Animatable so the
/// timing follows the lid's own progress rather than a plain crossfade.
nonisolated struct EyeLashFade: ViewModifier, Animatable {
    var progress: CGFloat
    let side: EyeMarkGeometry.Side

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private var opacity: CGFloat {
        let x = side == .above ? (progress - 0.5) * 2 : 1 - progress * 2
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    func body(content: Content) -> some View {
        content.opacity(opacity)
    }
}

/// The pupil with its highlight bitten out, for filling.
struct EyePupil: Shape {
    func path(in rect: CGRect) -> Path {
        Path(EyeMarkGeometry.pupil(in: rect))
    }
}

/// The pupil as the blink draws it: scaled about its own centre and faded,
/// then clipped to the lens outline, so neither the opening spring's
/// overshoot nor a blink interrupted at its peak can show it outside the
/// lens. The highlight bite is part of the same path, so it is clipped too.
struct EyePupilLayer: View {
    var scale: CGFloat
    var opacity: CGFloat

    /// The pupil's centre as a fraction of the (square) mark.
    static let anchor = UnitPoint(
        x: EyeMarkGeometry.pupilCenter.x / EyeMarkGeometry.designSize,
        y: EyeMarkGeometry.pupilCenter.y / EyeMarkGeometry.designSize
    )

    var body: some View {
        EyePupil()
            .fill(.black)
            .scaleEffect(scale, anchor: Self.anchor)
            .opacity(opacity)
            .clipShape(EyeLens())
    }
}

/// The status item rests on a fine closed lid with lashes below. While
/// sleep is held its upper contour lifts, revealing the pupil and lashes
/// above. The change is a blink: the lid lifts
/// while the lashes swap sides, and the pupil arrives behind it a beat
/// later (`Motion.pupilOpenDelay`) and shrinks away as the lid drops; or a
/// crossfade under Reduce Motion, where the pupil only fades.
/// Everything is drawn in `.primary`, so the mark follows the light or dark
/// menu bar and never takes a tint.
struct EyeMarkView: View {
    /// 0 closed, 1 open.
    let progress: CGFloat
    let reduceMotion: Bool
    var size: CGFloat = 17
    @Environment(\.displayScale) private var displayScale
    @State private var renderedState: BlinkState

    /// What the blink's animations are keyed on. Keying on both means a
    /// Reduce Motion change mid-blink is itself a value change, so it
    /// crossfades from the current presentation instead of jumping, and
    /// any delayed pupil animation still pending is retargeted.
    struct BlinkState: Equatable {
        var progress: CGFloat
        var reduceMotion: Bool
    }

    init(isRunning: Bool, reduceMotion: Bool, size: CGFloat = 17) {
        self.init(progress: isRunning ? 1 : 0, reduceMotion: reduceMotion, size: size)
    }

    /// One frozen frame of the blink, for previews.
    init(progress: CGFloat, reduceMotion: Bool = true, size: CGFloat = 17) {
        self.progress = progress
        self.reduceMotion = reduceMotion
        self.size = size
        _renderedState = State(initialValue: BlinkState(progress: progress, reduceMotion: reduceMotion))
    }

    static func stroke(size: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: EyeLensGeometry.lineWidth(for: size), lineCap: .round, lineJoin: .round)
    }

    private var state: BlinkState { BlinkState(progress: progress, reduceMotion: reduceMotion) }
    private var opening: Bool { renderedState.progress > 0.5 }

    /// The pupil's scale for this state: full in the open eye, shrunk in
    /// the closed one, and never anything else under Reduce Motion. A frozen
    /// frame between the two is drawn part way, for previews.
    var pupilScale: CGFloat {
        reduceMotion ? 1 : Motion.pupilClosedScale + (1 - Motion.pupilClosedScale) * min(max(progress, 0), 1)
    }

    /// The pupil's opacity for this state: present in the open eye, gone in
    /// the closed one.
    var pupilOpacity: CGFloat {
        min(max(progress, 0), 1)
    }

    var body: some View {
        // One adaptive ink mask prevents overlapping strokes from doubling
        // the system label colour's opacity.
        Rectangle()
            .fill(.primary)
            .mask { layers }
            .frame(width: size, height: size)
            .onChange(of: state) { _, target in
                // Keep the mask's drawing state local so its opening has an
                // explicit animation transaction even when the status item's
                // layout and width change without animation at the same time.
                withAnimation(Motion.blink(opening: target.progress > 0.5, reduceMotion: target.reduceMotion)) {
                    renderedState = target
                }
            }
    }

    private var layers: some View {
        // Snap the stroke weight to physical pixels at the current display
        // scale. Geometry stays vector-based on both Retina and 1x screens.
        var stroke = Self.stroke(size: size)
        stroke.lineWidth = max(1, (stroke.lineWidth * displayScale).rounded()) / displayScale
        let progress = renderedState.progress
        let reduceMotion = renderedState.reduceMotion
        let scale = reduceMotion ? 1 : Motion.pupilClosedScale + (1 - Motion.pupilClosedScale) * min(max(progress, 0), 1)
        return ZStack {
            EyeAperture(progress: reduceMotion ? 1 : progress)
                .stroke(.black, style: stroke)
                .opacity(reduceMotion ? progress : 1)
                .animation(Motion.blink(opening: opening, reduceMotion: reduceMotion), value: renderedState)
            if reduceMotion {
                EyeAperture(progress: 0)
                    .stroke(.black, style: stroke)
                    .opacity(1 - progress)
                    .animation(Motion.reducedBlink, value: renderedState)
            }
            // The pupil runs on its own curve, keyed on the eye state so a
            // close during its opening delay retargets it from wherever it is.
            EyePupilLayer(scale: scale, opacity: min(max(progress, 0), 1))
                .animation(Motion.pupil(opening: opening, reduceMotion: reduceMotion), value: renderedState)
                .clipShape(EyeAperture(progress: reduceMotion ? 1 : progress))
                .animation(Motion.blink(opening: opening, reduceMotion: reduceMotion), value: renderedState)
            // The lid and the lashes share the lid's curve, so the lash
            // hand-over follows the lid edge. Under Reduce Motion the closed
            // lid crossfades instead of lifting; the lashes hand over the
            // same way in both modes.
            Group {
                EyeLashes(side: .below)
                    .stroke(.black, style: stroke)
                    .modifier(EyeLashFade(progress: progress, side: .below))
                EyeLashes(side: .above)
                    .stroke(.black, style: stroke)
                    .modifier(EyeLashFade(progress: progress, side: .above))
            }
            .animation(Motion.blink(opening: opening, reduceMotion: reduceMotion), value: renderedState)
        }
    }
}
