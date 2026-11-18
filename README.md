# PT Wiregram

A macOS app that draws a live wiring diagram ("wiregram") of a Pro Tools session:
tracks, auxes, busses, sends, inserts, groups and VCAs, laid out as a signal-flow graph.

It reads the session through two channels:

- **PTSL** (Pro Tools Scripting Library) — a small dependency-free gRPC client on
  `localhost:31416` for the track list, session name, selection and show/hide.
- **Accessibility API** — reads routing (inputs, outputs, sends, inserts) and I/O setup
  from the Pro Tools mix window.

## Download

Get `PT Wiregram.zip` from the [latest release](https://github.com/fvrijhof/PT-Wiregram/releases/latest),
unzip it and move `PT Wiregram.app` to your Applications folder. It runs natively on Apple
silicon and Intel Macs.

**First launch:** the app is not notarized by Apple, so macOS will block it the first time.
Right-click the app and choose **Open**, then confirm. Or open it once, then go to
System Settings → Privacy & Security and click **Open Anyway**.

Then give PT Wiregram Accessibility access (see below) and make sure Pro Tools is running
with a session open.

## Requirements

- macOS 13 or later
- Pro Tools with PTSL enabled
- Accessibility permission for PT Wiregram (System Settings → Privacy & Security → Accessibility)
- To build: Xcode Command Line Tools (`xcode-select --install`); full Xcode is not needed

## Build from source

```bash
./build.sh
```

This builds a universal (arm64 + x86_64) binary and packages it as `PT Wiregram.app`,
ad-hoc signed.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/Wiregram/WiregramApp.swift` | App entry point and diagnostic CLI flags |
| `Sources/Wiregram/Model.swift` | Session model and graph layout |
| `Sources/Wiregram/Views.swift` | SwiftUI views |
| `Sources/Wiregram/PTSLClient.swift` | Minimal PTSL (gRPC over HTTP/2) client |
| `Sources/Wiregram/ProToolsAX.swift` | Accessibility-based routing reader |
| `tools/make_icon.swift` | Generates the app icon |

## Diagnostics

The binary accepts a few flags for debugging, for example:

```bash
"PT Wiregram.app/Contents/MacOS/Wiregram" --dump-ax ax-tree.txt
"PT Wiregram.app/Contents/MacOS/Wiregram" --routing-test routing.txt
```

Pro Tools is a trademark of Avid Technology. This project is not affiliated with Avid.
