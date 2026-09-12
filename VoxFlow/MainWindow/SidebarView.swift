import SwiftUI
import VoxFlowCore
import VoxFlowModels

/// Full-height sidebar (design 1c): the seven pages plus the "Everything on this Mac" footer.
struct SidebarView: View {
    @Binding var selection: SidebarPage
    let requestBytes: ModelRequestByteCounter

    var body: some View {
        List(SidebarPage.allCases, selection: $selection) { page in
            Label(page.title, systemImage: page.systemImage)
                .tag(page)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarFooter(requestBytes: requestBytes)
        }
    }
}

/// Shared with native render fixtures so byte-count wrapping is checked at sidebar widths.
struct SidebarFooter: View {
    let requestBytes: ModelRequestByteCounter

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(Palette.onDevice).frame(width: 8, height: 8)
                Text("Everything on this Mac").font(.callout.weight(.semibold))
            }
            Text("VoxFlow \(VoxFlowVersion.string) · \(requestBytes.summary)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(requestBytes.measurementDetails)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
