import AppKit

/// The same pill keyboard vocabulary is used in the menu bar and its compact
/// dropdown. Neither presentation needs a text field or insertion caret.
enum DurationInputCommand: Equatable, Sendable {
    case cancel
    case submit
    case next
    case previous
    case backspace
    case digit(Int)
    case focus(DurationInput.Field)
    case ignore

    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return nil
        }
        switch event.keyCode {
        case 53: self = .cancel
        case 36, 76: self = .submit
        case 48: self = flags.contains(.shift) ? .previous : .next
        case 51, 117: self = .backspace
        case 123: self = .previous
        case 124: self = .next
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  characters.count == 1, let character = characters.first else { return nil }
            if let digit = character.wholeNumberValue, character.isASCII {
                self = .digit(digit)
                return
            }
            switch character.lowercased() {
            case "d": self = .focus(.days)
            case "h": self = .focus(.hours)
            case "m": self = .focus(.minutes)
            default:
                // Swallow stray printable keys so typing a time never beeps.
                guard character.isLetter || character.isPunctuation || character == " " else { return nil }
                self = .ignore
            }
        }
    }
}
