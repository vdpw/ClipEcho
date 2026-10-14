# AGENTS.md

ClipEcho is a native Swift 6.4.1 + AppKit clipboard manager for macOS 14+.
The Swift package, resources, tests, scripts, and QA tools live at the repository
root. The Rust/Tauri/React reference is archived read-only in
[ClipEcho-rust](https://github.com/vdpw/ClipEcho-rust).

## Documentation Menu

Start with `README.md` and `docs/index.md`, then load only the relevant guide:

- Layer boundaries or concurrency: `docs/architecture.md`.
- Build, toolchain selection, checks, and manual QA: `docs/development.md`.
- GitHub Actions, tags, and packaged builds: `docs/release.md`.
- Product UI compatibility: `docs/history-ui-parity.md`.
- Synthetic fixtures and isolated UI captures: `QA/README.md`.
- Historical evidence and outstanding manual checks: `docs/validation.md`.

## Architecture And Compatibility

- `Sources/ClipEchoCore/Domain` defines models and persistence ports; it must not import AppKit or CSQLite.
- `Sources/ClipEchoCore/Application` implements use cases against `HistoryStorage`, without constructing SQLite adapters.
- `Sources/ClipEchoCore/Persistence` owns SQLite, schema compatibility, filesystem safety, and relocation.
- `Sources/ClipEchoCore/Clipboard` owns pure encoding/classification; `Export` owns the optional mirror.
- `Sources/ClipEcho/System` contains macOS adapters; `Presentation` contains AppKit views.
- Confine NSPasteboard/UI to the main actor, and disk/hash/codec work to service actors.
- Preserve the existing v4 schema, CSB1 binary format, setting keys, pins, and content identity.
- Tests use synthetic temporary databases and unique named pasteboards. Never commit user history or clipboard bodies.
- The original product UI and interactions are the compatibility contract. Reorganizing architecture does not authorize redesigning the product. Use the archived styles, views, labels, and menu linked from `docs/history-ui-parity.md`; preserve cards, inline expansion, dimensions, keyboard behavior, scroll rules, and confirmations.

## Verification

- Validate visible UI with isolated synthetic fixtures and `--qa --database /absolute/fixture/clipecho.db`. Never use production clipboard content in screenshots or accessibility captures.
- Run `./scripts/test.sh`, `./scripts/build-app.sh release`, and `./scripts/self-test.sh` after relevant changes. The wrapper requires the final `Native self-test passed:` marker as well as a successful executable exit. Verify the bundle with `codesign --verify --deep --strict build/ClipEcho.app`.
- Use `build/ClipEcho.app/Contents/MacOS/ClipEcho --verify-database` for read-only compatibility checks against existing history.
- Native screenshots and actual login/Universal Clipboard verification remain separate from unit tests.
- Never commit `.build/`, `.swiftpm/`, `build/`, user history, or clipboard bodies.
