import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ContentView
//
// NavigationSplitView gives us the native macOS sidebar:
// - Proper vibrancy / frosted-glass background automatically
// - Resizable divider via the standard sidebar handle
// - Correct sidebar width constraints + persistence

struct ContentView: View {
    @Bindable var document: ImageDocument

    var body: some View {
        NavigationSplitView {
            SidebarView(document: document)
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 340)
        } detail: {
            ImagePreviewView(
                document: document,
                background: document.selectedBackground
            )
            .navigationTitle("")
            .frame(minWidth: 300, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 600, minHeight: 420)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "png" }) else {
                return false
            }
            Task { await document.load(url: url) }
            return true
        }
    }
}
