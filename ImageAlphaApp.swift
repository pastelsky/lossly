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
                .navigationTitle("Lossly")
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.png]
                    panel.allowsMultipleSelection = false
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        NotificationCenter.default.post(name: .openFileURL, object: url)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .saveItem) {
                Button("Export…") {
                    NotificationCenter.default.post(name: .exportImage, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)

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

// MARK: - Notification for file open

extension Notification.Name {
    static let openFileURL = Notification.Name("com.lossly.openFileURL")
    static let exportImage = Notification.Name("com.lossly.exportImage")
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
