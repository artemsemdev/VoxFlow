import SwiftUI

/// Stand-in content until each page is built (phases 2–4).
struct PlaceholderPageView: View {
    let page: SidebarPage

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: page.systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(page.title)
                .font(.title2.weight(.semibold))
            Text("Coming in a later phase.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(page.title)
    }
}
