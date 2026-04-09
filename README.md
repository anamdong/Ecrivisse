# Écrivisse

Écrivisse is a native macOS Markdown/plain-text editor with live preview, multi-window + tab workflows, and a minimal writing UI.

## Version

- Beta 1.5

## Highlights

- Transparent titlebar style with standard macOS traffic-light window controls
- Light/Dark mode toggle, shared across newly opened tabs/windows
- Plain-text editor (monospaced) with customizable cursor color
- Live Markdown preview in a split pane (same window, right side)
- Preview toggle button (top-right) and folder toggle button (top-left)
- Two-finger horizontal swipe to show/hide preview
- Preview follows editing position; clicking preview text navigates editor to source
- Interactive task-list checkboxes in preview that sync back to Markdown source
- Floating formatting menu (top or bottom): headings, emphasis, lists, checklist, links, code, quote, footnote, TOC, tables
- File sidebar: import folders, browse files, open/open in new tab/open in new window, rename, delete
- Imported folders persist across app launches and auto-refresh
- Live word/character count at bottom bar
- Bottom utility controls (`-`, `+`, Light/Dark, Settings) are icon/label driven without hover pop-up captions
- Export/Print from rendered preview (`PDF`, `HTML`, `DOCX` when supported)
- AI actions:
  - Selection context menu: **Summarize using AI**
  - Command menu: **Summarize Current Document** (appends `#ai summary`)

## Markdown/Preview Support

- Headings, bold/italic/bold-italic, strikethrough
- Ordered/unordered/check lists
- Links, images, blockquotes
- Inline code + fenced code blocks (syntax highlighted)
- Tables
- Footnotes
- Inline/block math
- `{{TOC}}` token for generated table of contents

## Supported File Types

Open/import supports common text formats including:

- `.md`, `.markdown`, `.txt`, `.text`, `.rtf`
- `.html`, `.htm`, `.xml`, `.json`
- `.csv`, `.tsv`, `.log`, `.yaml`, `.yml`

## Keyboard Shortcuts

- `Cmd+N`: New window
- `Cmd+T`: New tab
- `Cmd+Shift+N`: New empty document (current tab/window)
- `Cmd+O`: Open document
- `Cmd+W`: Close window/tab (with save prompt when dirty)
- `Cmd+S`: Save
- `Cmd+Shift+S`: Save As
- `Cmd+P`: Print rendered preview
- `Cmd+B`: Wrap selection with `**...**`
- `Cmd+I`: Wrap selection with `*...*`
- `Cmd+Shift+P`: Toggle preview pane
- `Cmd+Shift+F`: Cycle focus mode
- `Ctrl+Cmd+1`: Sentence focus
- `Ctrl+Cmd+2`: Paragraph focus
- `Ctrl+Cmd+0`: Focus off
- `Cmd+Shift+E`: Export PDF
- `Cmd+Shift+H`: Export HTML
- `Cmd+Shift+D`: Export DOCX (if available)
- `Cmd+Shift+M`: Summarize current document using AI

## Run

```bash
swift build
swift run Ecrivisse
```

You can also open `Package.swift` in Xcode and run the `Ecrivisse` executable target.

## Build App Bundle

```bash
./scripts/package_app.sh debug
```

or

```bash
./scripts/package_app.sh release
```

Output app bundle:

`dist/Écrivisse.app`
