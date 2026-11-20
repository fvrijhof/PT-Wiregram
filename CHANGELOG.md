# Changelog

## 1.2

### Follows Pro Tools
- **Match Pro Tools** (on at launch): folders are open or closed and tracks are hidden exactly as in Pro Tools. Turn it off, or open a folder in PT Wiregram, to read the whole session (after one notice).
- **Closed folders** are shown as one block, as in Pro Tools. Click ⊕ to open it in PT Wiregram.
- Tracks inside closed folders are now read as well.

### Colours
- **Bus colours from I/O Setup:** a bus that has a colour in Pro Tools' I/O Setup draws its lines in that colour. Choose between track colours and bus colours in Settings. PT Wiregram reads the colours from Pro Tools' saved I/O settings, so no extra permission is needed. Changes show up after you click OK in I/O Setup.

### Settings (⌘,)
- **General:** appearance, Match Pro Tools at launch, notices before reading, automatic updates.
- **Graph:** track or bus colours, grey for buses without a colour, pre-fader send marks, stripe or whole-block track colour, zoom when opening, and whether bus columns are counted from the outputs or from the sources.
- **Pro Tools:** how often PT Wiregram refreshes, from every second to every 30 minutes, or only when you click Rescan. A longer interval keeps Pro Tools lighter in large sessions. Also: stop playback before reading, and read hidden tracks when a session opens.
- **Export and import settings** as a file, e.g. to set up every Mac in a studio the same way.
- Settings fixed by an organisation with a configuration profile (e.g. Jamf) are shown as locked.

### Developer mode
- Switch it on in Settings → Developer. A **Developer** menu appears with demo sessions that work without Pro Tools, read-only diagnostic exports for bug reports, version and status info, and the command-line options.
- The Help menu now links to the project on GitHub and to issue reporting.

### Views
- **View bar** with toggle buttons for all view settings (View → Show View Bar).
- **Pre Sends** and **Post Sends** can be shown or hidden separately.
- **Activity bar** at the top shows what PT Wiregram is reading and the result, and hides itself.

### Layout
- **Buses sit next to their sources.** A bus fed by a single folder or a single send was sometimes placed far away, near where its signal goes next. Lines that run together no longer push blocks out of place.
- **Dragged blocks move with their sources** when folders open or close. Positions dragged in 1.1 are reset once.

### Compatibility
- Prepared for newer Pro Tools versions that use new names in the scripting interface (PTSL).

### Diagnostics
- New read-only command-line flags `--folder-diag`, `--transport` and `--pio-colors`.

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
