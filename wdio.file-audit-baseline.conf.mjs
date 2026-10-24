import { config as securityConfig } from "./wdio.security.conf.mjs";

export const config = {
  ...securityConfig,
  specs: ["./tests/security/file-audit.baseline.mjs"],
};
