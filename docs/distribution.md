# LociiGhost — Distribution Signing & Notarization

How to ship LociiGhost as a Gatekeeper-trusted `.app` that anyone on
macOS 14+ can open by double-click — no `xattr -d com.apple.quarantine`
gymnastics for the recipient.

The build pipeline in [`Scripts/package-app.sh`](../Scripts/package-app.sh)
has three modes, switched purely by environment variables:

| Variables set | Result | Recipient experience |
|---|---|---|
| _(neither)_ | Ad-hoc signing | Local Mac only. Gatekeeper warns "unidentified developer" on every other Mac. |
| `LOCIIGHOST_SIGN_IDENTITY` only | Signed with Developer ID + Hardened Runtime | Other Macs can open after right-click → Open (one-time accept). |
| Both `LOCIIGHOST_SIGN_IDENTITY` + `LOCIIGHOST_NOTARY_PROFILE` | Signed + notarised + stapled | Other Macs open with a clean double-click, no warning. **Distribution-grade.** |


## One-time setup (per dev Mac)

You only need to do this once. After that every release build just
sets two env vars and runs the existing `package-app.sh`.

### 1. Apple Developer Program

You need a paid [Apple Developer Program](https://developer.apple.com/programs/)
membership ($99 USD/year). Individual or organisation, either works.

### 2. Developer ID Application certificate

In **Xcode → Settings → Accounts → (your Apple ID) → Manage
Certificates → ＋ → Developer ID Application**.

That generates a private key + certificate in your login keychain.
Confirm it's there:

```bash
security find-identity -v -p codesigning
```

You should see a line ending in `"Developer ID Application: Your
Name (ABCDEFGHIJ)"`. The `ABCDEFGHIJ` part is your **Team ID** —
copy it; you'll need it below.

### 3. App-specific password for notarytool

Apple's notarisation service needs an Apple-ID + an _app-specific
password_ (not your normal Apple ID password). Generate one at
<https://appleid.apple.com> → Sign-In and Security → App-Specific
Passwords → ＋. Save the 16-character `xxxx-xxxx-xxxx-xxxx` string.

### 4. Store credentials in keychain via notarytool

```bash
xcrun notarytool store-credentials LociiGhost \
    --apple-id you@example.com \
    --team-id  ABCDEFGHIJ \
    --password "xxxx-xxxx-xxxx-xxxx"
```

`LociiGhost` is just a profile name — pick anything memorable; the
build script reads it via `LOCIIGHOST_NOTARY_PROFILE`.

The password is stored encrypted in your login keychain; you only
type it this once.


## Release build

```bash
cd ~/Documents/LociiGhost

export LOCIIGHOST_SIGN_IDENTITY="Developer ID Application: Your Name (ABCDEFGHIJ)"
export LOCIIGHOST_NOTARY_PROFILE="LociiGhost"

CONFIG=release ./Scripts/package-app.sh
```

What this does, end-to-end:

1. **Builds** the Swift app in release configuration.
2. **Bundles** `LociiGhost.app` with the AppIcon, locales, and
   embedded resource bundle.
3. **Signs**, inside-out, with Hardened Runtime + secure timestamp:
   resource bundle → main executable → outer `.app` wrapper. The
   main executable gets the entitlements at
   [`Scripts/LociiGhost.entitlements`](../Scripts/LociiGhost.entitlements)
   (currently just `com.apple.security.automation.apple-events`,
   needed for `osascript` admin prompts).
4. **Verifies** the signature with `codesign --verify --deep --strict`.
5. **Zips** the `.app` with `ditto` (preserves extended attributes
   the way Apple expects).
6. **Submits** to Apple's notary service via `notarytool --wait`.
   Typical turnaround: under a minute, occasionally up to 30 min.
7. **Staples** the resulting notarisation ticket onto the `.app`
   so it works offline (no Gatekeeper round-trip on launch).
8. **Re-verifies** via `spctl --assess` — you should see
   `accepted: source=Notarized Developer ID`.

The output `dist/LociiGhost.app` is ready to drop on a website,
upload to a DMG / Sparkle feed, or hand off via AirDrop. Gatekeeper
on any macOS 14+ Mac will treat it like any commercial app:
double-click opens it without warnings.


## Troubleshooting

### `notarytool submit` rejected

Check `dist/notarytool.log` for the submission UUID, then:

```bash
xcrun notarytool log <UUID> --keychain-profile LociiGhost
```

The log lists every signature / entitlement / library-validation
issue. The two most common:

- **"The signature does not include a secure timestamp."** — Your
  `--timestamp` flag was missing (or Apple's timestamp server was
  unreachable). Re-run the build.
- **"The executable does not have the hardened runtime enabled."**
  — `--options runtime` flag was missing on some nested binary.
  Check `codesign -d --entitlements - --verbose=4 path/to/binary`
  to confirm.

### Gatekeeper still says "unverified developer" after stapling

Run `spctl --assess --type execute --verbose=2 dist/LociiGhost.app`
and look at the `source=` line:

- `Notarized Developer ID` → all good; macOS just hasn't seen this
  exact bundle hash before. First launch will check Apple's servers;
  subsequent launches go straight through.
- `Unnotarized Developer ID` → the staple step failed silently.
  Re-run notarisation.

### Certificate expired / revoked

Developer ID Application certs are valid for 5 years. Renew via
Xcode → Settings → Accounts → Manage Certificates. The keychain
auto-picks the new one as long as the old isn't deleted.
