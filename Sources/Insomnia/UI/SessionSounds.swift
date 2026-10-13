import AppKit

enum SessionSoundCue: CaseIterable {
    case activated, deactivated

    /// A short sine chirp with a smooth attack and release, so neither
    /// edge clicks. Generated once per cue; no files or audio engine run.
    var waveData: Data {
        let sampleRate = 22050
        let duration = 0.14
        let count = Int(Double(sampleRate) * duration)
        let start = self == .activated ? 420.0 : 640.0
        let end = self == .activated ? 680.0 : 360.0
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let t = Double(index) / Double(sampleRate)
            let phase = 2 * Double.pi * (start * t + (end - start) * t * t / (2 * duration))
            let envelope = pow(sin(Double.pi * Double(index) / Double(count - 1)), 2)
            let sample = (sin(phase) + 0.08 * sin(2 * phase)) * envelope * 0.38
            pcm.appendLittleEndian(Int16(sample * Double(Int16.max)))
        }
        var wav = Data("RIFF".utf8)
        wav.appendLittleEndian(UInt32(36 + pcm.count))
        wav.append(Data("WAVEfmt ".utf8))
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(UInt32(sampleRate * 2))
        wav.appendLittleEndian(UInt16(2))
        wav.appendLittleEndian(UInt16(16))
        wav.append(Data("data".utf8))
        wav.appendLittleEndian(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

@MainActor
final class SessionSounds {
    static let shared = SessionSounds()
    private let activation = NSSound(data: SessionSoundCue.activated.waveData)
    private let deactivation = NSSound(data: SessionSoundCue.deactivated.waveData)

    func play(_ cue: SessionSoundCue) {
        let sound = cue == .activated ? activation : deactivation
        activation?.stop()
        deactivation?.stop()
        sound?.volume = 0.35
        sound?.play()
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
