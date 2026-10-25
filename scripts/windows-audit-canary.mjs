import { constants } from "node:fs";
import { open } from "node:fs/promises";

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
