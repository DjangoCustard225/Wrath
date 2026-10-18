import SwiftUI

// Adapted from Quby's TorrentScrollView and TorrentCardScrollEffect.
// Copyright (c) 2026 Ammar Haseeb. MIT license: Resources/Licenses/Quby.txt.
private struct LibraryScrollEffectsEnabledKey: EnvironmentKey {
    static let defaultValue = false
}
private struct LibraryScrollAtTopKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    fileprivate var libraryScrollEffectsEnabled: Bool {
        get { self[LibraryScrollEffectsEnabledKey.self] }
        set { self[LibraryScrollEffectsEnabledKey.self] = newValue }
    }
    fileprivate var libraryScrollAtTop: Bool {
        get { self[LibraryScrollAtTopKey.self] }
        set { self[LibraryScrollAtTopKey.self] = newValue }
    }
}

struct LibraryListScrollView<Content: View>: View {
    private let content: Content
    @State private var hasStartedScrolling = false
    @State private var isAnimatingScroll = false
    @State private var isUserScrolling = false
    @State private var isAtTop = true

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) { content }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .environment(\.libraryScrollEffectsEnabled, hasStartedScrolling && !isAnimatingScroll)
                .environment(\.libraryScrollAtTop, isAtTop)
        }
    }

    @ViewBuilder private var trackedScroll: some View {
        if #available(iOS 18, *) {
            scrollContent.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top <= 1
            } action: { _, atTop in
                isAtTop = atTop
                if !atTop, isUserScrolling { hasStartedScrolling = true }
            }
            .onScrollPhaseChange { _, phase in
                let animating = phase == .animating
                let userScrolling = phase == .interacting || phase == .decelerating
                let started = !animating && (hasStartedScrolling || userScrolling)
                guard
                    hasStartedScrolling != started || isAnimatingScroll != animating || isUserScrolling != userScrolling
                else { return }
                hasStartedScrolling = started
                isAnimatingScroll = animating
                isUserScrolling = userScrolling
            }
        } else {
            scrollContent
        }
    }

    var body: some View {
        trackedScroll.contentMargins(.bottom, 48, for: .scrollContent)
            .wrathSoftScrollEdges()
            .wrathLibraryToolbar(atTop: isAtTop)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

struct LibraryCardScrollEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.libraryScrollEffectsEnabled) private var effectsEnabled
    @Environment(\.libraryScrollAtTop) private var isAtTop

    func body(content: Content) -> some View {
        let active = effectsEnabled && !reduceMotion
        let atTop = isAtTop
        return content.scrollTransition(
            // Keep the graph stable during native scroll-to-top and lazy row jumps.
            topLeading: .interactive.threshold(.visible.inset(by: 70)),
            bottomTrailing: .interactive.threshold(.visible.inset(by: 70)),
            axis: .vertical
        ) { effect, phase in
            let applyEffect = active && !phase.isIdentity && !(atTop && phase == .topLeading)
            return effect.opacity(applyEffect ? 0.65 : 1).scaleEffect(applyEffect ? 0.92 : 1)
        }
    }
}
