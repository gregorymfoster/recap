import SwiftUI

/// App root. M2 replaces the placeholder detail with the Library home
/// and real sidebar navigation.
public struct RootView: View {
    public init() {}

    public var body: some View {
        NavigationSplitView {
            List {
                Label("Library", systemImage: "rectangle.stack")
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(spacing: 12) {
                RecapLogo(size: 44)
                Text("Recap")
                    .font(Tokens.pageTitle)
                    .foregroundStyle(Tokens.textPrimary)
                Text("Offline meeting transcription — nothing leaves your Mac.")
                    .font(Tokens.meta)
                    .foregroundStyle(Tokens.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    RootView()
        .frame(width: 1060, height: 660)
}
