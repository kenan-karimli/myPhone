# myPhone

A private messenger between your own devices. Each device is a contact. You can send text, files and emoji reactions,
and the phone gets notifications even when the app is closed. Devices talk directly over Tailscale, so no server is involved.

- `app/`: the Flutter app (Android + Linux from one codebase)
- `design/`: the Claude Design handoff the UI follows

## How it works
- Every device runs a tiny HTTP server on port **4747** and only accepts connections from your tailnet (`100.64.0.0/10`).
  Tailscale picks the fastest path automatically: direct on the same Wi-Fi, peer-to-peer or relayed across the internet.
- Android runs that server in a foreground service ("myPhone online" notification), so messages arrive while the app is closed.
- Messages sent to an offline device wait and are delivered automatically when it comes back.
- Chats are append-only logs in the app's data folder. Received files go to `Downloads/myPhone`.

## Setup
1. **Tailscale** on both devices, logged into the same account:
   - PC: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`
   - Phone: install Tailscale from the Play Store and sign in.
2. **Linux build tools** (one time): `sudo apt install clang`
3. Use Flutter from `~/flutter/bin` (add it to your PATH).
4. Run on the PC: `cd app && flutter run -d linux` (or `flutter build linux --release` → `build/linux/x64/release/bundle/myphone`)
5. Install on the phone (USB debugging on): `cd app && flutter install`, or `adb install build/app/outputs/flutter-apk/app-debug.apk`
6. In the PC app, press **+** and type the phone's Tailscale name (shown in the Tailscale app, e.g. `pixel-8`).
   The phone adds the PC automatically.

## Desktop extras
- Closing the window hides myPhone to the tray; it keeps receiving. Quit from the tray menu.
- Files right-click → **Scripts → Send via myPhone** (Nautilus). The app installs this script itself on start.
- Start at login: an XDG autostart entry is created. On Hyprland add `exec-once = <path>/myphone --hidden` instead.
- Android: **Share → myPhone** from any app sends files, photos or links.

## Develop
- `flutter test`: the protocol test (two devices on localhost: text, 3 MB file, reaction, offline retry) plus screenshot tests.
- `flutter test --update-goldens test/screens_test.dart` renders screens to `test/goldens/*.png`.

## Not done yet
Battery, screen view, remote control, AI assistant, iOS, Windows/macOS builds.
