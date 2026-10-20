import assert from "node:assert/strict";
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

  it("blocks script, external requests, and file/top navigation attempts", async () => {
    await browser.$("h1").waitForDisplayed();
    const originalUrl = await browser.getUrl();

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

    await browser.pause(1500);

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

  it("allows the explicit IPC permission through the trusted main UI", async () => {
    await browser.$("button").click();
    await browser.waitUntil(
      async () => (await browser.$("output").getText()) === "security-probe-ok",
      { timeout: 5000, timeoutMsg: "main-window command permission was not granted" },
    );
  });
});
