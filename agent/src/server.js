import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { ROOT, PORT, loadPrefs } from "./config.js";
import { runCycle } from "./agent.js";
import { handleChat, renderResults } from "./chat.js";
import { readPortfolio, recentEvents } from "./portfolio.js";
import { gatherSignals } from "./signals.js";
import { ethers } from "ethers";

const MIME = { ".html": "text/html", ".js": "text/javascript", ".json": "application/json", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml" };
const json = (res, code, obj) => { res.writeHead(code, { "content-type": "application/json", "access-control-allow-origin": "*", "access-control-allow-headers": "content-type" }); res.end(JSON.stringify(obj, (k, v) => (typeof v === "bigint" ? v.toString() : v))); };
const body = (req) => new Promise((ok) => { let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => ok(b ? JSON.parse(b) : {})); });

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://x");
    if (req.method === "OPTIONS") return json(res, 204, {});
    if (url.pathname === "/api/chat" && req.method === "POST") {
      const { message } = await body(req);
      const r = await handleChat(String(message || ""));
      return json(res, 200, { ...r, text: [r.reply, renderResults(r.results)].filter(Boolean).join("\n") });
    }
    if (url.pathname === "/api/cycle" && req.method === "POST") return json(res, 200, await runCycle());
    if (url.pathname === "/api/state") return json(res, 200, { portfolio: { ...(await readPortfolio()), riskRaw: undefined }, events: await recentEvents(20), prefs: loadPrefs() });
    if (url.pathname === "/api/signals") return json(res, 200, await gatherSignals(ethers.parseEther("0.01")));
    if (url.pathname === "/api/health") return json(res, 200, { ok: true, agent: true });
    // static: dashboard at /, plus /decisions/*.json and /deployments.json
    if (url.pathname === "/" || url.pathname === "/dashboard") { res.writeHead(302, { location: "/dashboard/" + url.search }); return res.end(); }
    let p = url.pathname.endsWith("/") ? url.pathname + "index.html" : url.pathname;
    const file = path.join(ROOT, path.normalize(p).replace(/^(\.\.[/\\])+/, ""));
    if (!file.startsWith(ROOT) || file.includes(".env") || !fs.existsSync(file) || fs.statSync(file).isDirectory()) return json(res, 404, { error: "not found" });
    res.writeHead(200, { "content-type": MIME[path.extname(file)] || "application/octet-stream", "access-control-allow-origin": "*" });
    fs.createReadStream(file).pipe(res);
  } catch (e) {
    json(res, 500, { error: e.shortMessage || e.message });
  }
});
server.listen(PORT, () => console.log(`Leash agent + dashboard on http://localhost:${PORT}`));

if (process.env.AUTO === "1") {
  const loop = async () => {
    try { await runCycle(); } catch (e) { console.error("[cycle error]", e.shortMessage || e.message); }
    setTimeout(loop, loadPrefs().loopSeconds * 1000);
  };
  loop();
}
