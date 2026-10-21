import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));

export const config = {
  runner: "local",
  specs: ["./tests/security/*.spec.mjs"],
  maxInstances: 1,
  capabilities: [{ browserName: "tauri" }],
  logLevel: "warn",
  framework: "mocha",
  services: [
    [
      "@wdio/tauri-service",
      {
        appBinaryPath:
          process.env.MAIL_CLIENT_WDIO_BINARY ??
          path.join(
            root,
            "target",
            "release",
            process.platform === "win32" ? "mail-client.exe" : "mail-client",
          ),
        driverProvider: "embedded",
        commandTimeout: 60_000,
      },
    ],
  ],
  mochaOpts: {
    timeout: 30_000,
  },
};
