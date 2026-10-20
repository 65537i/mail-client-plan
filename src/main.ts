import { createApp } from "vue";
import App from "./App.vue";

if (import.meta.env.MODE === "security-test") {
  await import("@wdio/tauri-plugin");
}

createApp(App).mount("#app");
