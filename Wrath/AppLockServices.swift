import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import UIKit
import WrathCore

@MainActor enum AppLockServices {
    static let controller = AppLockController(
        storage: KeychainAppLockStore(), hashing: AppPINHasher(), authentication: DeviceAppAuthentication())
}

@MainActor struct KeychainAppLockStore: AppLockPersistence {
    var service = "app.wrath.downloader.app-lock"
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "pin-verifier-v1",
            kSecAttrSynchronizable as String: false,
        ]
    }

    func read() throws -> AppLockRecord? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecurityFailure.unavailable }
        return try JSONDecoder().decode(AppLockRecord.self, from: data)
    }

    func write(_ record: AppLockRecord) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(record),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecurityFailure.unavailable }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecurityFailure.unavailable }
    }
}

struct AppPINHasher: AppPINHashing {
    func create(_ pin: String) async throws -> AppPINVerifier {
        try await Task.detached(priority: .userInitiated) {
            var salt = Data(count: 16)
            let result = salt.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            guard result == errSecSuccess else { throw SecurityFailure.unavailable }
            return AppPINVerifier(salt: salt, key: try Self.derive(pin, salt: salt, iterations: 600_000))
        }.value
    }

    func matches(_ pin: String, verifier: AppPINVerifier) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            let candidate = try Self.derive(pin, salt: verifier.salt, iterations: verifier.iterations)
            guard candidate.count == verifier.key.count else { return false }
            // Do not stop at the first mismatching byte.
            var difference: UInt8 = 0
            for (lhs, rhs) in zip(candidate, verifier.key) { difference |= lhs ^ rhs }
            return difference == 0
        }.value
    }

    private static func derive(_ pin: String, salt: Data, iterations: UInt32) throws -> Data {
        var key = Data(count: 32)
        let count = pin.utf8.count
        let result = key.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                pin.withCString { password in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), password, count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        output.bindMemory(to: UInt8.self).baseAddress, output.count)
                }
            }
        }
        guard result == kCCSuccess else { throw SecurityFailure.unavailable }
        return key
    }
}

@MainActor private final class DeviceAppAuthentication: AppLockAuthenticating {
    private var context: LAContext?

    var biometricName: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return context.biometryType == .faceID ? "Face ID" : "Touch ID"
    }

    var canRecover: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(biometricsOnly: Bool) async throws {
        let request = LAContext()
        context = request
        if biometricsOnly { request.localizedFallbackTitle = "" }
        defer { if context === request { context = nil } }
        let policy: LAPolicy = biometricsOnly ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        let reason = biometricsOnly ? "Unlock Wrath" : "Verify your identity to reset your Wrath PIN"
        guard try await request.evaluatePolicy(policy, localizedReason: reason) else {
            throw SecurityFailure.unavailable
        }
    }

    func cancel() {
        context?.invalidate()
        context = nil
    }
}

private enum SecurityFailure: Error { case unavailable }
