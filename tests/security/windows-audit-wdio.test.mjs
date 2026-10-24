import assert from "node:assert/strict";
import { fork } from "node:child_process";
import { once } from "node:events";
import test from "node:test";

for (const action of ["start", "invalid", "disconnect"]) {
  test(`AC-05: preloaded WDIO worker fails explicitly on ${action}`, { timeout: 30_000 }, async () => {
    const child = fork(
      new URL("../../scripts/windows-audit-wdio.mjs", import.meta.url),
      ["missing-windows-audit-test-config.mjs"],
      { stdio: ["ignore", "ignore", "pipe", "ipc"] },
    );
    const exited = once(child, "exit");
    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (text) => { stderr += text; });
    try {
      const first = await Promise.race([
        once(child, "message", { signal: AbortSignal.timeout(15_000) }).then(([message]) => message),
        exited.then(() => "exited before ready"),
      ]);
      assert.equal(first, "ready");
      assert.equal(child.exitCode, null);
      assert.equal(stderr, "");
      if (action === "disconnect") child.disconnect();
      else child.send(action);
      const [code] = await exited;
      assert.notEqual(code, 0);
      assert.match(stderr, action === "start"
        ? /missing-windows-audit-test-config/
        : action === "disconnect" ? /disconnected before starting/ : /invalid start message/);
    } finally {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill();
        await exited;
      }
    }
  });
}
