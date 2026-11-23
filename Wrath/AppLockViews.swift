import SwiftUI
import WrathCore

struct AppLockSettingsView: View {
    @Environment(AppLockController.self) private var lock
    @State private var action: AppLockAction?

    var body: some View {
        Form {
            Section {
                if lock.isEnabled {
                    LabeledContent("App lock", value: "On")
                    Button("Change PIN") { action = .change }
                    if let name = lock.biometricName {
                        Toggle(
                            name,
                            isOn: Binding(
                                get: { lock.biometricsEnabled }, set: { action = .biometrics($0) }))
                    } else if lock.biometricsEnabled {
                        LabeledContent("Biometric unlocking", value: "Unavailable")
                        Button("Turn off biometric unlocking") { action = .biometrics(false) }
                    }
                    Button("Turn off app lock", role: .destructive) { action = .disable }
                } else {
                    Button("Set up app lock", systemImage: "lock") { action = .enable }
                        .disabled(!lock.canRecover)
                    if !lock.canRecover {
                        Text("Set a device passcode in iOS Settings to enable App Lock.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Six-digit PIN with optional Face ID or Touch ID. Recover it with device authentication.")
            }
            if lock.isEnabled {
                Section {
                    LabeledContent("Auto-lock", value: "Immediately")
                    LabeledContent("Live Activity details", value: "Hidden")
                }
            }
            Section {
                Text("App Lock doesn't encrypt saved files in Files.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("App Lock").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $action) { action in
            AppLockManagementSheet(action: action, lock: lock)
        }
    }
}

private enum AppLockAction: Identifiable {
    case enable, change, disable
    case biometrics(Bool)
    var id: String {
        switch self {
        case .enable: "enable"
        case .change: "change"
        case .disable: "disable"
        case .biometrics(let enabled): "biometrics-\(enabled)"
        }
    }
    var setsNewPIN: Bool {
        if case .enable = self { return true }
        return false
    }
    var isDisable: Bool {
        if case .disable = self { return true }
        return false
    }
    var title: String {
        switch self {
        case .enable: "Set Up App Lock"
        case .change: "Change PIN"
        case .disable: "Turn Off App Lock"
        case .biometrics: "Biometric Unlocking"
        }
    }
}

private struct AppLockManagementSheet: View {
    let action: AppLockAction
    @Bindable var lock: AppLockController
    @Environment(\.dismiss) private var dismiss
    @State private var currentPIN = ""
    @State private var authorization: UUID?
    @State private var enteringNewPIN: Bool

    init(action: AppLockAction, lock: AppLockController) {
        self.action = action
        self.lock = lock
        _enteringNewPIN = State(initialValue: action.setsNewPIN)
    }

    var body: some View {
        NavigationStack {
            Group {
                if enteringNewPIN {
                    AppPINSetupForm(lock: lock, authorization: authorization) { dismiss() }
                } else {
                    Form {
                        Section("Current Wrath PIN") {
                            AppPINField(title: "Six-digit PIN", text: $currentPIN)
                        }
                        AppLockFeedback(lock: lock)
                        Section {
                            Button(action.isDisable ? "Turn off app lock" : "Continue", action: confirmCurrentPIN)
                                .disabled(!AppLockController.validPIN(currentPIN) || lock.isBusy)
                        }
                    }
                }
            }
            .navigationTitle(action.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(lock.isBusy)
                }
            }
        }
        .interactiveDismissDisabled(lock.isBusy)
        .onAppear { lock.clearMessage() }
        .onChange(of: lock.revision) { _, _ in dismiss() }
    }

    /// Checks the current PIN, then applies the action or moves on to choosing a new PIN.
    private func confirmCurrentPIN() {
        let pin = currentPIN
        currentPIN = ""
        Task {
            guard let grant = await lock.authorizeChange(pin: pin) else { return }
            switch action {
            case .disable:
                if lock.disable(authorization: grant) { dismiss() }
            case .biometrics(let enabled):
                if lock.setBiometrics(enabled, authorization: grant) { dismiss() }
            case .change:
                authorization = grant
                enteringNewPIN = true
            case .enable: break
            }
        }
    }
}

/// A six-digit numeric secure field that drops any other characters as they are typed.
struct AppPINField: View {
    let title: String
    @Binding var text: String
    var body: some View {
        SecureField(title, text: $text)
            .keyboardType(.numberPad).textContentType(.none)
            .privacySensitive().monospacedDigit()
            .onChange(of: text) { _, value in
                let filtered = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                if filtered != value { text = filtered }
            }
    }
}

/// Chooses a new PIN, for first setup, a change, or recovery after device authentication.
struct AppPINSetupForm: View {
    @Bindable var lock: AppLockController
    let authorization: UUID?
    let completed: () -> Void
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var biometrics = true

    init(lock: AppLockController, authorization: UUID?, completed: @escaping () -> Void) {
        self.lock = lock
        self.authorization = authorization
        self.completed = completed
        _biometrics = State(initialValue: lock.isEnabled ? lock.biometricsEnabled : true)
    }

    var body: some View {
        Form {
            Section {
                AppPINField(title: "Six-digit PIN", text: $pin)
                AppPINField(title: "Confirm PIN", text: $confirmation)
            } header: {
                Text("New Wrath PIN")
            } footer: {
                Text("Choose a six-digit PIN for Wrath. Recovery uses your device's authentication.")
            }
            if let name = lock.biometricName {
                Section { Toggle("Use \(name)", isOn: $biometrics) }
            }
            if confirmation.count == 6 && pin != confirmation {
                Section { Text("The PINs do not match.").foregroundStyle(.secondary) }
            }
            AppLockFeedback(lock: lock)
            Section {
                Button("Save PIN") {
                    let value = pin
                    pin = ""
                    confirmation = ""
                    Task {
                        if await lock.setPIN(value, biometrics: biometrics, authorization: authorization) {
                            completed()
                        }
                    }
                }
                .disabled(!AppLockController.validPIN(pin) || pin != confirmation || lock.isBusy)
            }
        }
    }
}

private struct AppLockFeedback: View {
    let lock: AppLockController
    var body: some View {
        if lock.isBusy || lock.message != nil || lock.retryAfter != nil {
            Section {
                if lock.isBusy { ProgressView("Authenticating…") }
                if let message = lock.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                AppLockRetryLabel(deadline: lock.retryAfter)
            }
        }
    }
}
