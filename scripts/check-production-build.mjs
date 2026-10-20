import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import path from "node:path";

const root = process.cwd();
const tree = spawnSync(
  "cargo",
  [
    "tree",
    "--manifest-path",
    "src-tauri/Cargo.toml",
    "--locked",
    "--no-default-features",
    "-e",
    "normal",
  ],
  { cwd: root, encoding: "utf8" },
);
assert.equal(tree.status, 0, tree.stderr);
assert(!tree.stdout.includes("tauri-plugin-wdio"), "production dependency graph contains WDIO");

const config = JSON.parse(
  await readFile(path.join(root, "src-tauri/tauri.conf.json"), "utf8"),
);
assert.deepEqual(config.app.security.capabilities, ["default"]);
assert.notEqual(config.app.withGlobalTauri, true);

const capability = JSON.parse(
  await readFile(path.join(root, "src-tauri/capabilities/default.json"), "utf8"),
);
assert(
  capability.permissions.every((permission) => !permission.startsWith("wdio:")),
  "production capability grants WDIO permissions",
);
assert(
  capability.permissions.every((permission) => !permission.startsWith("allow-")),
  "production capability grants a test-only app command",
);

const binaryName = process.platform === "win32" ? "mail-client.exe" : "mail-client";
const binary = await readFile(path.join(root, "target/release", binaryName));
for (const marker of ["TAURI_WEBDRIVER_PORT", "tauri-plugin-wdio-webdriver", "wdioTauri"]) {
  assert(!binary.includes(marker), `production binary contains test-only marker: ${marker}`);
}

console.log("Production build excludes WebDriver plugins, permissions, and global Tauri API.");
