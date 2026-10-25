import assert from "node:assert/strict";
import path from "node:path";

function* parseCsvRecords(input) {
  let record = [];
  let value = "";
  let quoted = false;

  for (let index = 0; index < input.length; index += 1) {
    const character = input[index];
    if (character === '"') {
      if (quoted && input[index + 1] === '"') {
        value += '"';
        index += 1;
      } else {
        quoted = !quoted;
      }
    } else if (!quoted && character === ",") {
      record.push(value);
      value = "";
    } else if (!quoted && character === "\n") {
      record.push(value.replace(/\r$/, ""));
      yield record;
      record = [];
      value = "";
    } else {
      value += character;
    }
  }

  assert.equal(quoted, false, "Process Monitor CSV ended inside a quoted field");
  if (value.length > 0 || record.length > 0) {
    record.push(value.replace(/\r$/, ""));
    yield record;
  }
}

export function decodeWindowsFileTrace(buffer) {
  if (buffer.length >= 2 && buffer[0] === 0xff && buffer[1] === 0xfe) {
    return buffer.subarray(2).toString("utf16le");
  }
  if (buffer.length >= 2 && buffer[0] === 0xfe && buffer[1] === 0xff) {
    return Buffer.from(buffer.subarray(2)).swap16().toString("utf16le");
  }
  return buffer.toString("utf8");
}

function diagnosticToken(value) {
  return /^[A-Za-z0-9_. -]{1,80}$/.test(value) ? value : "[redacted]";
}

function normalizeWindowsPath(value) {
  return path.win32.normalize(value.trim()).replace(/^(?:\\\\\?\\|\\\?\?\\)/, "").toLowerCase();
}

function diagnosticDetail(value) {
  const allowed = [];
  let redacted = 0;
  for (const field of value.split(",")) {
    const item = field.trim();
    if (!item) continue;
    if (
      /^(?:Offset|Length|EndOfFile|AllocationSize): [0-9]{1,20}$/.test(item) ||
      /^SyncType: SyncType(?:Other|CreateSection)$/.test(item) ||
      /^PageProtection: PAGE_(?:READONLY|READWRITE|WRITECOPY|EXECUTE_READ|EXECUTE_READWRITE|EXECUTE_WRITECOPY|NOACCESS)$/.test(item)
    ) {
      if (allowed.length < 8) allowed.push(item);
      else redacted += 1;
    } else {
      redacted += 1;
    }
  }
  return { fields: allowed, redactedFields: redacted };
}

export function summarizeWindowsFileTrace(traceOutput, canaryPath) {
  const records = parseCsvRecords(traceOutput);
  const firstRecord = records.next();
  assert.equal(firstRecord.done, false, "Process Monitor CSV was empty");

  const headers = firstRecord.value.map((header) => header.replace(/^\uFEFF/, "").trim());
  const columns = new Map(headers.map((header, index) => [header.toLowerCase(), index]));
  const processColumn = columns.get("process name");
  const operationColumn = columns.get("operation");
  const pathColumn = columns.get("path");
  const timeColumn = columns.get("time of day");
  const resultColumn = columns.get("result");
  const detailColumn = columns.get("detail");
  assert(
    processColumn !== undefined && operationColumn !== undefined && pathColumn !== undefined,
    "Process Monitor CSV is missing Process Name, Operation, or Path columns",
  );

  const normalizedCanaryPath = normalizeWindowsPath(canaryPath);
  const canaryEvents = [];
  const canaryDiagnostics = [];
  const observedPaths = new Set();

  for (const fields of records) {
    assert.equal(fields.length, headers.length, "Process Monitor CSV row has an unexpected column count");
    const processName = fields[processColumn].trim();
    const eventPath = normalizeWindowsPath(fields[pathColumn]);
    if (eventPath) observedPaths.add(eventPath);
    if (eventPath === normalizedCanaryPath) {
      canaryEvents.push({
        processName,
        operation: fields[operationColumn].trim(),
      });
      if (canaryDiagnostics.length < 10) {
        const time = timeColumn === undefined ? "" : fields[timeColumn].trim();
        canaryDiagnostics.push({
          time: /^(?:[01]?\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,7})?(?: [AP]M)?$/.test(time)
            ? time : "[unavailable]",
          processName: diagnosticToken(processName),
          operation: diagnosticToken(fields[operationColumn].trim()),
          result: resultColumn === undefined ? "[unavailable]" : diagnosticToken(fields[resultColumn].trim()),
          detail: diagnosticDetail(detailColumn === undefined ? "" : fields[detailColumn]),
        });
      }
    }
  }

  return { canaryEvents, canaryDiagnostics, observedPaths };
}

export function inspectWindowsFileTrace(traceOutput, canaryPath, positiveControlPath, excludedPath) {
  assert(
    [canaryPath, positiveControlPath, excludedPath].every(
      (value) => typeof value === "string" && value.trim().length > 0,
    ),
    "canary, positive control, and excluded paths are required",
  );
  assert(
    new Set([canaryPath, positiveControlPath, excludedPath].map(normalizeWindowsPath)).size === 3,
    "canary, positive control, and excluded paths must be different files",
  );
  const summary = summarizeWindowsFileTrace(traceOutput, canaryPath);
  const controlSummary = summarizeWindowsFileTrace(traceOutput, positiveControlPath);
  const expectedPaths = new Set([
    normalizeWindowsPath(canaryPath),
    normalizeWindowsPath(positiveControlPath),
  ]);
  assert(
    [...summary.observedPaths, ...controlSummary.observedPaths].every((eventPath) => expectedPaths.has(eventPath)),
    "Process Monitor capture contained events outside the exact canary and control paths",
  );
  assert(
    !summary.observedPaths.has(normalizeWindowsPath(excludedPath)) &&
      !controlSummary.observedPaths.has(normalizeWindowsPath(excludedPath)),
    "Process Monitor capture retained an excluded synthetic file event",
  );
  const positiveControlEvents = controlSummary.canaryEvents.filter(
    ({ processName, operation }) =>
      processName.toLowerCase() === "node.exe" && operation === "ReadFile",
  );
  assert(
    positiveControlEvents.length > 0,
    "Process Monitor did not observe the Node synthetic-canary positive control",
  );

  return {
    positiveControlEvents: positiveControlEvents.length,
    canaryEvents: summary.canaryEvents,
    canaryDiagnostics: summary.canaryDiagnostics,
  };
}

export function verifyWindowsFileTrace(traceOutput, canaryPath, positiveControlPath, excludedPath) {
  const result = inspectWindowsFileTrace(traceOutput, canaryPath, positiveControlPath, excludedPath);
  assert.equal(
    result.canaryEvents.length,
    0,
    `synthetic file canary appeared in ${result.canaryEvents.length} unexpected event(s): ${JSON.stringify(result.canaryDiagnostics)}`,
  );
  return {
    positiveControlEvents: result.positiveControlEvents,
    canaryEvents: result.canaryEvents.length,
  };
}
