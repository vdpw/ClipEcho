# Synthetic original/native comparison

`create-fixture.py` creates 75 accepted synthetic clipboard rows, including text,
RTF, HTML, a generated PNG, existing temporary file/folder paths, two pinned
items, remote provenance, long hover text, CJK truncation, and paginated rows.
It never reads or copies the user's history or clipboard. The original and
native databases are byte-identical copies in separate directories.

```sh
python3 native-macos/QA/create-fixture.py
bash native-macos/QA/launch-original.sh /private/tmp/clipecho-ui-qa-<generated-id>
```

The original QA overlay uses a separate application identifier and Vite port 5174. Its runtime-only Objective-C shim replaces `NSPasteboard.generalPasteboard`
with a named QA pasteboard. It activates only for the `clip_echo` process with
both QA environment guards. Original source files remain unchanged.

For a uniquely named bundle suitable for selecting in UI automation, first
compile with the preceding launch command, stop only that QA process, and run:

```sh
python3 native-macos/QA/package-original.py /private/tmp/clipecho-ui-qa-<generated-id>
pnpm dev --port 5174 --strictPort
open -n '/private/tmp/clipecho-ui-qa-<generated-id>/runtime/ClipEcho Original QA.app'
```

The bundle embeds the fixture path and pasteboard shim in `LSEnvironment`, so
relaunching the bundle also selects synthetic storage and the named pasteboard.
`runtime/shim-active-<pid>` confirms the redirection was installed. Its display
name is `ClipEcho Original QA`; select the explicit bundle path in automation.

After building native, stop the previous Native QA instance before replacing its
bundle, then package and open the isolated counterpart:

```sh
python3 native-macos/QA/package-native.py /private/tmp/clipecho-ui-qa-<generated-id>
open -n '/private/tmp/clipecho-ui-qa-<generated-id>/runtime/ClipEcho Native QA.app'
```

The bundle embeds `CLIPECHO_NATIVE_QA_DATABASE`, so Finder and UI automation
relaunches still use the separate database, named pasteboard, and QA instance lock.
The command-line alternative is `--qa --database /absolute/fixture/native/clipecho.db`.
Only QA mode attaches the same status menu beneath `View > QA：菜单栏` for
accessible menu inspection and keyboard navigation. Normal launches do not
include this test entry. Its position differs from the system status-bar popup;
verify final hover-panel placement through the status-bar icon separately.
Native QA uses its own named pasteboard. Do not
operate the installed production apps for comparisons. Use typed synthetic
search text; do not copy or paste production clipboard contents.
