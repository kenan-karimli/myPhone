# myPhone

**A private, cross-device companion for Android and desktop.** Chat with your own devices, move files and clipboard content between them, view screens remotely, and interact with your Android phone from your computer — over your private Tailscale network.

<p align="center">
  <video src="https://i.imgur.com/BMwoIvc.mp4" controls playsinline width="100%">
    Your browser does not support embedded video.
    <a href="https://i.imgur.com/BMwoIvc.mp4">Watch the myPhone demo</a>
  </video>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#getting-started">Getting started</a> ·
  <a href="#building">Building</a>
</p>

---

## Overview

myPhone connects your Android phone and desktop as trusted devices on your own tailnet. It combines a lightweight messenger with practical remote-device tools, keeping communication and device access within your private network rather than relying on a hosted messaging service.

The application uses one Flutter codebase for Android and desktop interfaces. A small HTTP-based peer protocol handles messaging and device events; dedicated TCP streams carry live screen data.

## Features

### Messaging and file sharing
- Pair devices by their Tailscale hostname.
- Send and receive text messages, images, and files.
- View message delivery state, reply to messages, and react with emoji.
- Share files from the desktop file manager using the **Send via myPhone** Nautilus script.
- Open received files with the host operating system's default application.

### Clipboard
- Optional text clipboard synchronization between paired devices.
- Send clipboard text manually using the Android Quick Settings tile.
- Android clipboard reads follow platform restrictions: automatic phone-to-desktop reads happen when myPhone is in the foreground.

### Device presence and notifications
- See paired devices and their online state.
- Exchange device identity, presence, and battery information.
- Receive notifications for incoming messages and agent events.
- Keep the desktop app available in the system tray.

### Screen sharing and remote control
- Stream a desktop screen to a paired device.
- Choose a screen quality preset.
- View an Android phone's screen on the desktop after granting Android screen-capture permission.
- Control the mirrored phone with mouse and keyboard input, including taps, swipes, scrolling, text entry, Back, Home, and Recents.

### Claude Code integration
- Discover Claude Code sessions and projects running on the desktop.
- Open existing sessions or start a new one from the phone.
- Follow session output and tool activity.
- Review permission requests and allow or deny them from the phone.

### Interface and preferences
- Responsive phone and desktop layouts.
- Light and dark themes, with selectable accent colors.
- Adjustable text scale and reduced-motion preference.
- Configurable download location and device display name.

## Platforms

| Component | Platform |
| --- | --- |
| Mobile app | Android |
| Desktop app | Linux, Windows, macOS (Flutter desktop targets) |
| Desktop screen capture | Linux with `wf-recorder` |
| Clipboard integration | Android and Linux |
| Phone screen mirroring | Android ↔ desktop |
| Claude Code session integration | Desktop with Claude Code installed |

Some integrations are platform-specific. In particular, desktop screen capture currently uses Linux/Wayland tooling, and the Nautilus file-manager integration is Linux-specific.

## Architecture

```text
myPhone/
├── app/
│   ├── lib/                    # Flutter application
│   │   ├── main.dart           # App entry point
│   │   ├── core.dart           # Startup, services, lifecycle
│   │   ├── net.dart             # Peer networking and HTTP protocol
│   │   ├── store.dart           # Devices, messages, settings, persistence
│   │   ├── mirror.dart          # Android screen mirroring host
│   │   ├── screen.dart          # Desktop screen capture and streaming
│   │   ├── agents.dart          # Claude Code session integration
│   │   ├── assistant.dart       # Assistant integration
│   │   ├── clipboard.dart       # Clipboard synchronization
│   │   ├── battery.dart         # Battery state
│   │   ├── desktop.dart         # Desktop window and tray integration
│   │   ├── tokens.dart          # Theme and design tokens
│   │   └── ui/                  # Responsive screens and widgets
│   ├── android/                # Android host and native services
│   ├── linux/                  # Linux desktop runner
│   ├── windows/                # Windows desktop runner
│   ├── macos/                  # macOS desktop runner
│   ├── packages/
│   │   └── phone_native/       # Android-specific Flutter method channel
│   └── pubspec.yaml
├── design/                     # Mobile and desktop design handoffs
└── README.md
```

### Communication model

- **Peer discovery and messaging:** devices are added using their Tailscale hostname. The app exchanges identity and message events through its peer HTTP service (default port `4747`).
- **Network boundary:** incoming peer connections are restricted to loopback and Tailscale IPv4/IPv6 address ranges.
- **Phone screen mirroring:** a separate TCP stream (default port `4749`) carries framed H.264 video from Android to desktop. The desktop decodes the stream with GStreamer or FFmpeg and sends input events back.
- **Desktop screen sharing:** on supported Linux systems, `wf-recorder` captures the display and myPhone streams JPEG frames to paired devices.
- **Persistence:** settings are stored in JSON and device/chat histories are stored as JSONL files in the application support directory.

## Requirements

Before running myPhone, make sure you have:

- [Flutter](https://flutter.dev/docs/get-started/install) with the required desktop and/or Android toolchains enabled.
- [Dart](https://dart.dev/get-dart) compatible with the SDK constraint in `app/pubspec.yaml`.
- [Tailscale](https://tailscale.com/download) installed and connected on each device you want to pair.
- Android SDK and an Android device/emulator for the mobile target.

Optional tools for platform-specific functionality:

| Tool | Used for |
| --- | --- |
| [GStreamer](https://gstreamer.freedesktop.org/) with H.264 plugins | Low-latency decoding of the phone's mirrored screen on desktop |
| [FFmpeg](https://ffmpeg.org/) | Fallback H.264 decoder for phone screen mirroring |
| `wf-recorder` | Linux desktop screen capture |
| `wl-copy` and `wl-paste` | Linux Wayland clipboard integration |
| `hyprctl` | Detecting the focused monitor on Hyprland |
| `curl` | Nautilus file-manager handoff script |

## Getting started

### 1. Clone the repository

```bash
git clone https://github.com/kenan-karimli/myPhone.git
cd myPhone/app
```

### 2. Install dependencies

```bash
flutter pub get
```

### 3. Check available targets

```bash
flutter doctor
flutter devices
```

### 4. Run the application

For a connected Android device:

```bash
flutter run
```

For Linux desktop:

```bash
flutter run -d linux
```

For other configured Flutter desktop targets, replace `linux` with the target reported by `flutter devices`.

### 5. Pair your devices

1. Install and launch myPhone on both devices.
2. Make sure both devices are connected to the same Tailscale network.
3. Open **Add device** in myPhone.
4. Enter the other device's Tailscale hostname.
5. Confirm the discovered device to add it to your device list.

Keep Tailscale running on both devices for peer communication.

## Building

Run these commands from the `app/` directory.

### Android APK

```bash
flutter build apk --release
```

The APK is generated under:

```text
build/app/outputs/flutter-apk/
```

### Linux desktop

```bash
flutter build linux --release
```

### Windows desktop

```bash
flutter build windows --release
```

### macOS desktop

```bash
flutter build macos --release
```

Release signing and distribution configuration may need to be completed for your target platform.

## Permissions and privacy notes

- myPhone is designed for use between devices on your own Tailscale network; it is not a public messaging service.
- The peer server checks incoming addresses against loopback and Tailscale address ranges.
- Android screen mirroring requires the user to approve Android's screen-capture prompt. Ending the desktop mirror session closes the phone-side stream.
- Android clipboard access is restricted by Android itself. Reading the phone clipboard is only available while the app is in the foreground; the Quick Settings tile provides an explicit manual send action.
- Clipboard synchronization is optional and disabled unless enabled in settings.
- Android may request notification, foreground-service, and other runtime permissions for background operation and notifications.

Only pair devices and enable integrations on systems you own or are authorized to access.

## Development

The Flutter application and its Android-specific native functionality live in `app/`. The `phone_native` package provides a Flutter method channel for Android clipboard operations, the ring action, and the clipboard Quick Settings tile callback.

Useful commands:

```bash
cd app
flutter analyze
flutter test
```

## License

No license file was present in the repository when this README was written. Unless a license is added, the project should be treated as **all rights reserved**; check with the repository owner before reusing or distributing its code.
