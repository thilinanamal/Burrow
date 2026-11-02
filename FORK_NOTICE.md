# Fork notice

This repository is a modified fork of [Mole](https://github.com/tw93/Mole)
by tw93 and contributors, distributed under the GNU General Public License
v3.0. The original copyright and license notices are kept unchanged in
[LICENSE](LICENSE).

## Changes from upstream

- **2026-11-02 to 2026-11-03**: added `app/`, a native SwiftUI macOS app
  called **Burrow**. It is a graphical wrapper that runs the bundled Mole CLI
  scripts; it does not reimplement them. It adds:
  - a window for clean, uninstall, optimize, analyze and status;
  - its own grouping and recommended-selection rules for the clean preview;
  - an extra, evidence-based leftover search for app removal;
  - a build script that packages an ad-hoc signed `.app` and `.dmg`.
- Files outside `app/` and this notice are unmodified upstream code.

## License

The whole repository, including `app/`, is licensed under GPL-3.0. Anyone
who receives a built copy of Burrow is entitled to this complete source code.

## Name and trademark

"Mole" and the Mole logo are trademarks of the Mole project (see
[TRADEMARK.md](TRADEMARK.md)). This fork uses its own name, Burrow, and its own
icon, and it is not affiliated with or endorsed by Mole or Mole for Mac.
