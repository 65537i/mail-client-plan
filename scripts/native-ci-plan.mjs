import assert from "node:assert/strict";
import { appendFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const platforms = [
  { platform: "ubuntu-24.04-x64", runner: "ubuntu-24.04" },
  { platform: "windows-2025-x64", runner: "windows-2025" },
  { platform: "macos-14-arm64", runner: "macos-14" },
  { platform: "macos-15-intel", runner: "macos-15-intel" },
];

export function nativeCiPlan(event, target = "", mode = "") {
  assert(["push", "pull_request", "workflow_dispatch"].includes(event), "unsupported native CI event");
  if (event !== "workflow_dispatch") {
    assert(target === "" && mode === "", "manual inputs are not allowed on automatic CI");
    return {
      matrix: { include: event === "push" ? platforms.slice(0, 1) : platforms },
      mode: event === "push" ? "basic" : "full",
    };
  }
  assert(target === "all" || platforms.some((item) => item.platform === target), "invalid native CI target");
  assert(["basic", "webview", "full"].includes(mode), "invalid native CI mode");
  return {
    matrix: { include: target === "all" ? platforms : platforms.filter((item) => item.platform === target) },
    mode,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const plan = nativeCiPlan(process.env.CI_EVENT, process.env.CI_TARGET, process.env.CI_MODE);
  assert(process.env.GITHUB_OUTPUT, "GITHUB_OUTPUT is required");
  assert(process.env.GITHUB_STEP_SUMMARY, "GITHUB_STEP_SUMMARY is required");
  await appendFile(process.env.GITHUB_OUTPUT, `matrix=${JSON.stringify(plan.matrix)}\nmode=${plan.mode}\n`);
  await appendFile(
    process.env.GITHUB_STEP_SUMMARY,
    `## Native validation scope\n\nMode: **${plan.mode}**\n\nTargets: ${plan.matrix.include.map((item) => item.platform).join(", ")}\n\n${plan.mode === "full" ? "Full checks for the selected targets; all four targets are required for cross-OS validation." : "Partial validation only. Production isolation, launch smoke tests and protocol integration are not covered. Run all targets with full mode before treating cross-OS validation as complete."}\n`,
  );
  console.log(`native CI: mode=${plan.mode}, targets=${plan.matrix.include.map((item) => item.platform).join(", ")}`);
}
