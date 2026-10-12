# Release Workflow

## Trigger And Native Targets

`.github/workflows/release.yml` runs for pushed `v*` tags.

```bash
git tag v0.1.0
git push origin v0.1.0
```

The matrix builds each target on matching native hardware:

| Target                 | GitHub runner    |
| ---------------------- | ---------------- |
| `aarch64-apple-darwin` | `macos-15`       |
| `x86_64-apple-darwin`  | `macos-15-intel` |

PR CI (also available manually) runs its complete automated verification matrix
on both native runners; branch pushes and PR merges do not trigger it again.
Native compilation and unit tests improve architecture
coverage; they do not replace the manual Apple Silicon/Intel runtime evidence
required below.

## Automated Release Gate

Each release job:

1. checks out the tagged commit, including `src-tauri/Cargo.lock`;
2. installs pnpm 10.33.0, Node LTS, Rust, and the matching target;
3. fetches Rust dependencies with `cargo fetch --locked` for the matching target;
4. installs the frozen pnpm lockfile;
5. runs frontend type-check, lint, and tests;
6. runs `pnpm security-check`;
7. checks Rust formatting and runs Rust tests with `--locked`;
8. invokes `tauri-apps/tauri-action@v0`, whose configured build runs the
   frontend production build and packages the matching native target with
   `-- --locked` forwarded to Cargo;
9. publishes generated release notes and artifacts.

The checked-in manifest already uses:

```toml
copy_event_listener = "0.1.2"
```

Local development and release builds do not require a sibling
`copy_event_listener` checkout.

## Rust Dependency Updates

`"0.1.2"` is a compatible version requirement, not an exact pin. The committed
`src-tauri/Cargo.lock` selects the reviewed versions of all Rust dependencies,
including transitive dependencies and registry checksums. Do not run
`cargo update`, regenerate the lockfile, or replace dependencies in release CI.

Cargo's `--locked` fails if the lockfile is missing or dependency resolution
would change it. It still allows downloading the locked crates on a cold
runner; `--frozen` also forbids network access and is not needed here.
Tauri receives Cargo flags after `--`: the action uses
`args: ${{ matrix.args }} -- --locked`.

The action runs `scripts/tauri-release.sh`, which compares the working lockfile
byte-for-byte with `HEAD` before and after Tauri. A missing or changed lockfile
fails the build command before the action creates a release or uploads assets.
Checking only in a later workflow step would be too late. `pnpm test` includes
regression checks for the workflow flags and this failure behavior.

To intentionally update the listener, work on a normal PR branch:

```bash
# Edit Cargo.toml first if the desired version is outside its current requirement.
cargo update --manifest-path src-tauri/Cargo.toml -p copy_event_listener
git diff -- src-tauri/Cargo.toml src-tauri/Cargo.lock
cargo check --manifest-path src-tauri/Cargo.toml --locked
cargo test --manifest-path src-tauri/Cargo.toml --locked
```

Review all resulting lockfile changes, including transitive dependencies, and
commit `Cargo.lock` together with any manifest changes. Other Rust dependency
updates follow the same process. Run the existing automated gates and applicable
manual checks, have the PR reviewed and both native CI jobs pass, then tag the
approved commit. A release failure must be fixed through that process, never by
removing `--locked` or updating dependencies during the release job.

This locks Rust dependency selection; floating toolchains, runners, and action
versions mean it does not promise byte-identical installation packages.

## Local Release Build

Build the native release package from the current source with the same ad-hoc
signing identity used by the release workflow:

```bash
env APPLE_SIGNING_IDENTITY=- bash scripts/tauri-release.sh build -- --locked
```

The command writes the `.app` and `.dmg` bundles under
`src-tauri/target/release/bundle/` for the current Mac architecture. It does not
notarize the package.

Production packages do not subscribe to the development-only global runtime
diagnostic event or render safe-diagnostic JSON. Actionable startup and
user-invoked command errors remain localized and visible.

The security gate checks strict production CSP, empty static asset scope,
prototype freezing, per-window capabilities, absence of opener permissions,
audited dependency floors, and both native CI/release runner entries.

## Ad-Hoc Signing

The project is not currently enrolled for Apple Developer signing/notarization.
Jobs set:

```yaml
APPLE_SIGNING_IDENTITY: "-"
```

This creates an ad-hoc signature but does not establish a verified developer or
notarize the app. Gatekeeper may require Right-click → Open or
System Settings → Privacy & Security → Open Anyway.

For a trusted downloaded artifact that still reports damage after being moved
to `/Applications`, verify the signature before considering quarantine removal:

```bash
codesign --verify --deep --strict --verbose=4 "/Applications/ClipEcho.app"
xattr -dr com.apple.quarantine "/Applications/ClipEcho.app"
open "/Applications/ClipEcho.app"
```

## Required Pre-Tag Evidence

Run the automated gate in `docs/security-release-checklist.md`, the relevant
performance harness cases in `docs/performance.md`, and the full manual desktop
matrix.

At minimum, record native Apple Silicon and Intel evidence for:

- clean install and existing-database migration, including a second startup
  with no metadata rebuild;
- `0700` directory and `0600` database/sidecar/mirror permissions;
- manual launch, launch at login, app relocation, and duplicate launch;
- protocol skip combinations, source/remote badges, and canonical restore from
  both entry points;
- resource rejection/degradation and malicious HTML;
- 1000-row paging/lazy detail and menu bar behavior with all items plus
  configured smaller limits;
- offline use and unwritable/unsafe private paths;
- slow/failing JSONL destination, last-snapshot integrity, and bounded exit.

The checklist file is a test plan, not proof that these scenarios have already
passed. Attach dated, redacted results to the release record. If one
architecture cannot be exercised, keep the release blocked or obtain and
document an explicit release exception.

## Versions And Prereleases

Check version consistency in:

- `package.json`;
- `src-tauri/Cargo.toml`;
- `src-tauri/tauri.conf.json`.

Tags containing `-alpha`, `-beta`, or `-rc` are published as prereleases.
Others are normal releases. The workflow publishes immediately
(`releaseDraft: false`) and generates release notes.

## Post-Publish Verification

Download each produced artifact on matching native hardware rather than relying
only on the build job. Verify installation/approval, app launch, one synthetic
capture and restore, menu bar operation, single-instance activation, and
launch-at-login state.

## Release Risks

- Published listener behavior can change when its pinned version changes.
- Ad-hoc builds are not notarized and can require explicit Gatekeeper approval.
- Unit tests do not exercise real NSPasteboard, LaunchAgent state, app movement,
  WebView security behavior, or filesystem fault timing.
- Cross-compilation or native compilation alone is not runtime verification.
- Clipboard databases, mirrors, paths, source identifiers, and bodies must not
  appear in release logs or attachments; use synthetic redacted evidence.
