import { readFile } from "node:fs/promises";
import path from "node:path";
import type { Config } from "../../config.js";

export interface CodexAuth {
  accessToken: string;
  authPath: string;
}

export class CodexUsageCollectionError extends Error {
  constructor(
    readonly code:
      | "auth_json_missing"
      | "access_token_missing"
      | "http_401"
      | "http_403"
      | "http_404"
      | "http_429"
      | "http_5xx"
      | "network_error"
      | "schema_error",
    message: string
  ) {
    super(message);
  }
}

export function resolveAuthJsonPath(config: Pick<Config, "codexHome">): string {
  return path.join(config.codexHome, "auth.json");
}

export async function readCodexAuth(config: Pick<Config, "codexHome">): Promise<CodexAuth> {
  const authPath = resolveAuthJsonPath(config);
  let raw: string;
  try {
    raw = await readFile(authPath, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      throw new CodexUsageCollectionError("auth_json_missing", "Codex auth.json was not found");
    }
    throw error;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new CodexUsageCollectionError("schema_error", "Codex auth.json is not valid JSON");
  }

  const accessToken = findAccessToken(parsed);
  if (!accessToken) {
    throw new CodexUsageCollectionError("access_token_missing", "Codex auth.json does not contain a ChatGPT access token");
  }
  return { accessToken, authPath };
}

function findAccessToken(value: unknown): string | undefined {
  if (!value || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  if (typeof record.access_token === "string" && record.access_token.length > 0) return record.access_token;
  for (const item of Object.values(record)) {
    if (item && typeof item === "object") {
      const found = findAccessToken(item);
      if (found) return found;
    }
  }
  return undefined;
}
