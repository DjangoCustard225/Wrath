import SwiftUI
import WrathCore

/// Full-screen lock shown by the privacy shield, with PIN, biometric and recovery unlocking.
struct AppLockScreen: View {
    @Bindable var lock: AppLockController

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
                    LockedPane(lock: lock)
                        .navigationTitle("Wrath").navigationBarTitleDisplayMode(.inline)
                }
            }
            .background(Color(uiColor: .systemBackground))
        }
        .tint(.orange)
        .task { await lock.unlockWithBiometrics(automatically: true) }
    }
}

/// The PIN prompt shown while Wrath is locked.
private struct LockedPane: View {
    @Bindable var lock: AppLockController
    @State private var pin = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Wrath is locked").font(.title2.weight(.semibold))
                Text("Enter your six-digit PIN to continue.").font(.subheadline).foregroundStyle(.secondary)
                if !lock.storageUnavailable {
                    AppPINField(title: "Wrath PIN", text: $pin)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("app-lock-pin")
                    Button(action: unlock) {
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
        .onChange(of: lock.revision) { _, _ in pin = "" }
    }

    private func unlock() {
        let value = pin
        pin = ""
        Task { await lock.unlock(pin: value) }
    }
}

struct AppLockRetryLabel: View {
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
