import SwiftUI
import AppKit

// MARK: - AppTheme

enum AppTheme: String, CaseIterable, RawRepresentable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var displayName: String {
        switch self {
        case .system: return "Auto"
        case .light:  return "Light"
        case .dark:   return "Dark (Vibrant)"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .vibrantDark)
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @AppStorage("appTheme") private var themeRaw: String = AppTheme.system.rawValue

    private var theme: AppTheme {
        get { AppTheme(rawValue: themeRaw) ?? .dark }
        nonmutating set { themeRaw = newValue.rawValue }
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { theme }, set: { theme = $0 })) {
                    ForEach(AppTheme.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.inline)
                .onChange(of: themeRaw) { _, _ in
                    NSApp.appearance = theme.nsAppearance
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize()
        .onAppear {
            // Apply saved theme when settings window opens
            NSApp.appearance = theme.nsAppearance
        }
    }
}
