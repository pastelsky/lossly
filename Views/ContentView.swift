import SwiftUI
import AppKit

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
            .navigationTitle("Lossly")
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
        .onReceive(NotificationCenter.default.publisher(for: .openFileURL)) { note in
            guard let url = note.object as? URL else { return }
            Task { await document.load(url: url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportImage)) { _ in
            guard document.quantizedData != nil || document.sourceData != nil else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = document.suggestedFilename
            panel.prompt = "Export"
            if let dir = document.sourceDirectoryURL { panel.directoryURL = dir }
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                let data = document.quantizedData ?? document.sourceData
                try? data?.write(to: url, options: .atomic)
            }
        }
    }
}
