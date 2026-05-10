# WiFi tunnel setup

LocWarp talks to paired iPhones over WiFi using the same path Xcode
does — Bonjour mDNS discovery → RemotePairing tunnel → RSD. There is
no "Sync this iPhone over Wi-Fi" toggle to flip; iOS 17+ advertises the
`_remotepairing._tcp` service automatically once the iPhone is paired
and Developer Mode is on.

## One-time setup

1. Plug the iPhone into the Mac with a USB cable.
2. Tap **Trust this Computer** when prompted (iOS asks for the device
   passcode).
3. Connect the device once in LocWarp — that confirms the pairing
   record was written to `~/.pymobiledevice3`.
4. Make sure Developer Mode is on (Settings → Privacy & Security →
   Developer Mode). LocWarp's sidebar can flip the toggle for you with
   the **Enable Developer Mode...** button.

## Day-to-day flow

1. Open LocWarp. The daemon does a 2-second Bonjour browse on the
   first device list refresh.
2. Each iPhone appears as one row in the sidebar with capsule badges:
   - `USB` — currently plugged in over USB.
   - `WiFi` — `_remotepairing._tcp` is being advertised on the network.
   - `USB WiFi` — both transports available; you can choose.
3. Click **Connect**.
   - When only one transport is available, the button just connects.
   - When both are available, it becomes a small menu —
     **Connect via USB** / **Connect via WiFi** — pick whichever you
     want for this session.
4. Once connected, the active transport's badge turns green. You can
   unplug USB now and walk around with the iPhone; the simulation
   keeps running over the WiFi tunnel as long as the device stays on
   the same network and isn't put to sleep.

The daemon caches Bonjour discovery results for ~15 seconds to avoid
re-browsing on every UI refresh. Hit the sidebar's circular Refresh
arrow to force a fresh discovery if you've just brought a new device
onto the network.

## Limits & gotchas

- **Pairing required.** A factory-fresh iPhone won't be discoverable
  on WiFi until it's been trusted via USB at least once. The Mac's
  pairing record under `~/.pymobiledevice3` is what unlocks the WiFi
  side.
- **Lock screen kills the tunnel.** When the iPhone screen locks for
  long enough, iOS suspends the network stack and the RemotePairing
  tunnel drops. Wake the phone and reconnect.
- **Same network, no client isolation.** Most home Wi-Fi works fine.
  Public networks (cafés, hotels) often block peer-to-peer traffic and
  Bonjour, and will fail silently. Personal hotspot from the Mac to
  the iPhone (or vice versa) is the most reliable fallback.
- **iOS 17+ still needs admin.** The WiFi tunnel uses the same utun
  interface the USB tunnel does, so the daemon still has to run as
  root. The app's Authenticate banner handles this for you.
- **Switching transport.** LocWarp doesn't migrate an in-flight
  session from USB to WiFi (or vice versa). To switch, Disconnect the
  device, then Connect again with the transport you want.

## Troubleshooting

If the WiFi badge never appears:

1. Confirm the iPhone is on the same Wi-Fi as the Mac (not on cellular,
   not on a different VLAN).
2. Confirm Developer Mode is on. Without it, iOS doesn't broadcast
   `_remotepairing._tcp`.
3. Confirm the pairing record exists by running this in Terminal:
   ```
   ls ~/.pymobiledevice3 | grep -i remote_pairing
   ```
   You should see one file per paired UDID.
4. Wait ~15s after opening the app, or hit the sidebar Refresh, to
   give the Bonjour browse a chance to complete.
