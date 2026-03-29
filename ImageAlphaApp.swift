import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - AppDelegate — applies saved theme before first window renders

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        applyStoredTheme()
    }

    private func applyStoredTheme() {
        let raw = UserDefaults.standard.string(forKey: "appTheme") ?? AppTheme.system.rawValue
        let theme = AppTheme(rawValue: raw) ?? .system
        NSApp.appearance = theme.nsAppearance
    }
}

// MARK: - LosslyApp

@main
struct LosslyApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { ImageDocument() }) { config in
            ContentView(document: config.document)
                .frame(minWidth: 700, minHeight: 480)
        }
        .commands {
            // Replace "New" with "Open" in the File menu since Lossly
            // is a document-centric app — all work starts from an existing PNG.
            CommandGroup(replacing: .newItem) { }

            // Add "Reveal in Finder" after Save
            CommandGroup(after: .saveItem) {
                Divider()
                RevealInFinderCommand()
            }
        }

        // Native macOS Settings window (⌘,)
        Settings {
            SettingsView()
        }
    }
}

// MARK: - RevealInFinderCommand
//
// Uses FocusedValue to get the current document URL from the focused window.

private struct RevealInFinderCommand: View {
    @FocusedValue(\.documentURL) var documentURL

    var body: some View {
        Button("Reveal in Finder") {
            if let url = documentURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(documentURL == nil)
    }
}

// MARK: - FocusedValues for document URL

private struct DocumentURLKey: FocusedValueKey {
    typealias Value = URL
}

extension FocusedValues {
    var documentURL: URL? {
        get { self[DocumentURLKey.self] }
        set { self[DocumentURLKey.self] = newValue }
    }
}
