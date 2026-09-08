import SwiftUI
import VoxFlowCore

/// Full-height sidebar (design 1c): the seven pages plus the "Everything on this Mac" footer.
struct SidebarView: View {
    @Binding var selection: SidebarPage

    var body: some View {
        List(SidebarPage.allCases, selection: $selection) { page in
            Label(page.title, systemImage: page.systemImage)
                .tag(page)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(Palette.onDevice).frame(width: 8, height: 8)
                Text("Everything on this Mac").font(.callout.weight(.semibold))
            }
            // TODO(phase 4): derive "bytes sent" from the network counter instead of a literal.
            Text("VoxFlow \(VoxFlowVersion.string) · 0 bytes sent since install")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
