import { execFileSync, spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const releaseWorkflow = readFileSync(
  new URL("../.github/workflows/release.yml", import.meta.url),
  "utf8"
);

it("keeps CI and release dependency resolution locked", () => {
  const ciWorkflow = readFileSync(
    new URL("../.github/workflows/ci.yml", import.meta.url),
    "utf8"
  );
  for (const workflow of [ciWorkflow, releaseWorkflow]) {
    expect(workflow).not.toMatch(/\bcargo\s+update\b/);
    const commands = workflow.match(/run: cargo (?:check|test|fetch)\b[^\n]*/g);
    expect(commands?.length).toBeGreaterThanOrEqual(2);
    for (const command of commands ?? []) {
      expect(command).toMatch(/\s--locked(?:\s|$)/);
    }
  }
  expect(releaseWorkflow).toContain(
    "tauriScript: bash scripts/tauri-release.sh"
  );
  expect(releaseWorkflow).toContain("args: ${{ matrix.args }} -- --locked");
});

describe("release lockfile guard", () => {
  let root: string;
  let lockfile: string;

  function git(...args: string[]) {
    return execFileSync("git", args, { cwd: root, stdio: "pipe" });
  }

  function run(target = "aarch64-apple-darwin", env = {}) {
    return spawnSync(
      "bash",
      [
        "scripts/tauri-release.sh",
        "build",
        "--target",
        target,
        "--",
        "--locked",
      ],
      {
        cwd: root,
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${join(root, "bin")}:${process.env.PATH}`,
          ...env,
        },
      }
    );
  }

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "clipecho-release-"));
    lockfile = join(root, "src-tauri/Cargo.lock");
    for (const dir of ["scripts", "src-tauri", "bin"]) {
      mkdirSync(join(root, dir));
    }
    copyFileSync(
      new URL("./tauri-release.sh", import.meta.url),
      join(root, "scripts/tauri-release.sh")
    );
    writeFileSync(lockfile, "version = 4\n");
    git("init", "--quiet");
    git("add", "src-tauri/Cargo.lock", "scripts/tauri-release.sh");
    git(
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "commit",
      "--quiet",
      "-m",
      "fixture"
    );
    writeFileSync(
      join(root, "bin/pnpm"),
      `#!/usr/bin/env node
const fs = require("node:fs");
fs.writeFileSync("args.json", JSON.stringify(process.argv.slice(2)));
if (process.env.CHANGE_LOCK === "write") fs.appendFileSync("src-tauri/Cargo.lock", "# changed\\n");
if (process.env.CHANGE_LOCK === "delete") fs.unlinkSync("src-tauri/Cargo.lock");
process.exit(Number(process.env.BUILD_EXIT || 0));
`,
      { mode: 0o755 }
    );
  });

  afterEach(() => rmSync(root, { recursive: true, force: true }));

  it.each(["aarch64-apple-darwin", "x86_64-apple-darwin"])(
    "forwards Cargo's --locked argument for %s and accepts an unchanged lockfile",
    target => {
      const result = run(target);
      expect(result.status, result.stderr).toBe(0);
      expect(JSON.parse(readFileSync(join(root, "args.json"), "utf8"))).toEqual(
        ["tauri", "build", "--target", target, "--", "--locked"]
      );
    }
  );

  it.each(["modified", "staged", "missing", "untracked"])(
    "rejects a %s lockfile before invoking Tauri",
    state => {
      if (state === "missing") rmSync(lockfile);
      else if (state === "untracked") {
        git("rm", "--cached", "src-tauri/Cargo.lock");
        git(
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@example.com",
          "commit",
          "--quiet",
          "-m",
          "remove lock"
        );
      } else {
        writeFileSync(lockfile, "version = 4\n# changed\n");
        if (state === "staged") git("add", "src-tauri/Cargo.lock");
      }
      const result = run();
      expect(result.status).not.toBe(0);
      expect(result.stderr).toContain("Cargo.lock must match HEAD");
      expect(existsSync(join(root, "args.json"))).toBe(false);
    }
  );

  it.each(["write", "delete"])(
    "fails a successful Tauri build that changes the lockfile (%s)",
    change => {
      const result = run(undefined, { CHANGE_LOCK: change });
      expect(existsSync(join(root, "args.json"))).toBe(true);
      expect(result.status).not.toBe(0);
      expect(result.stderr).toContain("Cargo.lock must match HEAD");
    }
  );

  it("propagates a Tauri failure even when the lockfile is unchanged", () => {
    expect(run(undefined, { BUILD_EXIT: "17" }).status).toBe(17);
  });
});
