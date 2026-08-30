import SwiftUI
import AppKit
import LociiGhostCore

/// Pikmin Bloom 拉金盆 (Gold-Ditto exploit) — ported from
/// LocWarp 0.2.143.
///
/// Idea: during the in-game flower-bud animation the game
/// momentarily stops verifying the player's location. If we push
/// the iPhone's GPS to a different point (the user's REAL
/// location, "A") inside that animation window and then immediately
/// restore real GPS, the game credits the reward to A — the gold
/// pot itself stays "unclaimed" and can be milked again.
///
/// Flow:
///   1. User flies the iPhone to the gold-pot (any movement mode)
///   2. User opens the flower bud on the phone
///   3. User waits for the "Swipe down for reward" UI
///   4. User waits another 2 seconds
///   5. User clicks "Pull Gold Pot" on the Mac
///   6. Mac runs a small countdown (visual + audible) so the user
///      knows exactly when to swipe on the phone
///   7. Mac fires `location.gold_ditto` → daemon does set(A) +
///      clear() inside the animation window
///   8. User swipes down on phone → game claims reward at A
struct GoldDittoPanel: View {
    @Environment(AppState.self) private var state

    /// "A" coordinate string the user types or pastes. Persisted
    /// across launches so they don't have to retype their real
    /// location each session — most players park at one favourite
    /// spot to claim from.
    @AppStorage("goldDittoACoord") private var aCoordRaw: String = ""
    @State private var aHidden: Bool = false

    /// Countdown state. `running` flips to true on button press;
    /// the timer below decrements `secondsRemaining` until it hits
    /// 0, then fires the daemon RPC.
    @State private var running: Bool = false
    @State private var secondsRemaining: Int = 0
    @State private var status: String = ""
    /// `true` for ~5 seconds after the RPC fires so we can paint
    /// a big green banner that screams "GO swipe NOW". The plain
    /// `status` line under the button was too quiet — users
    /// reported the round-trip felt invisible and assumed it had
    /// silently failed.
    @State private var showSwipeNowBanner: Bool = false
    @State private var countdownTask: Task<Void, Never>?
    /// Picker between the two firing modes. Persisted so the
    /// user's preferred style sticks across launches — most
    /// users settle into one or the other.
    @AppStorage("goldDittoMode") private var fireMode: FireMode = .countdown

    /// Two operating modes for the Gold-Ditto cycle:
    ///
    ///   * `.countdown` — Mac-style: button press starts a visible
    ///     2-second countdown with beeps, RPC fires at zero. Best
    ///     when you want the Mac to handle the "wait 2 seconds
    ///     after the UI" rule for you.
    ///   * `.instant` — pure LocWarp parity: button press fires
    ///     set+clear immediately, you handle all timing yourself.
    ///     Faster cycles per minute, but you have to count the
    ///     2-second wait in your head.
    enum FireMode: String, CaseIterable, Identifiable {
        case countdown
        case instant
        var id: String { rawValue }
    }

    /// How long the visible countdown lasts before the RPC fires.
    /// **Two seconds** mirrors the LocWarp 0.2.143 documented
    /// timing — `goldditto.flow_help` in the original i18n file
    /// says "wait for the Swipe-down prompt, then wait another
    /// 2 seconds before tapping below" and the button itself
    /// fires set+clear instantly. Our 2-second countdown reaches
    /// "0 → fire" at the same point LocWarp's authors recommend.
    /// We don't know the actual animation-window length, so the
    /// safe default is to match the only timing that has
    /// empirical backing from the original project.
    private static let countdownSeconds = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            modeSpecificInstructions
                .font(.caption)
                .foregroundStyle(.secondary)

            // ---- A coordinate input -----------------------------
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("A coordinate (your real location)",
                         comment: "GoldDittoPanel — label above the A coord field")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button {
                        aHidden.toggle()
                    } label: {
                        Image(systemName: aHidden ? "eye.slash" : "eye")
                            .padding(2)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .hoverHighlight(cornerRadius: 4)
                    .help(LocalizedStringKey(aHidden ? "Show A coordinate" : "Hide A coordinate"))
                }
                if aHidden {
                    Text(aCoordRaw.isEmpty ? "—" : "•••••, •••••")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08),
                                    in: .rect(cornerRadius: 5))
                } else {
                    TextField("e.g. 25.034897, 121.545827",
                              text: $aCoordRaw)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                }
                HStack(spacing: 6) {
                    Button {
                        useCurrent()
                    } label: {
                        Label("Use current location",
                              systemImage: "location.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverHighlight(cornerRadius: 5)
                    Button {
                        paste()
                    } label: {
                        Label("Paste",
                              systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverHighlight(cornerRadius: 5)
                    Spacer()
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))

            // ---- Mode picker (countdown vs instant) -------------
            Picker("", selection: $fireMode) {
                Text("Countdown (2 s)",
                     comment: "GoldDittoPanel — Mac-style 2-second countdown mode label")
                    .tag(FireMode.countdown)
                Text("Instant",
                     comment: "GoldDittoPanel — instant-fire mode label")
                    .tag(FireMode.instant)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(LocalizedStringKey("Countdown gives you a visible 2-second timer with beeps before fire. Instant fires set+clear the moment you click, matching the original LocWarp behaviour exactly."))

            // ---- Countdown / fire button ------------------------
            if running {
                countdownView
            } else {
                fireButton
            }

            // Big "GO swipe now" banner — only painted briefly
            // after the RPC fires. Loud green so the user can see
            // it without looking away from the phone at the Mac.
            if showSwipeNowBanner {
                swipeNowBanner
                    .transition(.scale.combined(with: .opacity))
            } else if !status.isEmpty {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear {
            // Cancel any in-flight countdown if the user collapses
            // the section. We don't want a stray RPC to fire 3
            // seconds after they navigated away.
            countdownTask?.cancel()
            countdownTask = nil
            running = false
        }
    }

    // MARK: - Countdown view

    private var countdownView: some View {
        VStack(spacing: 8) {
            Text("\(secondsRemaining)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(secondsRemaining <= 1 ? Color.red : Color.lociSage)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 8))

            Text("Pulling the gold pot in…",
                 comment: "GoldDittoPanel — instructional text shown during the countdown")
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button(role: .cancel) {
                cancelCountdown()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .hoverHighlight(cornerRadius: 5)
        }
    }

    /// Two-line help text that flips with `fireMode` so each mode
    /// describes its own behaviour clearly. Pre-v1.5 we shipped a
    /// single combined paragraph that mentioned "swipe down for
    /// reward" — but the action the user actually performs is
    /// 拉金盆 (the GPS round-trip), not the in-game swipe. The
    /// new copy describes ONLY what this button does.
    @ViewBuilder
    private var modeSpecificInstructions: some View {
        switch fireMode {
        case .countdown:
            Text("Countdown mode: press the button to start a 2-second countdown, then the Mac will pull the gold pot (swap GPS to A and back).",
                 comment: "GoldDittoPanel — instructions for countdown mode")
        case .instant:
            Text("Instant mode: press the button to pull the gold pot immediately (swap GPS to A and back, no countdown).",
                 comment: "GoldDittoPanel — instructions for instant mode")
        }
    }

    private var swipeNowBanner: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                Text("Gold pot pulled",
                     comment: "GoldDittoPanel — banner heading after the RPC completes")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(.white)
            Text("GPS was swapped to A and back",
                 comment: "GoldDittoPanel — banner subheading describing what just happened")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.green.gradient, in: .rect(cornerRadius: 8))
        .shadow(color: Color.green.opacity(0.4), radius: 6, y: 2)
    }

    private var fireButton: some View {
        Button {
            switch fireMode {
            case .countdown: startCountdown()
            case .instant:   fireInstant()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Pull Gold Pot",
                     comment: "GoldDittoPanel — primary action button")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.yellow)
        .disabled(!canFire)
        .hoverHighlight(cornerRadius: 6)
        .help(canFire ? fireButtonHelp : noFireHelp)
    }

    private var fireButtonHelp: LocalizedStringKey {
        switch fireMode {
        case .countdown:
            return LocalizedStringKey("Start the 2-second countdown then push GPS to A")
        case .instant:
            return LocalizedStringKey("Fire set + clear immediately (LocWarp-style)")
        }
    }

    private var noFireHelp: LocalizedStringKey {
        LocalizedStringKey("Set A coordinate and connect an iPhone first")
    }

    // MARK: - Actions

    private var parsedA: Coordinate? {
        MapSearchBar.parseCoordinate(aCoordRaw)
    }

    private var canFire: Bool {
        guard parsedA != nil else { return false }
        guard let udid = state.selectedUDID,
              udid != AppState.virtualMapUDID else { return false }
        guard state.devices.first(where: { $0.udid == udid })?.connected == true
        else { return false }
        return true
    }

    private func useCurrent() {
        if let sim = state.simulatedLocation {
            aCoordRaw = String(format: "%.6f, %.6f", sim.lat, sim.lng)
        } else if let mac = state.macLocation.coordinate {
            aCoordRaw = String(format: "%.6f, %.6f", mac.latitude, mac.longitude)
        }
    }

    private func paste() {
        if let s = NSPasteboard.general.string(forType: .string),
           !s.isEmpty {
            aCoordRaw = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func startCountdown() {
        guard let coord = parsedA, canFire,
              let udid = state.selectedUDID else { return }
        // If a previous "swipe now" banner is still up, hide it
        // before starting the new countdown so the user doesn't
        // see two states layered on top of each other.
        showSwipeNowBanner = false
        running = true
        secondsRemaining = Self.countdownSeconds
        status = String(
            localized: "Counting down…",
            comment: "GoldDittoPanel — status shown while the countdown is running",
        )
        countdownTask = Task { @MainActor in
            // Beep on each tick so the user can keep eyes on the
            // phone and hear when zero is approaching. Last tick
            // gets a higher-pitched system sound to signal "now".
            while secondsRemaining > 0 {
                NSSound.beep()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                secondsRemaining -= 1
            }
            // Zero — fire the RPC, flash the big green banner,
            // and ring the success sound. The banner stays up for
            // ~5 seconds — long enough for the user to look at
            // the phone, swipe, and come back to see it; short
            // enough that it doesn't linger and confuse the next
            // pull attempt.
            NSSound(named: "Glass")?.play()
            await state.pullGoldDitto(udid: udid, lat: coord.lat, lng: coord.lng)
            withAnimation(.easeOut(duration: 0.2)) {
                showSwipeNowBanner = true
            }
            status = ""
            running = false
            countdownTask = nil
            // Auto-dismiss the banner after a comfortable read
            // window. If the user fires another pull before then,
            // `startCountdown` will hide it via animation below.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.easeIn(duration: 0.3)) {
                    showSwipeNowBanner = false
                }
            }
        }
    }

    /// LocWarp-parity firing path — no countdown, no beeps, just
    /// fires set + clear the moment the user clicks. The user is
    /// expected to time the "wait 2 seconds after the swipe-down
    /// UI" rule themselves. We still show the green "swipe NOW"
    /// banner + Glass sound so the user has a clear confirmation
    /// the round-trip happened.
    private func fireInstant() {
        guard let coord = parsedA, canFire,
              let udid = state.selectedUDID else { return }
        showSwipeNowBanner = false  // hide a stale banner if any
        Task { @MainActor in
            NSSound(named: "Glass")?.play()
            await state.pullGoldDitto(udid: udid, lat: coord.lat, lng: coord.lng)
            withAnimation(.easeOut(duration: 0.2)) {
                showSwipeNowBanner = true
            }
            status = ""
            // Auto-dismiss the banner after a comfortable read
            // window. Identical to the countdown path's tail
            // behaviour so the two modes feel consistent post-fire.
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.easeIn(duration: 0.3)) {
                showSwipeNowBanner = false
            }
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        running = false
        secondsRemaining = 0
        status = String(
            localized: "Cancelled.",
            comment: "GoldDittoPanel — status after the user cancels the countdown",
        )
    }
}
