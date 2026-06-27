import http from "node:http";
import { describe, expect, it } from "vitest";
import { runHttpProbe, sanitizeProbeUrl } from "../src/collectors/probes/httpProbe.js";
import { runTcpProbe } from "../src/collectors/probes/tcpProbe.js";

describe("probe collectors", () => {
  it("reports healthy HTTP probes without response body leakage", async () => {
    const server = http.createServer((_req, res) => {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("raw body must not appear");
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing server address");

    const result = await runHttpProbe(
      { name: "local", url: `http://127.0.0.1:${address.port}/healthz?access_token=raw`, timeout_ms: 1000 },
      "2026-06-08T00:00:00.000Z"
    );
    server.close();

    expect(result).toMatchObject({ status: "healthy", status_code: 200, kind: "http" });
    expect(JSON.stringify(result)).not.toContain("raw body");
    expect(result.sanitized_url).not.toContain("access_token");
  });

  it("reports down HTTP probes safely", async () => {
    const result = await runHttpProbe({ name: "missing", url: "http://127.0.0.1:1/healthz", timeout_ms: 100 }, "2026-06-08T00:00:00.000Z");

    expect(result.status).toBe("down");
    expect(result.message).toBe("http probe failed");
  });

  it("redacts token-bearing HTTP URLs", () => {
    expect(sanitizeProbeUrl("http://user:pass@example.test/healthz?token=secret#frag")).toBe("http://example.test/healthz");
  });

  it("rejects invalid TCP ports and reports down targets safely", async () => {
    expect(() => runTcpProbe({ name: "bad", host: "127.0.0.1", port: 0 }, "2026-06-08T00:00:00.000Z")).toThrow(/port/);

    const result = await runTcpProbe({ name: "closed", host: "127.0.0.1", port: 1, timeout_ms: 100 }, "2026-06-08T00:00:00.000Z");
    expect(result).toMatchObject({ kind: "tcp", status: "down", port: 1 });
    expect(JSON.stringify(result)).not.toContain("ECONNREFUSED");
  });
});
