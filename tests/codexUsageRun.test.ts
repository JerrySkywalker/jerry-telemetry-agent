import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it, vi } from "vitest";
import { runOnce } from "../src/main.js";
import { readState } from "../src/telemetry/state.js";
import { tempDir, testConfig } from "./helpers.js";

describe("Codex usage runOnce sinks and last-good", () => {
  it("writes stdout, file, latest, and last-good snapshots for fallback", async () => {
    const dir = await tempDir();
    const latest = path.join(dir, "latest.json");
    const out = path.join(dir, "out.safe.snapshot.json");
    await writeFile(latest, JSON.stringify({ captured_at: "2026-06-08T00:00:00.000Z", status: "ok", account_id: "raw" }));
    const writeSpy = vi.spyOn(process.stdout, "write").mockImplementation(() => true);

    await runOnce(
      testConfig({
        collectorMode: "codex-cli-status-fallback",
        outputModes: ["stdout", "file"],
        codexStatusLatestPath: latest,
        outputFile: out,
        usageLatestPath: path.join(dir, "latest.safe.snapshot.json"),
        usageLastGoodPath: path.join(dir, "last-good.safe.snapshot.json"),
        statePath: path.join(dir, "state.json")
      })
    );

    expect(writeSpy).toHaveBeenCalled();
    writeSpy.mockRestore();
    expect(JSON.parse(await readFile(out, "utf8"))).toMatchObject({ type: "codex.usage.snapshot", source: "codex_cli_status_capture" });
    expect(JSON.parse(await readFile(path.join(dir, "last-good.safe.snapshot.json"), "utf8"))).toMatchObject({ status: { ok: true } });
  });

  it("marks backend failure stale when a last-good usage exists and preserves last-good file", async () => {
    const dir = await tempDir();
    const codexHome = path.join(dir, "codex");
    await mkdir(codexHome);
    await writeFile(path.join(codexHome, "auth.json"), "{}");
    const lastGood = path.join(dir, "last-good.safe.snapshot.json");
    await writeFile(lastGood, JSON.stringify({ status: { ok: true } }));

    await runOnce(
      testConfig({
        outputModes: ["file"],
        codexHome,
        outputFile: path.join(dir, "out.safe.snapshot.json"),
        usageLatestPath: path.join(dir, "latest.safe.snapshot.json"),
        usageLastGoodPath: lastGood,
        statePath: path.join(dir, "state.json")
      })
    );

    const latest = JSON.parse(await readFile(path.join(dir, "latest.safe.snapshot.json"), "utf8"));
    expect(latest).toMatchObject({
      status: {
        ok: false,
        error_code: "codex_auth_unavailable",
        stale: true,
        auth_source: "auth_file",
        auth_file_present: true
      }
    });
    expect(JSON.stringify(latest)).not.toContain("auth.json");
    expect(await readFile(lastGood, "utf8")).toContain("\"ok\":true");
  });

  it("writes a safe degraded usage snapshot when the auth file is missing", async () => {
    const dir = await tempDir();
    const latestPath = path.join(dir, "latest.safe.snapshot.json");

    await runOnce(
      testConfig({
        outputModes: ["file"],
        codexHome: path.join(dir, "missing-codex-home"),
        outputFile: path.join(dir, "out.safe.snapshot.json"),
        usageLatestPath: latestPath,
        usageLastGoodPath: path.join(dir, "last-good.safe.snapshot.json"),
        statePath: path.join(dir, "state.json")
      })
    );

    const latestText = await readFile(latestPath, "utf8");
    const latest = JSON.parse(latestText);
    expect(latest).toMatchObject({
      status: {
        ok: false,
        error_code: "codex_auth_unavailable",
        message: "Codex auth unavailable",
        auth_source: "auth_file",
        auth_file_present: false
      }
    });
    expect(latestText).not.toContain("auth.json");
    expect(latestText).not.toContain(".codex");
  });

  it("wraps http sink as codex.usage.snapshot envelope", async () => {
    const dir = await tempDir();
    const latest = path.join(dir, "latest.json");
    await writeFile(latest, JSON.stringify({ captured_at: "2026-06-08T00:00:00.000Z", status: "ok" }));
    const seen: unknown[] = [];
    const server = (await import("node:http")).createServer((req, res) => {
      let body = "";
      req.on("data", (chunk) => {
        body += chunk;
      });
      req.on("end", () => {
        seen.push(JSON.parse(body));
        res.writeHead(204);
        res.end();
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing address");

    await runOnce(
      testConfig({
        collectorMode: "codex-cli-status-fallback",
        outputModes: ["http"],
        codexStatusLatestPath: latest,
        hubUrl: `http://127.0.0.1:${address.port}/telemetry`,
        usageLatestPath: path.join(dir, "latest.safe.snapshot.json"),
        usageLastGoodPath: path.join(dir, "last-good.safe.snapshot.json"),
        statePath: path.join(dir, "state.json"),
        spoolDir: path.join(dir, "spool")
      })
    );
    server.close();

    expect(seen[0]).toMatchObject({ event_type: "codex.usage.snapshot", payload: { type: "codex.usage.snapshot" } });
    expect((await readState(path.join(dir, "state.json"))).lastSuccessfulUsageAt).toBe("2026-06-08T00:00:00.000Z");
  });
});
