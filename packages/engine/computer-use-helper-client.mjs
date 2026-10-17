import { randomUUID } from "node:crypto";
import { readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

export async function requestComputerUseHelper(
  commandDirectory,
  action,
  payload = {},
  { timeoutMs = 3_000, pollMs = 25 } = {},
) {
  if (typeof commandDirectory !== "string" || !commandDirectory.trim()) {
    throw new Error("The Computer Use helper command directory is unavailable.");
  }
  const id = randomUUID();
  const requestPath = join(commandDirectory, `request-${id}.json`);
  const temporaryPath = `${requestPath}.tmp`;
  const responsePath = join(commandDirectory, `response-${id}.json`);

  try {
    await writeFile(temporaryPath, JSON.stringify({ id, action, ownerProcessID: process.pid, ...payload }), { mode: 0o600 });
    await rename(temporaryPath, requestPath);
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const response = JSON.parse(await readFile(responsePath, "utf8"));
        if (response.id !== id) {
          throw new Error("The Computer Use helper returned a mismatched response.");
        }
        return response;
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
      await new Promise((resolve) => setTimeout(resolve, pollMs));
    }
    throw new Error(`Computer Use helper action ${action} timed out.`);
  } finally {
    await Promise.all([
      rm(temporaryPath, { force: true }),
      rm(requestPath, { force: true }),
      rm(responsePath, { force: true }),
    ]).catch(() => undefined);
  }
}
