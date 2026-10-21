import assert from "node:assert/strict";

export function verifyMacosFileTrace(traceOutput, canaryName) {
  const lines = traceOutput.split(/\r?\n/);
  const canaryEvents = lines.filter((line) => line.includes(canaryName));
  const summaries = canaryEvents.slice(0, 10).map((line) => {
    const event = line.match(
      /^\s*\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+([A-Za-z0-9_]+)\b.*\s([A-Za-z0-9_.:-]+)\s*$/,
    );
    return event
      ? `operation=${event[1]} process/thread=${event[2]}`
      : "unrecognized canary event format";
  });

  assert.equal(
    canaryEvents.length,
    0,
    `synthetic file canary appeared in ${canaryEvents.length} system-wide trace event(s): ${summaries.join("; ")}. Attribution to the WebView is not established by this check.`,
  );
  assert(
    lines.some((line) => /\bmail-client(?:\.\d+)?\s*$/.test(line)),
    "fs_usage did not observe filesystem activity from the Tauri application",
  );
}
