import assert from "node:assert/strict";

export function verifyMacosFileTrace(
  traceOutput,
  { canaryName, positiveControlName, positiveControlProcess },
) {
  const lines = traceOutput.split(/\r?\n/);
  const canaryEvents = lines.filter((line) => line.includes(canaryName));
  const parsedEvents = canaryEvents.map((line) =>
    line.match(
      /^\s*\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+([A-Za-z0-9_]+)\b.*\s([A-Za-z0-9_.:-]+)\s*$/,
    ),
  );
  // FSEvents observes filesystem changes independently of the application.
  const isSystemMetadataEvent = (event) =>
    event !== null && event[1] === "lstat64" && /^fseventsd\.\d+$/.test(event[2]);
  const systemMetadataEvents = parsedEvents.filter(isSystemMetadataEvent).length;
  const unexpectedEvents = parsedEvents.filter((event) => !isSystemMetadataEvent(event));
  const summaries = unexpectedEvents.slice(0, 10).map((event) => {
    return event
      ? `operation=${event[1]} process/thread=${event[2]}`
      : "unrecognized canary event format";
  });

  assert.equal(
    unexpectedEvents.length,
    0,
    `synthetic file canary appeared in ${unexpectedEvents.length} unexpected system-wide trace event(s): ${summaries.join("; ")}. Separately classified fseventsd lstat64 events: ${systemMetadataEvents}. Attribution to the WebView is not established by this check.`,
  );
  assert(
    lines.some((line) => /\bmail-client(?:\.\d+)?\s*$/.test(line)),
    "fs_usage did not observe filesystem activity from the Tauri application",
  );

  const positiveControlEvents = lines
    .filter((line) => line.includes(positiveControlName))
    .map((line) =>
      line.match(
        /^\s*\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+([A-Za-z0-9_]+)\b.*\s([A-Za-z0-9_.:-]+)\s*$/,
      ),
    );
  const observedPositiveControl = positiveControlEvents.some(
    (event) =>
      event !== null &&
      ["open", "open_nocancel", "read", "read_nocancel"].includes(event[1]) &&
      event[2] === positiveControlProcess,
  );
  assert(
    observedPositiveControl,
    `fs_usage did not observe the explicit positive-control file read; matching file events=${positiveControlEvents.length}; expected process=${positiveControlProcess}; observed=${positiveControlEvents
      .slice(0, 10)
      .map((event) => event
        ? `operation=${event[1]} process/thread=${event[2]}`
        : "unrecognized control event format")
      .join("; ")}`,
  );

  const unexpectedPositiveControlEvents = positiveControlEvents.filter(
    (event) =>
      event === null ||
      (!isSystemMetadataEvent(event) &&
        !(
          event[2] === positiveControlProcess &&
          ["open", "open_nocancel", "read", "read_nocancel"].includes(event[1])
        )),
  );
  assert.equal(
    unexpectedPositiveControlEvents.length,
    0,
    "positive-control file was accessed by an unexpected process",
  );

  return { systemMetadataEvents, positiveControlEvents: positiveControlEvents.length };
}
