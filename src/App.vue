<script setup lang="ts">
import { invoke } from "@tauri-apps/api/core";
import { ref } from "vue";
import attackFixture from "../fixtures/security/malicious-email.html?raw";

const probeResult = ref("未実行");
const isSecurityTestMode = import.meta.env.MODE === "security-test";
const sandboxDocument = [
  "<!doctype html>",
  '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'none\'; connect-src \'none\'; img-src \'none\'; style-src \'unsafe-inline\'; font-src \'none\'; media-src \'none\'; frame-src \'none\'; object-src \'none\'; form-action \'none\'; base-uri \'none\'">',
  attackFixture,
].join("");

async function runSecurityProbe(): Promise<void> {
  try {
    probeResult.value = await invoke<string>("security_probe");
  } catch (error) {
    probeResult.value = `IPC rejected: ${String(error)}`;
  }
}
</script>

<template>
  <main>
    <h1>Mail Client — HTML security PoC</h1>
    <p>
      Synthetic hostile email is rendered only in a sandboxed iframe. This is a
      security prototype, not the production message renderer.
    </p>

    <section v-if="isSecurityTestMode" aria-labelledby="command-title">
      <h2 id="command-title">Explicit IPC permission</h2>
      <button type="button" @click="runSecurityProbe">Invoke security probe</button>
      <output aria-live="polite">{{ probeResult }}</output>
    </section>

    <section aria-labelledby="message-title">
      <h2 id="message-title">Untrusted HTML fixture</h2>
      <iframe
        title="Sandboxed synthetic hostile email"
        sandbox=""
        referrerpolicy="no-referrer"
        :srcdoc="sandboxDocument"
      />
    </section>
  </main>
</template>

<style>
:root {
  color: #1f2937;
  background: #f8fafc;
  font-family: system-ui, sans-serif;
}

body {
  margin: 0;
  min-width: 320px;
  min-height: 100vh;
}

main {
  max-width: 56rem;
  margin: 0 auto;
  padding: 2rem;
}

section {
  margin-block: 2rem;
}

button {
  margin-inline-end: 1rem;
}

iframe {
  display: block;
  width: 100%;
  min-height: 16rem;
  border: 1px solid #94a3b8;
  background: white;
}
</style>
