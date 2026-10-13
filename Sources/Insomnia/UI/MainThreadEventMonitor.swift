import AppKit

/// Owns one opaque AppKit monitor token. Registration/use stay on MainActor;
/// destruction transfers only the immutable token to main, never `self`.
/// This avoids the isolated-deinit TaskLocal runtime crash on macOS 26.1.
final class MainThreadEventMonitor: @unchecked Sendable {
    private struct Token: @unchecked Sendable { let value: Any }
    private let token: Token
    private let remove: @MainActor @Sendable (Any) -> Void

    init(_ value: Any, remove: @escaping @MainActor @Sendable (Any) -> Void = { NSEvent.removeMonitor($0) }) {
        token = Token(value: value)
        self.remove = remove
    }

    deinit {
        let token = token
        let remove = remove
        if Thread.isMainThread {
            MainActor.assumeIsolated { remove(token.value) }
        } else {
            DispatchQueue.main.async { remove(token.value) }
        }
    }
}

