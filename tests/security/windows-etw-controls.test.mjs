import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = await readFile(new URL("../../scripts/windows-etw-controls.cpp", import.meta.url), "utf8");
const wrapper = await readFile(new URL("../../scripts/test-windows-etw-controls.ps1", import.meta.url), "utf8");

test("AC-05 candidate: ETW capture is opt-in and absent from existing audit routing", async () => {
  const [workflow, driver] = await Promise.all([
    readFile(new URL("../../.github/workflows/native.yml", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/test-windows-file-access.mjs", import.meta.url), "utf8"),
  ]);
  assert.doesNotMatch(workflow + driver, /etw-controls|ETW_CONTROLS/);
  assert.match(wrapper, /\[switch\]\$Capture/);
  assert.match(wrapper, /& \$executable --self-test[\s\S]*if \(\$Capture\) \{[\s\S]*--capture-controls \$Scenario/);
  assert.match(source, /argc == 2 && wcscmp\(argv\[1\], L"--self-test"\) == 0\) SelfTest\(\)/);
  assert.match(source, /argc == 3 && wcscmp\(argv\[1\], L"--capture-controls"\) == 0/);
  const fixtures = source.slice(source.indexOf("void SelfTest()"), source.indexOf("int wmain("));
  assert.doesNotMatch(fixtures, /StartTrace|\.Start\(|Capture\(|\.Prepare\(|CreateFile|Exercise\(/);
  assert.match(fixtures, /capture:not-started/);
});

test("AC-05 candidate: ETW owns only its session and never persists raw trace payloads", () => {
  assert.match(source, /MailClient-EtwControls-PoC/);
  assert.match(source, /StartTraceW\(&session[\s\S]*if \(started != ERROR_SUCCESS\) \{[\s\S]*session = 0/);
  assert.match(source, /EVENT_TRACE_REAL_TIME_MODE/);
  assert.doesNotMatch(source, /LogFileNameOffset\s*=|EVENT_TRACE_FILE_MODE|wpr -cancel|EVENT_TRACE_CONTROL_UPDATE/);
  assert.match(source, /ControlTraceW\(session, nullptr,[\s\S]*EVENT_TRACE_CONTROL_STOP/);
  assert.doesNotMatch(source, /ControlTraceW\(0,/);
  assert.match(wrapper, /finally \{/);
});

test("AC-05 candidate: bounded correlations and fail-closed decode never log paths or pointers", () => {
  assert.match(source, /maximumMappings = 128/);
  assert.match(source, /maximumEvents = 200000/);
  assert.match(source, /maximumDurationMs = 10000/);
  assert.match(source, /size <= 8192[\s\S]*"property-size"/);
  assert.match(source, /bytes\.size\(\) == 4 \|\| bytes\.size\(\) == 8/);
  assert.match(source, /table\.erase\(value\);[\s\S]*target != Target::other/);
  assert.match(source, /correlation-conflict/);
  assert.match(source, /CheckVersion\(id, event->EventHeader.EventDescriptor.Version\)/);
  const output = [...source.matchAll(/std::(?:printf|fprintf|fputs|puts)\([\s\S]*?\);/g)].map((match) => match[0]);
  assert.ok(output.length > 0);
  for (const statement of output) {
    assert.doesNotMatch(statement, /\.c_str\(|\.data\(|FileName|FileObject|devicePaths|GetLastError|what\(\)/);
  }
});

test("AC-05 candidate: readiness, zero-loss drain and both canary scenarios are mandatory", () => {
  assert.match(source, /ControlReady\(\)[\s\S]*counts\[0\]\[0\] > 0 && counts\[0\]\[1\] > 0 && counts\[0\]\[2\] > 0/);
  assert.match(source, /Require\(consumer.Snapshot\(\).ControlReady\(\), "ready-control-missing"\)/);
  assert.match(source, /Lossless\(properties.data.EventsLost, properties.data.LogBuffersLost,[\s\S]*properties.data.RealTimeBuffersLost\)/);
  assert.match(source, /WaitForSingleObject\(worker, 3000\)[\s\S]*CloseTrace\(trace\)/);
  assert.match(source, /Require\(consumer.Stop\(\), "session-stop-or-loss"\)/);
  assert.match(source, /CanaryObserved\(\) == touchCanary/);
  assert.match(source, /!touchCanary \|\| model.CanaryComplete\(\)/);
  assert.match(source, /const int verdict = Evaluate\(final, touchCanary\)/);
  assert.match(source, /scope:controls-only/);
  assert.match(source, /return model.CanaryObserved\(\) \? 2 : 0/);
  assert.match(source, /CanaryObserved\(\) \? "rejected" : "unobserved"/);
  assert.match(wrapper, /\$expectedExit = if \(\$Scenario -ceq "touched"\) \{ 2 \} else \{ 0 \}/);
  assert.doesNotMatch(source, /audit.passed|AC-05.passed/i);
  assert.match(wrapper, /\/W4 \/WX/);
  assert.match(wrapper, /finally \{[\s\S]*Remove-Item -LiteralPath \$temporary -Recurse -Force -ErrorAction Stop/);
});
