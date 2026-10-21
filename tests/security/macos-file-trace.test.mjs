import assert from "node:assert/strict";
import test from "node:test";
import { verifyMacosFileTrace } from "../../scripts/macos-file-trace.mjs";

const canary = "mc-synthetic.png";
const appEvent = "13:07:03.000001 open F=3 /synthetic/app 0.000001 mail-client.123";

test("AC-05: accepts an observed application with no canary event", () => {
  verifyMacosFileTrace(appEvent, canary);
});

test("AC-05: rejects empty or unrelated traces", () => {
  for (const trace of ["", "13:07:03.000001 open /mail-client/file 0.000001 node.456"]) {
    assert.throws(() => verifyMacosFileTrace(trace, canary), /did not observe/);
  }
});

test("AC-05: reports canary operation and process without leaking raw paths", () => {
  for (const processName of ["mail-client.123", "com.apple.WebKit.WebContent.456", "mdworker.789"]) {
    const trace = `${appEvent}\n13:07:04.000001 open F=4 /private/synthetic/${canary} 0.000001 ${processName}`;
    assert.throws(() => verifyMacosFileTrace(trace, canary), (error) => {
      assert(error.message.includes(`operation=open process/thread=${processName}`));
      assert(!error.message.includes("/private/synthetic"));
      assert(!error.message.includes(canary));
      return true;
    });
  }
});

test("AC-05: does not silently ignore an unrecognized canary event", () => {
  assert.throws(
    () => verifyMacosFileTrace(`${appEvent}\nunknown ${canary}`, canary),
    /unrecognized canary event format/,
  );
});

test("AC-05: bounds canary diagnostics while counting every matching event", () => {
  const event = `13:07:04.000001 stat64 /synthetic/${canary} 0.000001 node.456`;
  assert.throws(() => verifyMacosFileTrace([appEvent, ...Array(20).fill(event)].join("\n"), canary), (error) => {
    assert(error.message.includes("20 system-wide trace event(s)"));
    assert.equal(error.message.match(/operation=stat64/g).length, 10);
    return true;
  });
});
