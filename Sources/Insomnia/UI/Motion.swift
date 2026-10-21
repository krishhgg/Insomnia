import AppKit
import SwiftUI

/// Single source of truth for every animation in the menu bar UI (spec 11).
///
/// Springs, with three exceptions: the fold that closes the pills runs on a
/// fixed-duration ease, so the moment the last pill is gone is known and
/// the slots can leave right after it; the pupil shrinking away as the lid
/// drops is a plain ease-out, no bounce; and behind Reduce Motion every
/// movement collapses into a short crossfade with no scale.
@MainActor
enum Motion {
    static let baseResponse: TimeInterval = 0.35
    static let baseDampingFraction = 0.72
    /// Baseline for layout, pill morphs and the focus ring.
    static let base: Animation = .spring(response: baseResponse, dampingFraction: baseDampingFraction)
    /// Focus bounce and icon taps: snappier, with a slight overshoot.
    static let snappy: Animation = .spring(response: 0.25, dampingFraction: 0.6)
    /// The countdown's 1 Hz text change carries no animation.
    ///
    /// Every frame of an animation is a content change, and AppKit re-renders
    /// the whole status item on each one: `NSStatusItem _updateReplicants`
    /// takes a fresh snapshot of the SwiftUI host, lays it out again and
    /// blurs it (`RenderBox`, `vImageSepConvolve`). One content change
    /// measured at about 23 ms of main thread, so the 0.18 s spring this
    /// replaced ran about twenty of them a second and held the app at about
    /// 46% of one core for as long as a session lasted. With no animation a
    /// session reads 2.3%, and one text change a second is affordable. The
    /// digits change in one step, as the menu bar clock's do.
    static let countdownTick: Animation? = nil
    /// How long the end button must be held before the session ends.
    static let holdDuration: TimeInterval = 0.6
    /// Delay between consecutive pills appearing (reversed on collapse).
    static let stagger: TimeInterval = 0.04
    /// Scale a focused pill overshoots to before settling.
    static let overshoot: CGFloat = 1.06
    /// Reduce Motion replacement for every spring.
    static let reduced: Animation = .easeInOut(duration: 0.15)

    /// A close folds the bar shut: each pill travels towards the
    /// eye by its own distance from the first slot (so all three converge
    /// on it, the farthest travelling farthest) while shrinking to
    /// `collapseScale` from its leading edge and fading out. One curve for
    /// all three, `stagger` apart, farthest first. A fixed-duration curve
    /// rather than a spring, so the moment the last pill is gone is known
    /// exactly and the slots can leave right after it.
    static let collapseDuration: TimeInterval = 0.32
    static let collapse: Animation = .easeInOut(duration: collapseDuration)
    static let collapseScale: CGFloat = 0.6
    /// Reduce Motion: opacity only, in place, a little longer than `reduced`
    /// so the pills are seen to leave rather than blink off.
    static let reducedCollapseDuration: TimeInterval = 0.2
    static let reducedCollapse: Animation = .easeInOut(duration: reducedCollapseDuration)

    static func collapse(reduceMotion: Bool = Motion.reduceMotion) -> Animation {
        reduceMotion ? reducedCollapse : collapse
    }

    /// How long after the last pill starts collapsing the slots leave the
    /// layout: the whole collapse curve, plus a frame or two so the frame
    /// that draws the pill at zero opacity has been rendered before the
    /// slot under it is removed. The settle timer starts with the last
    /// pill's step, after its stagger delay, so the delay is already counted.
    static let collapseSettleMargin: TimeInterval = 0.04
    static let retractSettleDuration: TimeInterval = collapseDuration + collapseSettleMargin
    static let reducedRetractSettleDuration: TimeInterval = reducedCollapseDuration + collapseSettleMargin

    static func retractSettle(reduceMotion: Bool = Motion.reduceMotion) -> TimeInterval {
        reduceMotion ? reducedRetractSettleDuration : retractSettleDuration
    }

    /// The eye's blink. The lid and the pupil run on their own curves, and
    /// each direction has its own, so the lid is seen lifting and the pupil
    /// is seen arriving: long enough to read as a blink, not a flicker.
    /// Opening: the lid lifts on a slow spring.
    static let blinkResponse: TimeInterval = 0.95
    static let blinkDampingFraction = 0.9
    static let blink: Animation = .spring(response: blinkResponse, dampingFraction: blinkDampingFraction)
    /// Closing: the lid drops a little quicker and nearer critical damping.
    static let blinkCloseResponse: TimeInterval = 0.8
    static let blinkCloseDampingFraction = 0.95
    static let blinkClose: Animation = .spring(response: blinkCloseResponse, dampingFraction: blinkCloseDampingFraction)
    /// Reduce Motion: the lid and the lashes crossfade instead.
    static let reducedBlinkDuration: TimeInterval = 0.3
    static let reducedBlink: Animation = .easeInOut(duration: reducedBlinkDuration)

    /// The pupil arriving behind the lifting lid: a bouncier spring (peak
    /// scale about 1.04) that starts once the lid is under way. Keyed on
    /// the eye state, so a close during the delay retargets it rather than
    /// letting it run late.
    static let pupilOpenResponse: TimeInterval = 0.5
    static let pupilOpenDampingFraction = 0.6
    static let pupilOpenDelay: TimeInterval = 0.2
    static let pupilOpen: Animation = .spring(response: pupilOpenResponse, dampingFraction: pupilOpenDampingFraction).delay(pupilOpenDelay)
    /// The pupil shrinking away as the lid drops: no delay, no bounce.
    static let pupilCloseDuration: TimeInterval = 0.4
    static let pupilClose: Animation = .easeOut(duration: pupilCloseDuration)
    /// The pupil's scale in the closed eye; 1 in the open eye and, since it
    /// never scales, under Reduce Motion.
    static let pupilClosedScale: CGFloat = 0.6

    /// The lid's blink in one direction; a crossfade under Reduce Motion.
    static func blink(opening: Bool, reduceMotion: Bool = Motion.reduceMotion) -> Animation {
        if reduceMotion { return reducedBlink }
        return opening ? blink : blinkClose
    }

    /// The pupil's blink in one direction. Under Reduce Motion it does not
    /// scale at all: only its opacity moves, on the same crossfade as the lid.
    static func pupil(opening: Bool, reduceMotion: Bool = Motion.reduceMotion) -> Animation {
        if reduceMotion { return reducedBlink }
        return opening ? pupilOpen : pupilClose
    }

    /// System Reduce Motion setting, read live so toggling it in System
    /// Settings takes effect on the next animation.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func base(reduceMotion: Bool = Motion.reduceMotion) -> Animation {
        reduceMotion ? reduced : base
    }

    static func snappy(reduceMotion: Bool = Motion.reduceMotion) -> Animation {
        reduceMotion ? reduced : snappy
    }

    /// Delay for pill `index` of `count` when expanding (`reversed == false`)
    /// or collapsing (`reversed == true`). Zero under Reduce Motion.
    static func staggerDelay(index: Int, count: Int, reversed: Bool, reduceMotion: Bool = Motion.reduceMotion) -> TimeInterval {
        guard !reduceMotion, count > 0 else { return 0 }
        let position = reversed ? (count - 1 - index) : index
        return Double(max(position, 0)) * stagger
    }

    /// Overshoot scale for a bounce, 1.0 under Reduce Motion.
    static func bounceScale(reduceMotion: Bool = Motion.reduceMotion) -> CGFloat {
        reduceMotion ? 1 : overshoot
    }

    /// Insertion transition for a pill slot born already shown: scale-and-fade,
    /// or a plain fade under Reduce Motion. The same shape `StatusRootView`
    /// drives by hand for the stagger.
    static func pillTransition(reduceMotion: Bool = Motion.reduceMotion) -> AnyTransition {
        reveal(scale: 0.55, anchor: .leading, reduceMotion: reduceMotion)
    }

    /// The countdown scaling in from (and out to) the mark's edge.
    static func countdownTransition(reduceMotion: Bool = Motion.reduceMotion) -> AnyTransition {
        reveal(scale: 0.7, anchor: .leading, reduceMotion: reduceMotion)
    }

    /// The hold-to-end ring growing in place.
    static func ringTransition(reduceMotion: Bool = Motion.reduceMotion) -> AnyTransition {
        reveal(scale: 0.5, anchor: .center, reduceMotion: reduceMotion)
    }

    /// The start-failed label: a fade in both modes.
    static func errorTransition(reduceMotion: Bool = Motion.reduceMotion) -> AnyTransition {
        .opacity.animation(base(reduceMotion: reduceMotion))
    }

    /// Scale-and-fade from `anchor`, or a plain fade under Reduce Motion.
    /// The animation rides on the transition itself, so it runs whatever
    /// transaction the insertion or removal lands in: layout state is set
    /// outside `withAnimation`, and an `.animation(_:value:)` on the
    /// enclosing container does not reach a branch switch.
    private static func reveal(scale: CGFloat, anchor: UnitPoint, reduceMotion: Bool) -> AnyTransition {
        let animation = base(reduceMotion: reduceMotion)
        if reduceMotion { return .opacity.animation(animation) }
        return .scale(scale: scale, anchor: anchor).combined(with: .opacity).animation(animation)
    }
}
