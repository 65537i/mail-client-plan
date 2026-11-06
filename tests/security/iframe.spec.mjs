import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const maliciousFixture = await readFile(
  new URL("../../fixtures/security/malicious-email.html", import.meta.url),
  "utf8",
);
const requests = [];
let server;
let probeUrl;

describe("AC-05 and AC-23: real WebView security and accessibility", () => {
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
      console.log(`AC-05: closing probe server after ${requests.length} requests`);
      await new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
        server.closeAllConnections();
      });
      console.log("AC-05: probe server closed");
    }
  });

  it("AC-23: exposes named controls as focusable controls", async () => {
    await browser.$("h1").waitForDisplayed();
    const semantics = await browser.execute(() => {
      const commandRegion = document.querySelector(
        'section[aria-labelledby="command-title"]',
      );
      const messageRegion = document.querySelector(
        'section[aria-labelledby="message-title"]',
      );
      const button = commandRegion?.querySelector("button");
      const output = commandRegion?.querySelector("output");
      const frame = messageRegion?.querySelector("iframe");
      return {
        initialFocus: document.activeElement?.tagName ?? "none",
        commandRegionLabel: commandRegion?.getAttribute("aria-labelledby"),
        buttonType: button?.type ?? "missing",
        buttonName: button?.textContent?.trim() ?? "missing",
        buttonTabIndex: button?.tabIndex ?? -999,
        buttonDisabled: button?.disabled ?? true,
        outputLive: output?.getAttribute("aria-live") ?? "missing",
        messageRegionLabel: messageRegion?.getAttribute("aria-labelledby"),
        frameTitle: frame?.title ?? "missing",
        frameTabIndex: frame?.tabIndex ?? -999,
      };
    });
    assert.ok(
      semantics.initialFocus === "BODY" || semantics.initialFocus === "HTML",
      `Expected the document to start without a control focused, got ${semantics.initialFocus}`,
    );
    assert.deepEqual(
      {
        commandRegionLabel: semantics.commandRegionLabel,
        buttonType: semantics.buttonType,
        buttonName: semantics.buttonName,
        buttonTabIndex: semantics.buttonTabIndex,
        buttonDisabled: semantics.buttonDisabled,
        outputLive: semantics.outputLive,
        messageRegionLabel: semantics.messageRegionLabel,
        frameTitle: semantics.frameTitle,
        frameTabIndex: semantics.frameTabIndex,
      },
      {
        commandRegionLabel: "command-title",
        buttonType: "button",
        buttonName: "Invoke security probe",
        buttonTabIndex: 0,
        buttonDisabled: false,
        outputLive: "polite",
        messageRegionLabel: "message-title",
        frameTitle: "Sandboxed synthetic hostile email",
        frameTabIndex: 0,
      },
    );

    const focusability = await browser.execute(() => {
      const button = document.querySelector(
        'section[aria-labelledby="command-title"] button',
      );
      const frame = document.querySelector(
        'section[aria-labelledby="message-title"] iframe',
      );
      if (
        !(button instanceof HTMLButtonElement) ||
        !(frame instanceof HTMLIFrameElement)
      ) {
        return { buttonFocused: false, frameFocused: false };
      }

      button.focus();
      const buttonFocused = document.activeElement === button;
      frame.focus();
      return {
        buttonFocused,
        frameFocused: document.activeElement === frame,
      };
    });
    assert.deepEqual(focusability, {
      buttonFocused: true,
      frameFocused: true,
    });
  });

  it("AC-23: native keyboard focus and activation", async function () {
    if (process.platform !== "win32") {
      this.skip();
    }

    await browser.$("h1").waitForDisplayed();
    await browser.execute(() => {
      window.__nativeKeyEvents = [];
      window.addEventListener(
        "keydown",
        (event) => {
          window.__nativeKeyEvents.push({
            key: event.key,
            trusted: event.isTrusted,
          });
        },
        true,
      );
    });

    const applicationPath = process.env.MAIL_CLIENT_WDIO_BINARY ??
      path.resolve("target", "release", "mail-client.exe");
    const sendNativeKey = (key, shift = false) => {
      const args = [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle",
        "Hidden",
        "-File",
        fileURLToPath(new URL("./windows-send-tab.ps1", import.meta.url)),
        "-ApplicationPath",
        applicationPath,
        "-Key",
        key,
      ];
      if (shift) {
        args.push("-Shift");
      }
      const output = execFileSync(
        "powershell.exe",
        args,
        {
          encoding: "utf8",
          timeout: 10_000,
          windowsHide: true,
        },
      );
      assert.equal(output.trim(), "NATIVE_KEY_SENT");
    };

    const documentFocus = await browser.execute(() => {
      const activeElement = document.activeElement;
      if (activeElement instanceof HTMLElement) {
        activeElement.blur();
      }
      return document.activeElement?.tagName ?? "none";
    });
    assert.ok(
      documentFocus === "BODY" || documentFocus === "HTML",
      `Expected no control to be focused before native Tab, got ${documentFocus}`,
    );

    sendNativeKey("Tab");
    await browser.pause(100);
    const firstTabResult = await browser.execute(() => ({
      buttonFocused:
        document.activeElement ===
        document.querySelector('section[aria-labelledby="command-title"] button'),
      activeElement: document.activeElement?.tagName ?? "none",
      documentHasFocus: document.hasFocus(),
      trusted:
        window.__nativeKeyEvents.at(-1)?.key === "Tab" &&
        window.__nativeKeyEvents.at(-1)?.trusted === true,
    }));
    assert.equal(firstTabResult.trusted, true);
    assert.equal(firstTabResult.documentHasFocus, true);
    assert.ok(
      firstTabResult.buttonFocused || firstTabResult.activeElement === "BODY",
      `Expected native Tab to leave focus on BODY or move to the command button, got ${firstTabResult.activeElement}`,
    );
    if (!firstTabResult.buttonFocused) {
      sendNativeKey("Tab");
      await browser.pause(100);
      const secondTabFromDocument = await browser.execute(() => ({
        focused:
          document.activeElement ===
          document.querySelector(
            'section[aria-labelledby="command-title"] button',
          ),
        trusted:
          window.__nativeKeyEvents.at(-1)?.key === "Tab" &&
          window.__nativeKeyEvents.at(-1)?.trusted === true,
      }));
      assert.deepEqual(
        secondTabFromDocument,
        { focused: true, trusted: true },
        "A subsequent native Tab should focus the named command button",
      );
    }

    sendNativeKey("Tab");
    await browser.pause(100);
    const secondTabResult = await browser.execute(() => ({
      focused:
        document.activeElement ===
        document.querySelector('section[aria-labelledby="message-title"] iframe'),
      trusted:
        window.__nativeKeyEvents.at(-1)?.key === "Tab" &&
        window.__nativeKeyEvents.at(-1)?.trusted === true,
    }));
    assert.deepEqual(
      secondTabResult,
      { focused: true, trusted: true },
      "Native Tab should move focus from the command button to the titled iframe",
    );

    sendNativeKey("Tab", true);
    await browser.pause(100);
    const reverseTabResult = await browser.execute(() => ({
      focused:
        document.activeElement ===
        document.querySelector(
          'section[aria-labelledby="command-title"] button',
        ),
    }));
    assert.deepEqual(
      reverseTabResult,
      { focused: true },
      "Native Shift+Tab should return focus to the named command button",
    );

    sendNativeKey("Enter");
    await browser.waitUntil(
      async () =>
        (await browser.$("output").getText()).startsWith("IPC rejected:"),
      {
        timeout: 5_000,
        timeoutMsg: "Enter did not activate the focused command button",
      },
    );
    const activation = await browser.execute(() => ({
      focused:
        document.activeElement ===
        document.querySelector(
          'section[aria-labelledby="command-title"] button',
        ),
      trusted:
        window.__nativeKeyEvents.at(-1)?.key === "Enter" &&
        window.__nativeKeyEvents.at(-1)?.trusted === true,
      output: document.querySelector("output")?.textContent?.trim() ?? "",
    }));
    assert.equal(activation.focused, true);
    assert.equal(activation.trusted, true);
    assert.match(activation.output, /^IPC rejected:/);
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
    const fileCanaryUrl =
      process.env.MAIL_CLIENT_FILE_CANARY_URL ??
      "file:///synthetic-mail-client-file-canary";
    const hostileHtml = maliciousFixture
      .replaceAll("http://127.0.0.1:39871", probeUrl)
      .replaceAll("file:///synthetic-mail-client-file-canary", fileCanaryUrl);
    if (process.env.MAIL_CLIENT_FILE_CANARY_URL) {
      assert(hostileHtml.includes(fileCanaryUrl));
      assert(!hostileHtml.includes("file:///synthetic-mail-client-file-canary"));
    }
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
    }, hostileHtml);
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
