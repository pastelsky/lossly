import SwiftUI
import AppKit

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

    @State private var document = ImageDocument()

    var body: some Scene {
        WindowGroup {
            ContentView(document: document)
                .frame(minWidth: 700, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Remove "New Window" — Lossly is single window
            CommandGroup(replacing: .newItem) { }

            // Add "Open" to File menu
            CommandGroup(after: .newItem) {
                Button("Open...") {
                    openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // Add "Reveal in Finder"
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

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            NotificationCenter.default.post(name: .openFileURL, object: url)
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
