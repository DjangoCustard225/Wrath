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
        _enteringNewPIN = State(initialValue: action.id == "enable")
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
                            Button(action.id == "disable" ? "Turn off app lock" : "Continue") {
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
                            }.disabled(!AppLockController.validPIN(currentPIN) || lock.isBusy)
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
}

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

private struct AppPINSetupForm: View {
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

struct AppLockScreen: View {
    @Bindable var lock: AppLockController
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            Group {
                if let authorization = lock.recoveryAuthorization {
                    AppPINSetupForm(lock: lock, authorization: authorization, completed: {})
                        .navigationTitle("Reset Wrath PIN").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { lock.cancelRecovery() }.disabled(lock.isBusy)
                            }
                        }
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            Text("Wrath is locked").font(.title2.weight(.semibold))
                            Text("Enter your six-digit PIN to continue.").font(.subheadline).foregroundStyle(.secondary)
                            if !lock.storageUnavailable {
                                AppPINField(title: "Wrath PIN", text: $pin)
                                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("app-lock-pin")
                                Button {
                                    let value = pin
                                    pin = ""
                                    Task { await lock.unlock(pin: value) }
                                } label: {
                                    Text("Unlock").opacity(lock.isBusy ? 0 : 1)
                                        .frame(maxWidth: .infinity)
                                        .overlay {
                                            if lock.isBusy { ProgressView().tint(.white) }
                                        }
                                }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                                .disabled(!AppLockController.validPIN(pin) || lock.isBusy)
                                .accessibilityLabel(lock.isBusy ? "Authenticating" : "Unlock")
                                .accessibilityIdentifier("app-lock-unlock")
                                if lock.biometricsEnabled, let name = lock.biometricName {
                                    Button("Unlock with \(name)") {
                                        Task { await lock.unlockWithBiometrics() }
                                    }.disabled(lock.isBusy)
                                }
                            } else {
                                Button("Retry secure storage") { lock.reload() }.disabled(lock.isBusy)
                            }
                            if let message = lock.message {
                                Text(message).font(.footnote).foregroundStyle(.secondary)
                            }
                            AppLockRetryLabel(deadline: lock.retryAfter)
                            Button("Forgot PIN?") { Task { await lock.authorizeRecovery() } }
                                .disabled(lock.isBusy || !lock.canRecover)
                        }
                        .padding(28).frame(maxWidth: 380).frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .navigationTitle("Wrath").navigationBarTitleDisplayMode(.inline)
                }
            }
            .background(Color(uiColor: .systemBackground))
        }
        .tint(.orange)
        .task { await lock.unlockWithBiometrics(automatically: true) }
        .onChange(of: lock.revision) { _, _ in pin = "" }
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

private struct AppLockRetryLabel: View {
    let deadline: Date?
    var body: some View {
        if let deadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if deadline > context.date {
                    Text("Try your PIN again in \(Int(ceil(deadline.timeIntervalSince(context.date)))) seconds")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}
