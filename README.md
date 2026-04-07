# Écrivisse

Écrivisse is a native macOS writing app focused on distraction-free drafting with plain text and Markdown.

## What It Includes

- Minimal writing environment with transparent titlebar and standard macOS window controls
- Plain-text Markdown editor as the primary mode
- Live Markdown preview as a right-side split panel
- Preview toggle button in the top-right corner
- Focus mode: `Off`, `Current Sentence`, `Current Paragraph`
- Subtle real-time part-of-speech highlighting for nouns, verbs, adjectives
- Desaturated red insertion cursor
- Live word/character count at the bottom bar
- Single-document session model (New / Open / Save / Save As)
- Export to `PDF`, `HTML`, and `DOCX` (if supported by current macOS APIs)

## Keyboard Shortcuts

- `Cmd+N`: New window
- `Cmd+Shift+N`: New empty document (current window)
- `Cmd+O`: Open document
- `Cmd+S`: Save
- `Cmd+Shift+S`: Save As
- `Cmd+Shift+P`: Toggle right-side preview panel
- `Cmd+Shift+F`: Cycle focus mode
- `Ctrl+Cmd+1`: Sentence focus
- `Ctrl+Cmd+2`: Paragraph focus
- `Ctrl+Cmd+0`: Focus off
- `Cmd+Shift+E`: Export PDF
- `Cmd+Shift+H`: Export HTML
- `Cmd+Shift+D`: Export DOCX

## Run

```bash
swift build
swift run Ecrivisse
```

You can also open `Package.swift` in Xcode and run the `Ecrivisse` executable target.

If `swift build` fails due local SDK/toolchain mismatch, switch to a matching Xcode/CLT install before building.

## Build Double-Clickable App

```bash
./scripts/package_app.sh debug
```

or

```bash
./scripts/package_app.sh release
```

The app bundle is created at:

`dist/Écrivisse.app`
