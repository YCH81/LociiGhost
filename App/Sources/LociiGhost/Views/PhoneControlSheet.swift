import SwiftUI

/// Modal sheet that surfaces the LAN URL + 6-digit PIN for the
/// daemon's phone-control HTTP server. The user types both into
/// their phone's browser; on success the phone gets a mobile UI
/// for teleport / navigate / restore / stop / search / coord.
///
/// The sheet auto-fetches `/api/phone/info` on appear — that
/// endpoint is localhost-only on the daemon side, so the URL and
/// PIN here NEVER leave this Mac except through the user typing
/// them into the phone.
struct PhoneControlSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Phone Control",
                         comment: "Phone Control sheet title")
                        .font(.headline)
                    Text("Type the URL into your phone's browser, then enter the PIN.",
                         comment: "Phone Control sheet subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            if state.isLoadingPhoneInfo && state.phoneControlInfo == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading…",
                         comment: "Phone Control info still loading")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 30)
            } else if let info = state.phoneControlInfo {
                infoBlock(info: info)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Phone control HTTP server isn't reachable.",
                             comment: "Phone Control failed to load")
                            .font(.callout)
                    }
                    Text("Make sure the daemon is running (Authenticate above if the banner is showing) and try again.",
                         comment: "Phone Control failure recovery hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await state.fetchPhoneControlInfo() }
                    } label: {
                        Label("Retry",
                              systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
            }

            Spacer(minLength: 4)

            HStack {
                if state.phoneControlInfo != nil {
                    Button {
                        Task { await state.rotatePhoneControlPIN() }
                    } label: {
                        Label("Regenerate PIN",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help(LocalizedStringKey(
                        "Generate a fresh PIN + token. Any phone tab still using the old PIN gets logged out."
                    ))

                    // Hard kill switch — kicks every authenticated
                    // phone tab AND rotates the PIN so they can't
                    // reconnect with the old credentials. Always
                    // visible (not gated on phoneSessionActive)
                    // so the user can pre-emptively clear a
                    // forgotten phone tab sitting on someone
                    // else's screen.
                    Button(role: .destructive) {
                        Task { await state.forcePhoneLogout() }
                    } label: {
                        Label("Sign out all phones",
                              systemImage: "person.crop.circle.badge.xmark")
                    }
                    .tint(.red)
                    .help(LocalizedStringKey(
                        "Sign every paired phone out and rotate the PIN."
                    ))
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 320)
        .task {
            // Auto-fetch on first appear. Subsequent re-opens get a
            // fresh fetch too so a stale PIN never lingers in the UI.
            await state.fetchPhoneControlInfo()
        }
    }

    @ViewBuilder
    private func infoBlock(info: PhoneControlInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("URL",
                     comment: "Phone Control sheet — section label for the LAN URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(info.url)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(info.url, forType: .string)
                    } label: {
                        Label("Copy",
                              systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("PIN",
                     comment: "Phone Control sheet — section label for the 6-digit PIN")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack {
                    Text(info.pin)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .tracking(8)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
            }

            Text("Phone must be on the same Wi-Fi as this Mac. The PIN regenerates each time the daemon restarts; tap Regenerate below to invalidate any phone that's currently paired.",
                 comment: "Phone Control help text under URL/PIN")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
