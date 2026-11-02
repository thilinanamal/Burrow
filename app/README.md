# Burrow

A native macOS window for the open-source [Mole CLI](https://github.com/tw93/Mole).
Burrow does not reimplement any cleanup logic. Every scan, cleanup, uninstall,
optimization, disk analysis and health reading runs the same `mole` scripts the
terminal uses, which ship inside the app at `Burrow.app/Contents/Resources/mole`.

Burrow is an independent wrapper. It is not affiliated with or endorsed by the
Mole project, and uses its own name and icon per Mole's `TRADEMARK.md`.

## Build

Requirements: macOS 14+, Xcode command line tools (Swift 5.10+), Go (for Mole's
`analyze`/`status` helpers).

```bash
app/scripts/build.sh            # -> app/dist/Burrow.app and app/dist/Burrow-1.0.0.dmg
app/scripts/build.sh --no-dmg   # app only
BURROW_VERSION=1.1.0 app/scripts/build.sh
```

The app is ad-hoc signed (no Apple Developer account). On first launch macOS
blocks it: open **System Settings > Privacy & Security** and click
**Open Anyway** once.

Development run against the checkout's CLI:

```bash
cd app && swift build
BURROW_MOLE_PATH="$PWD/../mole" .build/debug/Burrow
```

`BURROW_TAB=clean|apps|optimize|analyze|status` picks the start tab;
`BURROW_AUTOSCAN=1` starts a read-only clean preview on launch (for QA).

## How each tab maps to the CLI

| Tab | CLI surface |
|---|---|
| Clean | `mo clean --dry-run` + `~/.config/mole/clean-list.txt` for the review; `mo clean` in a pseudo-terminal for the run |
| Apps > Uninstall | `mo uninstall --list`, `mo uninstall --dry-run <name>` for the plan, `mo uninstall [--with-data] <names>` in a pseudo-terminal |
| Apps > Updates | `brew outdated --json=v2`, `brew upgrade` (Mole does not update apps) |
| Apps > Startup | launchd plists + `launchctl enable/disable` (Mole has no startup manager) |
| Optimize | `mo optimize --dry-run` for the task list, `mo optimize` in a pseudo-terminal |
| Analyze | `mo analyze --json [path]`; Move to Trash uses Finder's Trash |
| Status | `mo status --watch --interval 2s` (NDJSON) |

### Why a pseudo-terminal

Mole only accepts confirmations and sudo passwords from a real terminal. When
you press Remove / Permanently clean / Optimize, Burrow runs the CLI under a
PTY and answers its Enter prompt for you, because you already reviewed the plan
in the window. When the CLI asks for an administrator password, Burrow shows a
native sheet and writes the password only to the CLI's sudo prompt; it is never
stored.

### Deselecting items in Clean

The CLI cleans whole categories. To skip items you unchecked, Burrow adds them
to a clearly marked temporary block in `~/.config/mole/whitelist` for the run
and removes the block when the run ends (and again at every launch, in case the
app was killed). The shield button adds a path to the whitelist permanently,
the same as `mo clean --whitelist`. If the file did not exist, Burrow creates it
with Mole's default protections so nothing loses protection.

## License

The bundled Mole CLI is GPL-3.0; its license is included in the app at
`Contents/Resources/mole/LICENSE`, and its full source is the scripts shipped
there plus https://github.com/tw93/Mole.
