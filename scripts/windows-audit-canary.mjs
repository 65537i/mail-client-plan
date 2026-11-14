import { constants } from "node:fs";
import { mkdtemp, open, realpath } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export async function createWindowsAuditDirectory(temporaryRoot = os.tmpdir()) {
  const canonicalRoot = await realpath(temporaryRoot);
  return mkdtemp(path.join(canonicalRoot, "mail-client-file-audit-"));
}

export async function createWindowsAuditCanary(filePath) {
  const content = "Synthetic file-access canary; no user data.\n";
  const file = await open(
    filePath,
    constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_SYNC,
    0o600,
  );
  try {
    await file.writeFile(content);
    await file.sync();
  } finally {
    await file.close();
  }
  return Buffer.byteLength(content);
}
