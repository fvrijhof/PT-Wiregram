# PT Wiregram

A macOS app that draws a live wiring diagram ("wiregram") of a Pro Tools session:
tracks, auxes, busses, sends, inserts, groups and VCAs, laid out as a signal-flow graph.

It reads the session through two channels:

- **PTSL** (Pro Tools Scripting Library) — a small dependency-free gRPC client on
  `localhost:31416` for the track list, session name, selection and show/hide.
- **Accessibility API** — reads routing (inputs, outputs, sends, inserts) and I/O setup
  from the Pro Tools mix window.

## Download

Get `PT.Wiregram.zip` from the [latest release](https://github.com/fvrijhof/PT-Wiregram/releases/latest),
unzip it and move `PT Wiregram.app` to your Applications folder. It runs natively on Apple
silicon and Intel Macs.

**First launch:** the app is not notarized by Apple, so macOS will block it the first time.
Right-click the app and choose **Open**, then confirm. Or open it once, then go to
System Settings → Privacy & Security and click **Open Anyway**.

Then give PT Wiregram Accessibility access (see below) and make sure Pro Tools is running
with a session open.

## Features

- Signal-flow graph of tracks, auxes, busses, sends and output paths, with VCA and table views
- Rails that combine lines going to the same place, so even busy sessions stay readable
- Collapse tracks (identical routing, folder or group), a minimap and a hand tool for large sessions
- Focus view: right-click a block to see only its routing
- Reads groups, hidden tracks and the I/O Setup on request. It asks first, stops playback,
  and changes nothing in the session.
- Optional automatic updates from the GitHub releases

See [CHANGELOG.md](CHANGELOG.md) for what's new.

## Updating

From version 1.1 on, PT Wiregram can update itself. On first launch it asks whether to do this
automatically. You can change that later, or run **Check for Updates…**, from the PT Wiregram menu.
Version 1.0 has no updater: install 1.1 once by hand.

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
| `Sources/Wiregram/Updater.swift` | Automatic updates from GitHub releases |
| `Sources/Wiregram/Demo.swift` | Synthetic session for testing without Pro Tools |
| `tools/make_icon.swift` | Generates the app icon |

## Diagnostics

The binary accepts a few flags for debugging, for example:

```bash
"PT Wiregram.app/Contents/MacOS/Wiregram" --dump-ax ax-tree.txt
"PT Wiregram.app/Contents/MacOS/Wiregram" --routing-test routing.txt
"PT Wiregram.app/Contents/MacOS/Wiregram" --transport
"PT Wiregram.app/Contents/MacOS/Wiregram" --demo demo.png --tracks 60
```

`--demo` renders a synthetic session to a PNG without Pro Tools; `--demo-ui` runs the app on it.

Pro Tools is a trademark of Avid Technology. This project is not affiliated with Avid.

## License

MIT — see [LICENSE](LICENSE).
