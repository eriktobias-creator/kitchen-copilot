import { timingSafeEqual } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Anthropic from "@anthropic-ai/sdk";
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { streamSSE } from "hono/streaming";
import { ask, AskRequest, describeError, EFFORT, MODEL } from "./assistant.js";
import { loadKnowledge } from "./knowledge.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = process.env.KNOWLEDGE_DIR ?? path.resolve(here, "..", "..");
const PORT = Number(process.env.PORT ?? 8787);
const APP_TOKEN = process.env.APP_TOKEN;

if (!APP_TOKEN || APP_TOKEN.length < 24) {
  console.error("Set APP_TOKEN to a random string of 24+ characters (the iPhone app sends it).");
  process.exit(1);
}

const STORE_TIMEZONE = process.env.STORE_TIMEZONE ?? "America/Chicago";

/** Store-local time, used when the caller (e.g. a Shortcut) doesn't send one. */
function storeTime(): string {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: STORE_TIMEZONE,
    weekday: "long",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date());
}

const client = new Anthropic();
const app = new Hono();

function authorized(header: string | undefined): boolean {
  const expected = Buffer.from(`Bearer ${APP_TOKEN}`);
  const given = Buffer.from(header ?? "");
  return given.length === expected.length && timingSafeEqual(given, expected);
}

app.get("/health", async (c) => {
  const k = await loadKnowledge(ROOT);
  return c.json({ ok: true, model: MODEL, effort: EFFORT, storeFiles: k.files });
});

app.post("/ask", async (c) => {
  if (!authorized(c.req.header("authorization"))) return c.json({ error: "unauthorized" }, 401);

  const parsed = AskRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: "bad request", issues: parsed.error.issues }, 400);

  // Re-read files per request so edits apply without a restart.
  const knowledge = await loadKnowledge(ROOT);

  return streamSSE(c, async (sse) => {
    const abort = new AbortController();
    sse.onAbort(() => abort.abort());
    try {
      const req = { ...parsed.data, localTime: parsed.data.localTime ?? storeTime() };
      for await (const ev of ask(client, knowledge, req, abort.signal)) {
        await sse.writeSSE({ event: ev.type, data: JSON.stringify(ev) });
      }
    } catch (error) {
      if (abort.signal.aborted) return;
      console.error(error);
      await sse.writeSSE({
        event: "error",
        data: JSON.stringify({ type: "error", message: describeError(error) }),
      });
    }
  });
});

/**
 * Plain-text version for iPhone Shortcuts: send {"question": "..."} and get
 * the whole answer back as text, ready for the "Speak Text" action.
 */
app.post("/ask/text", async (c) => {
  if (!authorized(c.req.header("authorization"))) return c.text("The app token doesn't match.", 401);

  const parsed = AskRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.text("I didn't catch a question.", 400);

  const knowledge = await loadKnowledge(ROOT);
  try {
    let answer = "";
    const req = { ...parsed.data, localTime: parsed.data.localTime ?? storeTime() };
    for await (const ev of ask(client, knowledge, req, c.req.raw.signal)) {
      if (ev.type === "delta") answer += ev.text;
    }
    return c.text(answer.trim() || "I don't have an answer for that.");
  } catch (error) {
    console.error(error);
    return c.text(describeError(error), 502);
  }
});

serve({ fetch: app.fetch, port: PORT }, (info) => {
  console.log(`Kitchen Copilot server on :${info.port} (model ${MODEL}, effort ${EFFORT})`);
});
