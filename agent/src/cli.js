import { runCycle } from "./agent.js";
import { readPortfolio, recentEvents } from "./portfolio.js";
import { handleChat, renderResults } from "./chat.js";
import { writeSnapshot } from "./snapshot.js";

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === "cycle") {
  const r = await runCycle();
  console.log(JSON.stringify({ choice: r.decision.choice, memo: r.decision.memo, model: r.decision.model, preflight: r.preflight, result: r.result }, null, 2));
  try { console.log("snapshot", JSON.stringify(await writeSnapshot())); } catch (e) { console.log("snapshot failed:", e.shortMessage || e.message); }
} else if (cmd === "snapshot") {
  console.log(JSON.stringify(await writeSnapshot()));
} else if (cmd === "status") {
  const p = await readPortfolio();
  console.log(JSON.stringify({ ...p, riskRaw: undefined, recent: await recentEvents(8) }, null, 2));
} else if (cmd === "chat") {
  const r = await handleChat(rest.join(" "));
  console.log(r.reply + "\n" + renderResults(r.results));
} else {
  console.log("usage: node src/cli.js cycle | status | chat <message>");
}
process.exit(0);
