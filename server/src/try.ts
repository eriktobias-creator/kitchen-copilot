// Ask the assistant from the terminal to test prompt/store changes:
//   npm run try -- "how much chicken for Saturday lunch"
//   npm run try -- --rush "someone called out on grill"
import Anthropic from "@anthropic-ai/sdk";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ask, AskRequest } from "./assistant.js";
import { loadKnowledge } from "./knowledge.js";

const args = process.argv.slice(2);
const rush = args.includes("--rush");
const question = args.filter((a) => a !== "--rush").join(" ");
if (!question) {
  console.error('Usage: npm run try -- [--rush] "your question"');
  process.exit(1);
}
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const knowledge = await loadKnowledge(root);
const started = Date.now();
let first = 0;
for await (const ev of ask(new Anthropic(), knowledge, AskRequest.parse({ question, rush }))) {
  if (ev.type === "delta") {
    if (!first) first = Date.now();
    process.stdout.write(ev.text);
  } else if (ev.type === "done") {
    console.log(`\n\n[first words ${first - started} ms, total ${Date.now() - started} ms, ${ev.servedBy}, ${ev.stopReason}]`);
  }
}
