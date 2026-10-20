import SwiftUI
import UIKit
import WrathCore

/// A separate scene window covers every presentation, including sheets and
/// previews, without rebuilding the app or interrupting its download store.
struct AppPrivacyShield: UIViewControllerRepresentable {
    let lock: AppLockController
    let enabled: Bool
    let locked: Bool
    @Environment(\.scenePhase) private var phase

    func makeUIViewController(context: Context) -> PrivacyHostController {
        PrivacyHostController(lock: lock)
    }

    func updateUIViewController(_ controller: PrivacyHostController, context: Context) {
        controller.setPhase(phase)
    }

    static func dismantleUIViewController(_ controller: PrivacyHostController, coordinator: ()) {
        controller.stop()
    }
}

@MainActor final class PrivacyHostController: UIViewController {
    private let lock: AppLockController
    private var privacyWindow: UIWindow?
    private var hosting: UIHostingController<PrivacyShieldContent>?
    private weak var scene: UIWindowScene?
    private weak var originalWindow: UIWindow?
    private var active = false
    private var deactivatedBySystem = false
    private var unlockAnimator: UIViewPropertyAnimator?
    private var unlockTransitionID: UUID?

    init(lock: AppLockController) {
        self.lock = lock
        super.init(nibName: nil, bundle: nil)
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(deactivate), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(activate), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sceneDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sceneActivate(_:)), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sceneBackground(_:)), name: UIScene.didEnterBackgroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let attachment = PrivacyAttachmentView()
        attachment.isUserInteractionEnabled = false
        attachment.attached = { [weak self] in self?.refresh() }
        view = attachment
    }

    func setPhase(_ phase: ScenePhase) {
        // UIKit notifications protect snapshots before SwiftUI delivers its
        // scene-phase update. An older SwiftUI render must not uncover content.
        active =
            phase == .active && !deactivatedBySystem
            && (scene == nil || scene?.activationState == .foregroundActive)
        if phase == .background { lockIfAllScenesBackgrounded() }
        refresh()
    }

    @objc private func deactivate() {
        deactivatedBySystem = true
        active = false
        originalWindow?.endEditing(true)
        privacyWindow?.endEditing(true)
        refresh()
    }

    @objc private func activate() {
        deactivatedBySystem = false
        active = scene?.activationState == .foregroundActive
        refresh()
    }

    @objc private func background() {
        deactivatedBySystem = true
        active = false
        lockIfAllScenesBackgrounded()
        refresh()
    }

    @objc private func sceneDeactivate(_ note: Notification) {
        guard let changed = note.object as? UIWindowScene, changed === scene else { return }
        deactivate()
    }

    @objc private func sceneActivate(_ note: Notification) {
        guard let changed = note.object as? UIWindowScene, changed === scene else { return }
        activate()
    }

    @objc private func sceneBackground(_ note: Notification) {
        guard let changed = note.object as? UIWindowScene, changed === scene else { return }
        active = false
        deactivatedBySystem = true
        lockIfAllScenesBackgrounded()
        refresh()
    }

    private func lockIfAllScenesBackgrounded() {
        let anyForeground = UIApplication.shared.connectedScenes.contains {
            $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
        }
        if !anyForeground { lock.lock() }
    }

    private func refresh() {
        guard let attachedScene = viewIfLoaded?.window?.windowScene ?? scene else { return }
        if scene == nil {
            scene = attachedScene
            active = !deactivatedBySystem && attachedScene.activationState == .foregroundActive
        }
        let needed = lock.isEnabled && (!active || !lock.isUnlocked)
        guard needed else {
            hide(animated: active && lock.isUnlocked)
            return
        }
        // Re-cover synchronously if the app leaves the foreground mid-unlock.
        cancelUnlockTransition()
        if privacyWindow == nil {
            originalWindow = attachedScene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: attachedScene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .systemBackground
            let host = UIHostingController(rootView: PrivacyShieldContent(lock: lock, active: active))
            host.view.backgroundColor = .systemBackground
            host.view.accessibilityViewIsModal = true
            window.rootViewController = host
            hosting = host
            privacyWindow = window
        }
        originalWindow?.accessibilityElementsHidden = true
        if !active {
            originalWindow?.endEditing(true)
            privacyWindow?.endEditing(true)
        }
        hosting?.rootView = PrivacyShieldContent(lock: lock, active: active)
        if active && !lock.isUnlocked {
            if privacyWindow?.isKeyWindow != true {
                if let keyWindow = attachedScene.windows.first(where: { $0.isKeyWindow && $0 !== privacyWindow }) {
                    originalWindow = keyWindow
                }
                privacyWindow?.makeKeyAndVisible()
            }
        } else {
            privacyWindow?.isHidden = false
        }
    }

    private func cancelUnlockTransition() {
        unlockTransitionID = nil
        unlockAnimator?.stopAnimation(true)
        unlockAnimator = nil
        privacyWindow?.alpha = 1
    }

    private func hide(animated: Bool = false) {
        guard let window = privacyWindow, !window.isHidden else { return }
        guard animated else {
            cancelUnlockTransition()
            finishHiding()
            return
        }
        guard unlockAnimator == nil else { return }
        window.endEditing(true)
        let transitionID = UUID()
        unlockTransitionID = transitionID
        let animator = UIViewPropertyAnimator(
            duration: UIAccessibility.isReduceMotionEnabled ? 0.12 : 0.28, curve: .easeOut
        ) {
            window.alpha = 0
        }
        animator.addCompletion { [weak self] position in
            guard let self, self.unlockTransitionID == transitionID else { return }
            self.unlockAnimator = nil
            self.unlockTransitionID = nil
            guard position == .end, self.active, self.lock.isUnlocked else {
                window.alpha = 1
                self.refresh()
                return
            }
            self.finishHiding()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
        unlockAnimator = animator
        animator.startAnimation()
    }

    private func finishHiding() {
        let restoreKey = privacyWindow?.isKeyWindow == true
        privacyWindow?.isHidden = true
        privacyWindow?.alpha = 1
        originalWindow?.accessibilityElementsHidden = false
        if restoreKey && scene?.activationState == .foregroundActive { originalWindow?.makeKey() }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        cancelUnlockTransition()
        hide()
        privacyWindow?.rootViewController = nil
        hosting = nil
        privacyWindow = nil
    }
}

private final class PrivacyAttachmentView: UIView {
    var attached: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { attached?() }
    }
}

private struct PrivacyShieldContent: View {
    let lock: AppLockController
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if active {
                AppLockScreen(lock: lock)
                    .allowsHitTesting(!lock.isUnlocked)
                    .accessibilityHidden(lock.isUnlocked)
                    .transition(.opacity)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.down").font(.system(size: 44, weight: .semibold)).foregroundStyle(.orange)
                    Text("Wrath").font(.largeTitle.weight(.bold))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .animation(active ? .easeOut(duration: reduceMotion ? 0.12 : 0.18) : nil, value: active)
        .accessibilityIdentifier("app-privacy-shield")
    }
}
