import assert from "node:assert/strict";
import test from "node:test";
import {
  decodeWindowsFileTrace,
  verifyWindowsFileTrace,
} from "../../scripts/windows-file-trace.mjs";

const canaryPath = "C:\\Users\\runner\\Temp\\mc-synthetic.png";
const header =
  '"Time of Day","Process Name","PID","Operation","Path","Result","Detail"\r\n';

test("AC-05: requires a positive control and observes the app and WebView2", () => {
  const trace =
    header +
    '"10:00:00.0000000","powershell.exe","100","ReadFile","C:\\\\Users\\\\runner\\\\Temp\\\\mc-synthetic.png","SUCCESS","Offset: 0"\r\n' +
    '"10:00:00.0000001","mail-client.exe","200","CreateFile","C:\\\\app\\\\mail.db","SUCCESS",""\r\n' +
    '"10:00:00.0000002","msedgewebview2.exe","300","ReadFile","C:\\\\app\\\\WebView2Loader.dll","SUCCESS",""\r\n';

  assert.deepEqual(verifyWindowsFileTrace(trace, canaryPath), {
    positiveControlEvents: 1,
    canaryEvents: 1,
  });
});

test("AC-05: rejects canary access from the app or any other process", () => {
  const trace =
    header +
    '"10:00:00.0000000","powershell.exe","100","ReadFile","C:\\\\Users\\\\runner\\\\Temp\\\\mc-synthetic.png","SUCCESS",""\r\n' +
    '"10:00:00.0000001","mail-client.exe","200","CreateFile","C:\\\\Users\\\\runner\\\\Temp\\\\mc-synthetic.png","SUCCESS",""\r\n' +
    '"10:00:00.0000002","msedgewebview2.exe","300","ReadFile","C:\\\\app\\\\WebView2Loader.dll","SUCCESS",""\r\n';

  assert.throws(
    () => verifyWindowsFileTrace(trace, canaryPath),
    /synthetic file canary appeared in 1 unexpected event/,
  );
});

test("AC-05: rejects unknown CSV layouts and missing positive controls", () => {
  assert.throws(
    () => verifyWindowsFileTrace('"Process Name","Path"\r\n', canaryPath),
    /missing Process Name, Operation, or Path columns/,
  );
  assert.throws(
    () =>
      verifyWindowsFileTrace(
        header +
          '"10:00:00.0000000","mail-client.exe","200","CreateFile","C:\\\\app\\\\mail.db","SUCCESS",""\r\n' +
          '"10:00:00.0000001","msedgewebview2.exe","300","ReadFile","C:\\\\app\\\\WebView2Loader.dll","SUCCESS",""\r\n',
        canaryPath,
      ),
    /did not observe the PowerShell synthetic-canary positive control/,
  );
});

test("AC-05: decodes UTF-8 and UTF-16 Process Monitor exports", () => {
  const csv = Buffer.from(header, "utf8");
  const utf16le = Buffer.concat([
    Buffer.from([0xff, 0xfe]),
    Buffer.from(header, "utf16le"),
  ]);
  const utf16be = Buffer.concat([
    Buffer.from([0xfe, 0xff]),
    Buffer.from(header, "utf16le").swap16(),
  ]);

  assert.equal(decodeWindowsFileTrace(csv), header);
  assert.equal(decodeWindowsFileTrace(utf16le), header);
  assert.equal(decodeWindowsFileTrace(utf16be), header);
});
