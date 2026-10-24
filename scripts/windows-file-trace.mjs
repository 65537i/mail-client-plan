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

export function summarizeWindowsFileTrace(traceOutput, canaryPath) {
  const records = parseCsvRecords(traceOutput);
  const firstRecord = records.next();
  assert.equal(firstRecord.done, false, "Process Monitor CSV was empty");

  const headers = firstRecord.value.map((header) => header.replace(/^\uFEFF/, "").trim());
  const columns = new Map(headers.map((header, index) => [header.toLowerCase(), index]));
  const processColumn = columns.get("process name");
  const operationColumn = columns.get("operation");
  const pathColumn = columns.get("path");
  assert(
    processColumn !== undefined && operationColumn !== undefined && pathColumn !== undefined,
    "Process Monitor CSV is missing Process Name, Operation, or Path columns",
  );

  const canaryName = path.win32.basename(canaryPath).toLowerCase();
  const observedProcessNames = new Set();
  const canaryEvents = [];

  for (const fields of records) {
    if (fields.length < headers.length) continue;
    const processName = fields[processColumn].trim();
    if (processName) observedProcessNames.add(processName.toLowerCase());

    const eventPath = path.win32.normalize(fields[pathColumn].trim()).toLowerCase();
    if (path.win32.basename(eventPath) === canaryName) {
      canaryEvents.push({
        processName,
        operation: fields[operationColumn].trim(),
      });
    }
  }

  return { canaryEvents, observedProcessNames };
}

export function verifyWindowsFileTrace(traceOutput, canaryPath) {
  const summary = summarizeWindowsFileTrace(traceOutput, canaryPath);
  const positiveControlEvents = summary.canaryEvents.filter(
    ({ processName, operation }) =>
      processName.toLowerCase() === "powershell.exe" && operation === "ReadFile",
  );
  assert(
    positiveControlEvents.length > 0,
    "Process Monitor did not observe the PowerShell synthetic-canary positive control",
  );

  const unexpectedEvents = summary.canaryEvents.filter(
    ({ processName }) => processName.toLowerCase() !== "powershell.exe",
  );
  assert.equal(
    unexpectedEvents.length,
    0,
    `synthetic file canary appeared in ${unexpectedEvents.length} unexpected event(s): ${unexpectedEvents
      .slice(0, 10)
      .map(({ operation, processName }) => `operation=${operation} process=${processName}`)
      .join("; ")}`,
  );
  assert(
    summary.observedProcessNames.has("mail-client.exe"),
    "Process Monitor did not observe file activity from the Tauri application",
  );
  assert(
    summary.observedProcessNames.has("msedgewebview2.exe"),
    "Process Monitor did not observe file activity from a WebView2 process",
  );

  return {
    positiveControlEvents: positiveControlEvents.length,
    canaryEvents: summary.canaryEvents.length,
  };
}
