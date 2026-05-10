import SwiftUI

/// Cmd-, settings sheet. For now hosts only the language picker —
/// future Phase 5.x sub-phases (default speed, preferred tile layer,
/// startup behaviour) will hang off the same window.
struct SettingsView: View {
    @Binding var appLanguage: AppLanguage

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General",
                          systemImage: "gear")
                }
        }
        .scenePadding()
        .frame(minWidth: 460, minHeight: 220)
    }

    @ViewBuilder
    private var generalTab: some View {
        Form {
            Section {
                Picker(selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                } label: {
                    Text("Language",
                         comment: "Settings label for UI language picker")
                }
                .pickerStyle(.menu)

                Text("Switching takes effect immediately on the next view update — no restart needed. Daemon-side error messages remain in English regardless.",
                     comment: "Help text under the language picker explaining live-switch behaviour")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Appearance",
                     comment: "Settings section header for visual / language options")
            }
        }
        .formStyle(.grouped)
    }
}
