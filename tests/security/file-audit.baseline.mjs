import assert from "node:assert/strict";

describe("File audit diagnostic baseline (not an AC-05 attack test)", () => {
  it("keeps the default UI idle without injecting the hostile fixture or canary URL", async () => {
    assert.equal(process.env.MAIL_CLIENT_FILE_CANARY_URL, undefined);
    await browser.$("h1").waitForDisplayed();
    const originalUrl = await browser.getUrl();
    await browser.pause(1500);
    assert.equal(await browser.getUrl(), originalUrl);
    console.log("File audit baseline: no hostile fixture or file-canary URL was injected.");
  });
});
