# Changelog

## 1.1

### Large sessions
- **Collapse Tracks** (View menu): show tracks with identical routing, a whole folder or a whole group as one stacked block. Click ⊕ to open a block, ⊖ to close it again.
- **Minimap** in the bottom-right corner. Drag the blue frame to move through the whole graph.
- **Hand tool** for panning. You can also drag an empty spot, hold Space while dragging, or use the middle mouse button.

### Clearer lines
- **Rails:** lines from neighbouring blocks that go to the same place are combined automatically. Each group gets one rail per destination, in a fixed order: send A, B, C… and the output last. A dot means "connected". This also works on the bus levels.
- **Single blocks** get one line with the slot names above it. Sends hang below it, each with a dot, and Out continues the line itself.
- **Hover or select** a block and the rails stay in place. Only the parts that carry its signal light up.
- **Send Lines** setting: all, only for the selected track, or hidden.
- **Show Bus Names** (optional) on the lines.
- **Smarter layout:** blocks are placed near their sources and keep out of the way of lines that pass by.

### Views
- **Focus view** (right-click a block) now draws and highlights like the full view. Right-click another block there to focus on its routing. Right-click an empty spot or press Esc to go back.
- **Track Color:** a color stripe or a fully colored block.
- **Legend** can be switched off.
- **Reset Block Positions** button appears as soon as you have dragged a block.
- **VCA view:** scrolling back up with the scroll wheel works again.

### Reading from Pro Tools
- **Notice before reading:** before PT Wiregram briefly controls Pro Tools to read groups, hidden tracks or the I/O Setup, it explains what it will do. Nothing is changed, but saving first is recommended. You can tell it not to ask again until the app quits.
- **Playback is stopped** before reading. A running recording is never touched.
- **Missing data:** a notice appears when a function needs data that hasn't been read from the session yet, with a **Read Now** button.

### Updates
- **Automatic updates:** on first launch PT Wiregram asks whether to keep itself up to date. When this is on, it checks GitHub once a day, downloads a new version in the background and installs it when you quit. Use **Relaunch to Update** to install it right away. **Check for Updates…** is in the PT Wiregram menu.

### Other
- The app is now fully in English.
- **Accessibility permission:** it now stays valid after an update. Use **Reset Permission** and **Relaunch** in the banner if macOS keeps asking.

## 1.0

First release.
