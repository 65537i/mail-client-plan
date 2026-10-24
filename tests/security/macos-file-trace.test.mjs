import assert from "node:assert/strict";
import test from "node:test";
import { verifyMacosFileTrace } from "../../scripts/macos-file-trace.mjs";

const canary = "mc-synthetic.png";
const positiveControl = "mc-control.png";
const positiveControlProcess = "cat.456";
const appEvent = "13:07:03.000001 open F=3 /synthetic/app 0.000001 mail-client.123";
const positiveControlEvent = `13:07:03.000002 read /synthetic/${positiveControl} 0.000001 ${positiveControlProcess}`;
const verify = (trace) =>
  verifyMacosFileTrace(trace, {
    canaryName: canary,
    positiveControlName: positiveControl,
    positiveControlProcess,
  });

test("AC-05: accepts an observed application with no canary event", () => {
  assert.throws(() => verify(appEvent), /positive-control file read/);
  assert.deepEqual(verify(`${appEvent}\n${positiveControlEvent}`), {
    systemMetadataEvents: 0,
    positiveControlEvents: 1,
  });
});

test("AC-05: rejects missing or unexpected positive-control observations", () => {
  assert.throws(
    () => verify(`${appEvent}\n${positiveControlEvent.replace("cat.456", "cat.999")}`),
    /positive-control file read/,
  );
  assert.throws(
    () =>
      verify(
        `${appEvent}\n${positiveControlEvent}\n13:07:03.000003 open /synthetic/${positiveControl} 0.000001 mdworker.789`,
      ),
    /positive-control file was accessed by an unexpected process/,
  );
});

test("AC-05: rejects empty or unrelated traces", () => {
  for (const trace of ["", "13:07:03.000001 open /mail-client/file 0.000001 node.456"]) {
    assert.throws(() => verify(trace), /did not observe/);
  }
});

test("AC-05: reports canary operation and process without leaking raw paths", () => {
  for (const processName of ["mail-client.123", "com.apple.WebKit.WebContent.456", "mdworker.789"]) {
    const trace = `${appEvent}\n13:07:04.000001 open F=4 /private/synthetic/${canary} 0.000001 ${processName}`;
    assert.throws(() => verify(`${trace}\n${positiveControlEvent}`), (error) => {
      assert(error.message.includes(`operation=open process/thread=${processName}`));
      assert(!error.message.includes("/private/synthetic"));
      assert(!error.message.includes(canary));
      return true;
    });
  }
});

test("AC-05: does not silently ignore an unrecognized canary event", () => {
  assert.throws(
    () => verify(`${appEvent}\nunknown ${canary}\n${positiveControlEvent}`),
    /unrecognized canary event format/,
  );
});

test("AC-05: bounds canary diagnostics while counting every matching event", () => {
  const event = `13:07:04.000001 stat64 /synthetic/${canary} 0.000001 node.456`;
  assert.throws(
    () => verify([appEvent, ...Array(20).fill(event), positiveControlEvent].join("\n")),
    (error) => {
      assert(error.message.includes("20 unexpected system-wide trace event(s)"));
      assert.equal(error.message.match(/operation=stat64/g).length, 10);
      return true;
    },
  );
});

test("AC-05: separately counts only fseventsd lstat64 metadata observations", () => {
  const event = `13:32:35.000001 lstat64 /synthetic/${canary} 0.000001 fseventsd.2298`;
  assert.deepEqual(verify(`${appEvent}\n${event}\n${event}\n${positiveControlEvent}`), {
    systemMetadataEvents: 2,
    positiveControlEvents: 1,
  });
  assert.throws(() => verify(event), /did not observe/);
});

test("AC-05: rejects other daemon operations and lookalike process names", () => {
  for (const [operation, processName] of [
    ["open", "fseventsd.2298"],
    ["read", "fseventsd.2298"],
    ["stat64", "fseventsd.2298"],
    ["lstat64", "fake-fseventsd.2298"],
    ["lstat64", "fseventsd.2298.extra"],
    ["lstat64", "mail-client.123"],
    ["lstat64", "com.apple.WebKit.WebContent.456"],
  ]) {
    const event = `13:32:35.000001 ${operation} /synthetic/${canary} 0.000001 ${processName}`;
    assert.throws(
      () => verify(`${appEvent}\n${event}\n${positiveControlEvent}`),
      /unexpected system-wide/,
    );
  }
});

test("AC-05: a classified metadata event cannot hide another canary event", () => {
  const events = [
    appEvent,
    positiveControlEvent,
    `13:32:35.000001 lstat64 /synthetic/${canary} 0.000001 fseventsd.2298`,
    `13:32:35.000002 open /synthetic/${canary} 0.000001 mail-client.123`,
  ];
  assert.throws(() => verify(events.join("\n")), (error) => {
    assert(error.message.includes("1 unexpected system-wide trace event(s)"));
    assert(error.message.includes("Separately classified fseventsd lstat64 events: 1"));
    assert(error.message.includes("operation=open process/thread=mail-client.123"));
    return true;
  });
});
