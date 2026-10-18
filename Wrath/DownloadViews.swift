import SwiftUI
import WrathCore

struct DownloadsView: View {
    @Bindable var store: DownloadStore
    @Binding var adding: Bool
    var body: some View {
        NavigationStack {
            Group {
                if let item = store.items.first(where: { $0.job.state.isActive }) {
                    ScrollView {
                        DownloadProgressView(
                            item: item, cancel: { store.cancel(item) },
                            togglePause: { store.toggleDownloadPause(item) }
                        )
                        .frame(maxWidth: 600).frame(maxWidth: .infinity)
                        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
                    }
                    .wrathSoftScrollEdges()
                } else if store.isDownloadOccupied {
                    ProgressView("Finishing up…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LiquidPlusButton(diameter: 104) { adding = true }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Wrath")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.visible, for: .navigationBar)
        }
    }
}

struct LiquidPlusButton: View {
    let diameter: CGFloat
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: diameter * 0.4, weight: .light))
                .foregroundStyle(.orange)
                .frame(width: diameter, height: diameter)
        }
        .wrathGlassButton()
        .buttonBorderShape(.circle)
        .accessibilityLabel("Add a link")
        .accessibilityHint("Choose a link to download video or audio")
    }
}
