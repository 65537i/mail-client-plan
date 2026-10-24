import assert from "node:assert/strict";
import { Launcher } from "@wdio/cli";

assert(process.send, "Windows audit WDIO worker requires an IPC channel");
assert(process.argv[2], "Windows audit WDIO worker requires a config path");

const start = new Promise((resolve, reject) => {
  process.once("message", (message) => {
    if (message !== "start") {
      reject(new Error("Windows audit WDIO worker received an invalid start message"));
    } else {
      resolve();
    }
  });
  process.once("disconnect", () => {
    reject(new Error("Windows audit parent disconnected before starting WDIO"));
  });
});
process.send("ready");
await start;
process.exitCode = await new Launcher(process.argv[2]).run();
if (process.connected) process.disconnect();
