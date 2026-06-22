# chuan

A macOS menu-bar input-source switcher with user-defined global shortcuts.

## Features

- Lives in the menu bar — no Dock icon.
- Assign a global keyboard shortcut to each keyboard input source.
- Press a shortcut from anywhere to switch to that input source.

## Requirements

- macOS 13 or later, Apple Silicon (native `arm64`).
- A Swift toolchain (Xcode Command Line Tools are enough).

## Build

```bash
./build.sh            # builds Chuan.app in this directory
./build.sh --install  # also installs it to /Applications
```

The build produces a self-contained, ad-hoc-signed `Chuan.app`.

## Notes

Switching is performed with the system Text Input Source API
(`TISSelectInputSource`). Some complex (CJKV) input methods have a
long-standing platform quirk where programmatic selection is unreliable; this
is a macOS limitation, not specific to this app.

## License

MIT
