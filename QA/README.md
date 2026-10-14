# Synthetic UI QA

Run every command from the repository root. `create-fixture.py` creates 75
synthetic clipboard rows by default: text, RTF, HTML, generated PNG, temporary
file/folder paths, two pinned items, remote provenance, long hover text, CJK
truncation, and pagination. It never reads the user's history or clipboard.

```sh
fixture_root="/private/tmp/clipecho-ui-qa-$(uuidgen)"
python3 QA/create-fixture.py --directory "$fixture_root"
./scripts/build-app.sh release
python3 QA/package-app.py "$fixture_root"
open -n "$fixture_root/runtime/ClipEcho QA.app"
```

The fixture directory must be a new absolute path. The script prints its path
and both database locations. `original/clipecho.db` and `native/clipecho.db` are
initially byte-identical, independent copies. The `original` copy remains
available for a separate comparison with the
[Rust reference](https://github.com/vdpw/ClipEcho-rust); the Swift app uses the
`native` copy. This repository contains only Swift QA packaging tools.

`package-app.py` copies `build/ClipEcho.app` into the fixture's `runtime` folder,
sets the display name to `ClipEcho QA` and a separate bundle identifier, embeds
`CLIPECHO_NATIVE_QA_DATABASE`, and signs the copy ad-hoc. Finder or UI automation
relaunches continue using the synthetic database, named pasteboard, and QA
instance lock. Exit the previous QA app before replacing its bundle.

The direct executable alternative is:

```sh
"build/ClipEcho.app/Contents/MacOS/ClipEcho" \
  --qa --database "$fixture_root/native/clipecho.db"
```

`--qa` requires an explicit database. Only QA mode attaches the real status menu
under `View > QA：菜单栏` for accessible menu inspection and keyboard navigation.
Its position differs from the system status-bar popup; verify final hover-panel
placement through the status-bar icon separately.

Use typed synthetic search text, never production clipboard contents. Do not
operate installed production apps for comparisons. A Rust-side comparison also
requires its own storage and named-pasteboard isolation; pointing it at the
`original` database alone does not isolate the system clipboard.

Check history cards, inline expansion, search/focus, pagination, pin/restore/delete
flows, menus, settings, languages, themes, and window dimensions. The established
product contract is recorded in [UI parity](../docs/history-ui-parity.md); record
actual results and remaining manual items in
[validation](../docs/validation.md), including the date and fixture used.

Core tests and `--self-test` are described in
[development](../docs/development.md). Login startup, another device's Universal
Clipboard, and native menu hover appearance require separate desktop validation.
