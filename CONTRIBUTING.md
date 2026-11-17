# Contributing to Keepresso

Issues and pull requests are welcome. Bug reports, fixes, new triggers,
translations, and docs all help.

## Before you start

- For a bug, open an issue with your macOS version, Mac model, Keepresso
  version, and the steps to reproduce it.
- For a larger feature, open an issue first so we can agree on the shape before
  you spend time on it.
- Security issues can go through normal issues and pull requests too. See
  [SECURITY.md](SECURITY.md).

## Building

See [docs/BUILDING.md](docs/BUILDING.md). In short: full Xcode 26 or later,
`brew install xcodegen`, then `xcodegen generate` and open the project.

[AGENTS.md](AGENTS.md) describes the architecture, where things live, and the
conventions. It is written for coding agents but reads fine for humans.

## Making a change

- New behavior goes in `Sources/KeepressoCore` behind a protocol seam when it
  touches the system, with tests in `Tests/KeepressoCoreTests`. The SwiftUI app
  stays a thin layer on top.
- Keep the App Sandbox off (`ENABLE_APP_SANDBOX: false`). The power APIs the app
  depends on do not work inside it.
- Never commit the generated `Keepresso.xcodeproj`.
- UI strings live in the Python catalogs under `tools/localization/`. Do not
  hand-edit the `.strings` files. If you can't translate a new string into every
  language, say so in the pull request and we will fill in the rest.

## Checks

Run these before you open a pull request. CI runs the same ones.

```sh
swift test
python3 tools/localization/check_all.py
bash scripts/check-versions.sh
python3 scripts/check-location-permission.py
```

## Style

- Plain, short sentences in UI copy, comments, and docs. No em dashes.
- Clean, restrained UI: system fonts, SF Symbols, no decorative animation.
- Commit messages describe the change in the imperative ("Fix fan control on
  M5 Macs"), one topic per commit.

## License

Keepresso is licensed under the [GNU GPL v3.0](LICENSE). By contributing, you
agree that your contribution is released under the same license. There is no
CLA.

The GPL covers the code, not the name. Forks and derivative apps must use their
own name, see [TRADEMARK.md](TRADEMARK.md).
