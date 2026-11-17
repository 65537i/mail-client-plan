import { constants } from "node:fs";
import { mkdtemp, open, readdir, realpath, rm, stat } from "node:fs/promises";
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

export async function retainOnlyWindowsAuditBackingFile(temporaryDirectory, backingFile) {
  const resolvedDirectory = path.resolve(temporaryDirectory);
  const resolvedBackingFile = path.resolve(backingFile);
  if (path.dirname(resolvedBackingFile) !== resolvedDirectory) {
    throw new Error("Windows audit backing file must be inside its temporary directory");
  }

  const backingFileName = path.basename(resolvedBackingFile);
  const entries = await readdir(resolvedDirectory);
  if (!entries.includes(backingFileName)) {
    throw new Error("Windows audit backing file is missing");
  }
  if (!(await stat(resolvedBackingFile)).isFile()) {
    throw new Error("Windows audit backing file is not a file");
  }

  for (const entry of entries) {
    if (entry !== backingFileName) {
      await rm(path.join(resolvedDirectory, entry), { recursive: true, force: true });
    }
  }

  const remainingEntries = await readdir(resolvedDirectory);
  if (remainingEntries.length !== 1 || remainingEntries[0] !== backingFileName) {
    throw new Error("Windows audit temporary directory contains unexpected files");
  }
}
