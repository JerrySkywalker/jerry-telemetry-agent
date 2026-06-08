import { redactCodexStatus } from "./redactCodexStatus.js";
import { validateCodexLatest } from "./validateCodexLatest.js";

export function parseCodexStatusPane(text: string, now = new Date()): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    captured_at: now.toISOString(),
    provider: "codex"
  };

  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;
    const match = line.match(/^([^:]+):\s*(.+)$/);
    if (!match) continue;
    const key = normalizeKey(match[1]);
    const value = match[2].trim();
    if (key === "token_usage") {
      payload[key] = parseTokenUsage(value);
    } else {
      payload[key] = value;
    }
  }

  const redacted = redactCodexStatus(payload);
  validateCodexLatest(redacted);
  return redacted;
}

function normalizeKey(input: string): string {
  return input.trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
}

function parseTokenUsage(value: string): Record<string, number> | string {
  const usage: Record<string, number> = {};
  for (const match of value.matchAll(/([a-z_]+)=([0-9]+)/gi)) {
    usage[match[1].toLowerCase()] = Number.parseInt(match[2], 10);
  }
  return Object.keys(usage).length > 0 ? usage : value;
}
