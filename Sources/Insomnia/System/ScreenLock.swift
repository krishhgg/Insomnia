import Foundation

/// Failure to lock the screen. `what` is the whole story: which framework or
/// symbol was missing, or what the call returned.
struct ScreenLockError: Error, LocalizedError, Sendable {
    let what: String

    var errorDescription: String? { what }
}

/// Locks the login session so the password is asked on the next wake or lid
/// open. The Mac itself stays awake.
protocol ScreenLocking: Sendable {
    func lockNow() throws
}

/// Calls `SACLockScreenImmediate` from the login framework, the call behind
/// Ctrl+Cmd+Q. This is a private Apple API with no documentation or
/// stability promise: an OS update can rename or remove it. That is why a
/// failure is thrown and shown in the menu instead of being swallowed.
/// Symbols are resolved once, lazily, under a lock, like the brightness wrappers.
/// Measured on macOS 27.0.1 (M4): with an active session it locks about one
/// second after the lid closes, and the Mac stays awake with the network up.
final class LoginFrameworkScreenLocker: ScreenLocking, @unchecked Sendable {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    private static let symbolName = "SACLockScreenImmediate"

    typealias LockScreenImmediate = @convention(c) () -> Int32

    private let lock = NSLock()
    private let resolveSymbols: @Sendable () -> Result<LockScreenImmediate, ScreenLockError>
    private var resolved: Result<LockScreenImmediate, ScreenLockError>?

    init() {
        resolveSymbols = Self.resolve
    }

    /// Injected for tests so resolving and calling never lock the real session.
    init(resolve: @escaping @Sendable () -> Result<LockScreenImmediate, ScreenLockError>) {
        resolveSymbols = resolve
    }

    func lockNow() throws {
        let function = try symbols()
        let status = function()
        guard status == 0 else {
            throw ScreenLockError(what: "\(Self.symbolName) returned \(status)")
        }
    }

    private func symbols() throws -> LockScreenImmediate {
        try lock.withLock {
            if let resolved { return try resolved.get() }
            let result = resolveSymbols()
            resolved = result
            return try result.get()
        }
    }

    private static func resolve() -> Result<LockScreenImmediate, ScreenLockError> {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            return .failure(ScreenLockError(what: "login.framework could not be loaded"))
        }
        guard let pointer = dlsym(handle, symbolName) else {
            return .failure(ScreenLockError(what: "login.framework has no \(symbolName)"))
        }
        return .success(unsafeBitCast(pointer, to: LockScreenImmediate.self))
    }
}

/// Does nothing; the default where a test or a caller does not lock.
struct NoopScreenLocker: ScreenLocking {
    func lockNow() throws {}
}
