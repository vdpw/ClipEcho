# ClipEcho Native

This is the independent Swift 6.4 + AppKit implementation. Keep the existing
Tauri/React/Rust project outside this directory intact.

- Read `README.md` for build, launch, compatibility, and validation commands.
- Read `docs/architecture.md` before changing layer boundaries or concurrency.
- `ClipEchoCore/Domain` defines models and persistence ports; it must not import AppKit or CSQLite.
- `ClipEchoCore/Application` implements use cases against `HistoryStorage`, without constructing SQLite adapters.
- `ClipEchoCore/Persistence` owns SQLite, schema compatibility, filesystem safety, and relocation.
- `ClipEchoCore/Clipboard` owns pure encoding/classification; `Export` owns the optional mirror.
- `ClipEcho/System` contains macOS adapters; `Presentation` contains AppKit views.
- Confine NSPasteboard/UI to the main actor, and disk/hash/codec work to service actors.
- Preserve the existing v4 schema, CSB1 binary format, setting keys, pins, and content identity.
- Tests use synthetic temporary databases and unique named pasteboards. Never commit user history or clipboard bodies.
- The original product UI and interactions are the compatibility contract. Reorganizing architecture does not authorize redesigning the product. Use `src/macos.css`, `src/features/history`, `src/features/settings/settings.css`, `src/i18n.ts`, and the Rust native menu as the reference; keep cards, inline expansion, dimensions, labels, keyboard behavior, scroll rules, and confirmation flows consistent.
- Validate visible UI with isolated synthetic fixtures and `--qa --database /absolute/fixture/clipecho.db`. Never use production clipboard content in screenshots or accessibility captures.
- Run `./scripts/test.sh`, `./scripts/build-app.sh release`, and the built executable's `--self-test` after relevant changes.
- Native screenshots and actual login/Universal Clipboard verification remain separate from unit tests.
