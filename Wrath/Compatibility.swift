import SwiftUI

// Shared controls keep both build variants on the same view and data paths.
extension View {
    @ViewBuilder func wrathGlassButton(clear: Bool = false) -> some View {
        #if WRATH_COMPATIBILITY
            self.buttonStyle(.bordered)
        #else
            if #available(iOS 26, *) {
                if clear { self.buttonStyle(.glass(.clear)) } else { self.buttonStyle(.glass) }
            } else {
                self.buttonStyle(.bordered)
            }
        #endif
    }

    @ViewBuilder func wrathBottomBar<Bar: View>(@ViewBuilder content: () -> Bar) -> some View {
        #if WRATH_COMPATIBILITY
            self.safeAreaInset(edge: .bottom, spacing: 0) { content().background(.bar) }
        #else
            if #available(iOS 26, *) {
                self.safeAreaBar(edge: .bottom, spacing: 0, content: content)
            } else {
                self.safeAreaInset(edge: .bottom, spacing: 0) { content().background(.bar) }
            }
        #endif
    }

    @ViewBuilder func wrathSoftScrollEdges() -> some View {
        #if WRATH_COMPATIBILITY
            self
        #else
            if #available(iOS 26, *) { self.scrollEdgeEffectStyle(.soft, for: .all) } else { self }
        #endif
    }

    @ViewBuilder func wrathHideBottomEdge(_ hidden: Bool) -> some View {
        #if WRATH_COMPATIBILITY
            self
        #else
            if #available(iOS 26, *) { self.scrollEdgeEffectHidden(hidden, for: .bottom) } else { self }
        #endif
    }

    @ViewBuilder func wrathMinimizeTabs() -> some View {
        #if WRATH_COMPATIBILITY
            self
        #else
            if #available(iOS 26, *) { self.tabBarMinimizeBehavior(.onScrollDown) } else { self }
        #endif
    }

    @ViewBuilder func wrathLibraryToolbar(atTop: Bool) -> some View {
        #if WRATH_COMPATIBILITY
            self
        #else
            if #available(iOS 27, *) {
                self.toolbarMinimizationBehavior(atTop ? .never : .onScrollDown, for: .navigationBar)
                    .toolbarMinimizationRestoration(.atScrollEdge, for: .navigationBar)
                    .toolbarMinimizationSafeAreaAdjustment(.disabled, for: .navigationBar)
            } else {
                self
            }
        #endif
    }
}
