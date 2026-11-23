import Foundation
import Testing

@testable import WrathCore

@MainActor private final class MemoryLockStore: AppLockPersistence {
    var record: AppLockRecord?
    var failWrites = false
    func read() throws -> AppLockRecord? { record }
    func write(_ record: AppLockRecord) throws {
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        self.record = record
    }
    func remove() throws { record = nil }
}

/// Stores the PIN itself; the real hasher's cost is irrelevant to controller logic.
private struct PlainHasher: AppPINHashing {
    func create(_ pin: String) async throws -> AppPINVerifier {
        AppPINVerifier(salt: Data(repeating: 1, count: 16), key: Data(pin.utf8) + Data(repeating: 0, count: 26))
    }
    func matches(_ pin: String, verifier: AppPINVerifier) async throws -> Bool {
        try await create(pin).key == verifier.key
    }
}

@MainActor private final class FakeAuthentication: AppLockAuthenticating {
    var biometricName: String? = "Face ID"
    var canRecover = true
    var succeeds = true
    func authenticate(biometricsOnly: Bool) async throws {
        if !succeeds { throw CancellationError() }
    }
    func cancel() {}
}

@MainActor @Suite struct AppLockControllerTests {
    private let store = MemoryLockStore()
    private let authentication = FakeAuthentication()
    private var clock = Date(timeIntervalSince1970: 1_000)

    private func controller() -> AppLockController {
        let now = clock
        return AppLockController(
            storage: store, hashing: PlainHasher(), authentication: authentication, now: { now })
    }

    private func enabledController(pin: String = "123456") async -> AppLockController {
        let lock = controller()
        #expect(await lock.setPIN(pin, biometrics: true, authorization: nil))
        return lock
    }

    @Test func startsUnlockedWithoutAStoredPIN() {
        let lock = controller()
        #expect(lock.isUnlocked)
        #expect(!lock.isEnabled)
    }

    @Test func locksAndUnlocksWithTheRightPIN() async {
        let lock = await enabledController()
        lock.lock()
        #expect(!lock.isUnlocked)
        #expect(!(await lock.unlock(pin: "000000")))
        #expect(lock.message == "Incorrect PIN. Try again.")
        #expect(await lock.unlock(pin: "123456"))
        #expect(lock.isUnlocked)
    }

    @Test func backsOffAfterRepeatedFailures() async {
        let lock = await enabledController()
        lock.lock()
        for _ in 0..<5 { _ = await lock.unlock(pin: "000000") }
        #expect(lock.retryAfter == clock.addingTimeInterval(30))
        #expect(!(await lock.unlock(pin: "123456")))
        #expect(lock.message == "Too many attempts. Wait for the timer before trying your PIN again.")
    }

    @Test func rejectsInvalidPINs() {
        #expect(AppLockController.validPIN("123456"))
        #expect(!AppLockController.validPIN("12345"))
        #expect(!AppLockController.validPIN("12345a"))
        #expect(!AppLockController.validPIN("１２３４５６"))
    }

    @Test func changesRequireAFreshGrant() async throws {
        let lock = await enabledController()
        let grant = try #require(await lock.authorizeChange(pin: "123456"))
        lock.lock()
        #expect(!lock.disable(authorization: grant))
        #expect(await lock.unlock(pin: "123456"))
        let fresh = try #require(await lock.authorizeChange(pin: "123456"))
        #expect(lock.disable(authorization: fresh))
        #expect(!lock.isEnabled)
    }

    @Test func failsClosedWhenStorageBreaks() async {
        let lock = await enabledController()
        lock.lock()
        store.failWrites = true
        _ = await lock.unlock(pin: "000000")
        #expect(lock.storageUnavailable)
        #expect(!lock.isUnlocked)
    }

    @Test func recoveryLetsTheOwnerSetANewPIN() async throws {
        let lock = await enabledController()
        lock.lock()
        await lock.authorizeRecovery()
        let grant = try #require(lock.recoveryAuthorization)
        #expect(await lock.setPIN("654321", biometrics: false, authorization: grant))
        lock.lock()
        #expect(await lock.unlock(pin: "654321"))
    }
}
