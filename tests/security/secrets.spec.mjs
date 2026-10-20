import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

const runId = `wdio-${randomUUID()}`;
const syntheticSecret = `SYNTHETIC-${randomUUID()}`;

async function invokeSecretStore(operation, value) {
  return browser.executeAsync(
    ({ operation, runId, value }, done) => {
      window.__TAURI__.core
        .invoke("secret_store_probe", {
          operation,
          runId,
          value,
        })
        .then((result) => done({ result }))
        .catch((error) => {
          done({ error: String(error) });
        });
    },
    { operation, runId, value },
  );
}

describe("AC-06: operating-system secret store", () => {
  it("stores a synthetic credential or explicitly reports an unavailable store", async () => {
    let stored = false;
    try {
      const storeResult = await invokeSecretStore("store", syntheticSecret);
      if (storeResult.error || storeResult.result?.status === "error") {
        const error = storeResult.error ?? storeResult.result.message;
        assert.notEqual(
          process.env.MAIL_CLIENT_REQUIRE_SECRET_STORE,
          "1",
          `CI requires a functioning OS credential store: ${error}`,
        );
        assert.match(
          error,
          /secure store (unavailable|write failed)/,
          "store failure must be explicit",
        );
        return;
      }

      assert.equal(storeResult.result?.status, "success");
      assert.equal(storeResult.result.message, "stored");
      stored = true;

      const readResult = await invokeSecretStore("read");
      assert.equal(readResult.result?.status, "success");
      assert.equal(readResult.result.message, syntheticSecret);

      const deleteResult = await invokeSecretStore("delete");
      assert.equal(deleteResult.result?.status, "success");
      assert.equal(deleteResult.result.message, "deleted");
      stored = false;

      const missingResult = await invokeSecretStore("read");
      assert.equal(missingResult.result?.status, "error");
      assert.match(missingResult.result.message, /secure store read failed/);
    } finally {
      if (stored) {
        const cleanupResult = await invokeSecretStore("delete");
        assert.equal(cleanupResult.result?.status, "success");
      }
    }
  });
});
