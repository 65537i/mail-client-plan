import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";

const maliciousFixture = await readFile(
  new URL("../../fixtures/security/malicious-email.html", import.meta.url),
  "utf8",
);
const requests = [];
let server;
let probeUrl;

describe("AC-05: real WebKitGTK HTML isolation", () => {
  before(async () => {
    server = createServer((request, response) => {
      requests.push(request.url);
      response.writeHead(200, {
        "content-type": "text/css",
        "cache-control": "no-store",
      });
      response.end("body { color: red; }");
    });
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    assert(address && typeof address !== "string");
    probeUrl = `http://127.0.0.1:${address.port}`;
  });

  after(async () => {
    if (server?.listening) {
      await new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    }
  });

  it("allows the explicit IPC permission through the trusted main UI", async () => {
    const runId = `wdio-${randomUUID()}`;
    const result = await browser.executeAsync(({ runId }, done) => {
      window.__TAURI__.core
        .invoke("secret_store_probe", { operation: "read", runId })
        .then((value) => done({ value }))
        .catch((error) => done({ error: String(error) }));
    }, { runId });
    assert.equal(result.error, undefined, "trusted main-window IPC command was denied");
    assert.equal(result.value?.status, "error");
    assert.match(
      result.value.message,
      /^secure store (unavailable|read failed):/,
      "trusted main-window IPC should return the explicit SecretStore result",
    );
  });

  it("blocks script, external requests, and file/top navigation attempts", async () => {
    console.log("AC-05: waiting for trusted UI");
    await browser.$("h1").waitForDisplayed();
    console.log("AC-05: trusted UI is ready");
    const originalUrl = await browser.getUrl();

    console.log("AC-05: injecting hostile fixture");
    await browser.execute((html) => {
      window.__mailClientSecurityMessages = [];
      window.addEventListener("message", (event) => {
        window.__mailClientSecurityMessages.push(event.data);
      });
      const frame = document.querySelector("iframe");
      if (!(frame instanceof HTMLIFrameElement)) {
        throw new Error("Expected the sandboxed message iframe");
      }
      frame.dataset.securityTestLoads = "0";
      frame.addEventListener("load", () => {
        frame.dataset.securityTestLoads = String(
          Number(frame.dataset.securityTestLoads) + 1,
        );
      });
      frame.srcdoc = html;
    }, maliciousFixture.replaceAll("http://127.0.0.1:39871", probeUrl));
    console.log("AC-05: fixture injection returned");

    await browser.pause(1500);
    console.log("AC-05: post-load inspection started");

    const topLevel = await browser.execute(() => ({
      url: location.href,
      title: document.title,
      messages: window.__mailClientSecurityMessages,
      iframeSandbox: document.querySelector("iframe")?.getAttribute("sandbox"),
      iframeDocumentAvailable:
        document.querySelector("iframe")?.contentDocument !== null,
      iframeLoadCount: Number(
        document.querySelector("iframe")?.dataset.securityTestLoads,
      ),
    }));
    console.log("AC-05: post-load inspection returned");
    assert.equal(topLevel.url, originalUrl, "top-level navigation changed");
    assert.deepEqual(topLevel.messages, [], "message fixture script executed");
    assert.equal(topLevel.title, "Mail Client", "top-level document changed");
    assert.equal(topLevel.iframeSandbox, "", "iframe sandbox flags were broadened");
    assert.equal(
      topLevel.iframeDocumentAvailable,
      false,
      "parent can access the sandboxed iframe document",
    );
    assert.equal(topLevel.iframeLoadCount, 1, "iframe navigated after loading srcdoc");
    assert.deepEqual(requests, [], "fixture made an external HTTP request");
  });
});
