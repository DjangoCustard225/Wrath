import Foundation
import Observation

public struct AppPINVerifier: Codable, Equatable, Sendable {
    public let salt: Data
    public let key: Data
    public let iterations: UInt32
    public init(salt: Data, key: Data, iterations: UInt32 = 600_000) {
        self.salt = salt
        self.key = key
        self.iterations = iterations
    }
}

public struct AppLockRecord: Codable, Equatable, Sendable {
    public var version = 1
    public var verifier: AppPINVerifier
    public var biometrics: Bool
    public var failures = 0
    public var retryAfter: Date?
    public init(verifier: AppPINVerifier, biometrics: Bool) {
        self.verifier = verifier
        self.biometrics = biometrics
    }
    public var isValid: Bool {
        version == 1 && verifier.salt.count == 16 && verifier.key.count == 32
            && verifier.iterations == 600_000 && failures >= 0 && failures <= 1_000_000
            && (retryAfter?.timeIntervalSince1970.isFinite ?? true)
    }
}

@MainActor public protocol AppLockPersistence {
    func read() throws -> AppLockRecord?
    func write(_ record: AppLockRecord) throws
    func remove() throws
}

public protocol AppPINHashing: Sendable {
    func create(_ pin: String) async throws -> AppPINVerifier
    func matches(_ pin: String, verifier: AppPINVerifier) async throws -> Bool
}

@MainActor public protocol AppLockAuthenticating {
    var biometricName: String? { get }
    var canRecover: Bool { get }
    func authenticate(biometricsOnly: Bool) async throws
    func cancel()
}

/// Authentication is independent of download execution and of individual scenes.
/// All async results and management grants are invalidated when the app locks.
@Observable @MainActor public final class AppLockController {
    public enum State: Sendable { case loading, locked, authenticating, unlocked }
    public private(set) var state: State = .loading
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var storageUnavailable = false
    public private(set) var revision = UUID()
    public private(set) var recoveryAuthorization: UUID?
    private var record: AppLockRecord?
    @ObservationIgnored private let storage: any AppLockPersistence
    @ObservationIgnored private let hashing: any AppPINHashing
    @ObservationIgnored private let authentication: any AppLockAuthenticating
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var changeAuthorization: UUID?
    @ObservationIgnored private var biometricAttempted = false

    public var isEnabled: Bool { record != nil || storageUnavailable || state == .loading }
    public var isUnlocked: Bool { state == .unlocked }
    public var biometricsEnabled: Bool { record?.biometrics == true }
    public var biometricName: String? { authentication.biometricName }
    public var canRecover: Bool { authentication.canRecover }
    public var retryAfter: Date? { record?.retryAfter }

    public init(
        storage: any AppLockPersistence, hashing: any AppPINHashing,
        authentication: any AppLockAuthenticating, now: @escaping () -> Date = Date.init
    ) {
        self.storage = storage
        self.hashing = hashing
        self.authentication = authentication
        self.now = now
        reload()
    }

    public func reload() {
        guard !isBusy else { return }
        do {
            let restored = try storage.read()
            guard restored?.isValid != false else { throw LockFailure.invalidRecord }
            record = restored
            storageUnavailable = false
            message = nil
            state = restored == nil ? .unlocked : .locked
        } catch {
            storageUnavailable = true
            state = .locked
            message = "Secure app lock storage is unavailable. Unlock your device and try again."
        }
        invalidateGrants()
    }

    public func lock() {
        if !isEnabled {
            // Setup can still be hashing its first PIN when the app leaves the
            // foreground. Do not let that stale result enable an unlocked lock.
            if isBusy {
                authentication.cancel()
                invalidateGrants()
                isBusy = false
            }
            return
        }
        authentication.cancel()
        invalidateGrants()
        isBusy = false
        state = .locked
        message = storageUnavailable ? "Secure app lock storage is unavailable. Try again." : nil
        biometricAttempted = false
    }

    public func clearMessage() { message = nil }

    @discardableResult public func unlock(pin: String) async -> Bool {
        guard !isUnlocked else { return true }
        return await verify(pin, unlocking: true)
    }

    public func authorizeChange(pin: String) async -> UUID? {
        let operation = revision
        guard isUnlocked, await verify(pin, unlocking: false), revision == operation, isUnlocked else { return nil }
        let grant = UUID()
        changeAuthorization = grant
        return grant
    }

    private func verify(_ pin: String, unlocking: Bool) async -> Bool {
        guard !isBusy, !storageUnavailable, let current = record else { return false }
        guard Self.validPIN(pin) else {
            message = "Enter a six-digit PIN."
            return false
        }
        guard current.retryAfter.map({ $0 <= now() }) ?? true else {
            message = "Too many attempts. Wait for the timer before trying your PIN again."
            return false
        }
        let operation = revision
        let previousState = state
        isBusy = true
        if unlocking { state = .authenticating }
        message = nil
        do {
            let matches = try await hashing.matches(pin, verifier: current.verifier)
            guard revision == operation else { return false }
            if matches {
                try clearFailures()
                state = unlocking ? .unlocked : previousState
                isBusy = false
                return true
            }
            var failed = current
            failed.failures = min(1_000_000, failed.failures + 1)
            if failed.failures >= 5 {
                let delay = min(300, 30 * pow(2, Double(min(4, failed.failures - 5))))
                failed.retryAfter = now().addingTimeInterval(delay)
            }
            try storage.write(failed)
            record = failed
            message = failed.retryAfter == nil ? "Incorrect PIN. Try again." : "Too many attempts. Please wait."
            state = previousState
        } catch {
            guard revision == operation else { return false }
            failClosed()
        }
        isBusy = false
        return false
    }

    @discardableResult public func unlockWithBiometrics(automatically: Bool = false) async -> Bool {
        guard !isBusy, !isUnlocked, !storageUnavailable, biometricsEnabled, biometricName != nil else { return false }
        if automatically && biometricAttempted { return false }
        biometricAttempted = true
        let operation = revision
        state = .authenticating
        isBusy = true
        message = nil
        do {
            try await authentication.authenticate(biometricsOnly: true)
            guard revision == operation else { return false }
            do { try clearFailures() } catch {
                failClosed()
                isBusy = false
                return false
            }
            state = .unlocked
            isBusy = false
            return true
        } catch {
            guard revision == operation else { return false }
            message = "Enter your Wrath PIN or try biometric unlocking again."
            state = .locked
            isBusy = false
            return false
        }
    }

    public func authorizeRecovery() async {
        guard isEnabled, !isBusy else { return }
        guard canRecover else {
            message = "Device authentication is unavailable. Enter your Wrath PIN."
            return
        }
        let operation = revision
        isBusy = true
        state = .authenticating
        message = nil
        do {
            try await authentication.authenticate(biometricsOnly: false)
            guard revision == operation else { return }
            recoveryAuthorization = UUID()
            state = .locked
        } catch {
            guard revision == operation else { return }
            message = "Device authentication did not finish. Your PIN has not changed."
            state = .locked
        }
        isBusy = false
    }

    public func cancelRecovery() {
        guard !isBusy else { return }
        invalidateGrants()
        message = nil
        state = .locked
    }

    @discardableResult public func setPIN(_ pin: String, biometrics: Bool, authorization: UUID?) async -> Bool {
        guard !isBusy else { return false }
        let recovering = authorization != nil && authorization == recoveryAuthorization
        let changing = authorization != nil && authorization == changeAuthorization && isUnlocked
        let creating = !isEnabled && isUnlocked && authorization == nil
        guard recovering || changing || creating else {
            message = "Authenticate again to change your PIN."
            return false
        }
        guard Self.validPIN(pin) else {
            message = "Choose a six-digit PIN."
            return false
        }
        guard canRecover else {
            message = "Set a device passcode in iOS Settings before enabling app lock."
            return false
        }
        let operation = revision
        isBusy = true
        message = nil
        do {
            let verifier = try await hashing.create(pin)
            guard revision == operation else { return false }
            let updated = AppLockRecord(verifier: verifier, biometrics: biometrics && biometricName != nil)
            guard updated.isValid else { throw LockFailure.invalidRecord }
            try storage.write(updated)
            record = updated
            storageUnavailable = false
            state = .unlocked
            invalidateGrants()
            isBusy = false
            return true
        } catch {
            guard revision == operation else { return false }
            message = "Could not save the PIN securely. Your previous app lock settings have been kept."
            isBusy = false
            return false
        }
    }

    @discardableResult public func disable(authorization: UUID) -> Bool {
        guard !isBusy, isUnlocked, changeAuthorization == authorization, !storageUnavailable else { return false }
        do {
            try storage.remove()
            record = nil
            state = .unlocked
            message = nil
            invalidateGrants()
            return true
        } catch {
            message = "Could not disable app lock securely. Your PIN is still required."
            return false
        }
    }

    @discardableResult public func setBiometrics(_ enabled: Bool, authorization: UUID) -> Bool {
        guard !isBusy, isUnlocked, changeAuthorization == authorization,
            !storageUnavailable, var updated = record
        else { return false }
        guard !enabled || biometricName != nil else {
            message = "Biometric unlocking is unavailable."
            return false
        }
        do {
            updated.biometrics = enabled
            try storage.write(updated)
            record = updated
            message = nil
            invalidateGrants()
            return true
        } catch {
            message = "Could not save app lock settings. Your previous settings have been kept."
            return false
        }
    }

    private func clearFailures() throws {
        guard var updated = record, updated.failures > 0 || updated.retryAfter != nil else { return }
        updated.failures = 0
        updated.retryAfter = nil
        try storage.write(updated)
        record = updated
    }

    private func failClosed() {
        storageUnavailable = true
        state = .locked
        message = "Secure app lock storage is unavailable. Unlock your device and try again."
        invalidateGrants()
    }

    private func invalidateGrants() {
        revision = UUID()
        changeAuthorization = nil
        recoveryAuthorization = nil
    }

    public static func validPIN(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private enum LockFailure: Error { case invalidRecord }
}
