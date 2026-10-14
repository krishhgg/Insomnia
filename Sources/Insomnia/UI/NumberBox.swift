import SwiftUI

/// A small number field with its unit after it, in place of a stepper.
/// It takes digits only and sets `value` on Return, when it loses focus,
/// or when it goes away; an empty box puts the value back, and a number
/// out of `range` is pulled into it.
struct NumberBox: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String
    /// What VoiceOver reads for the field: the setting's name.
    var label: String = ""

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            TextField(label, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 52)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: text) {
                    let digits = Self.digits(text, max: Self.maxDigits(for: range))
                    if digits != text { text = digits }
                }
                .onChange(of: focused) { if !focused { commit() } }
                .onChange(of: value) { if !focused { text = String(value) } }
                .onAppear { text = String(value) }
                .onDisappear(perform: commit)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func commit() {
        if let n = Self.parse(text, in: range), n != value { value = n }
        // The setter may move the number (the floors keep their order).
        text = String(value)
    }

    /// How many digits the box takes: one more than the range's top has,
    /// so a number past the top is typed whole and pulled into the range
    /// on commit (100 in 0...95 becomes 95) instead of losing a digit and
    /// changing scale (10).
    static func maxDigits(for range: ClosedRange<Int>) -> Int {
        String(range.upperBound).count + 1
    }

    /// The digits of `text`, at most `max` of them.
    static func digits(_ text: String, max: Int) -> String {
        String(text.filter(\.isASCII).filter(\.isNumber).prefix(max))
    }

    /// The number typed, pulled into `range`; nil for an empty box.
    static func parse(_ text: String, in range: ClosedRange<Int>) -> Int? {
        guard let n = Int(digits(text, max: 9)) else { return nil }
        return min(max(n, range.lowerBound), range.upperBound)
    }
}
