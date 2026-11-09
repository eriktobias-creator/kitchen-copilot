import Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import type { Knowledge } from "./knowledge.js";

export const MODEL = process.env.KC_MODEL ?? "claude-opus-5-5";
/** Voice needs a fast first word; raise to "medium" for planning-heavy use. */
export const EFFORT = (process.env.KC_EFFORT ?? "low") as "low" | "medium" | "high";
/** How many earlier turns the phone may send back as context. */
export const MAX_HISTORY_TURNS = 20;

export const AskRequest = z.object({
  question: z.string().trim().min(1).max(4000),
  history: z
    .array(z.object({ role: z.enum(["user", "assistant"]), text: z.string().max(8000) }))
    .max(MAX_HISTORY_TURNS * 2)
    .default([]),
  rush: z.boolean().default(false),
  /** e.g. "Saturday 11:05 AM" from the phone's clock. */
  localTime: z.string().max(64).optional(),
  /** Optional JPEG from the glasses or phone camera, base64. */
  imageJpegBase64: z.string().max(8_000_000).optional(),
});
export type AskRequest = z.infer<typeof AskRequest>;

export function buildMessages(req: AskRequest): Anthropic.Beta.BetaMessageParam[] {
  const messages: Anthropic.Beta.BetaMessageParam[] = [];

  // Keep only well-formed alternating history, oldest first, ending on an
  // assistant turn so the new question is the next user turn.
  const history = req.history.slice(-MAX_HISTORY_TURNS * 2).filter((t) => t.text.trim());
  for (const turn of history) {
    const last = messages[messages.length - 1];
    if (last && last.role === turn.role) continue;
    if (!last && turn.role !== "user") continue;
    messages.push({ role: turn.role, content: turn.text });
  }
  if (messages.length > 0 && messages[messages.length - 1]!.role === "user") messages.pop();

  const prefix = req.localTime ? `(${req.localTime}) ` : "";
  const content: Anthropic.Beta.BetaContentBlockParam[] = [];
  if (req.imageJpegBase64) {
    content.push({
      type: "image",
      source: { type: "base64", media_type: "image/jpeg", data: req.imageJpegBase64 },
    });
  }
  content.push({ type: "text", text: prefix + req.question });
  messages.push({ role: "user", content });

  if (req.rush) {
    // Mid-conversation system message: adds the instruction without
    // invalidating the cached prompt prefix.
    messages.push({ role: "system", content: "Rush mode: answer in one short spoken line." });
  }
  return messages;
}

export type AssistantEvent =
  | { type: "delta"; text: string }
  | { type: "done"; stopReason: string | null; servedBy: string }
  | { type: "error"; message: string };

/** Streams the spoken answer as text chunks. */
export async function* ask(
  client: Anthropic,
  knowledge: Knowledge,
  req: AskRequest,
  signal?: AbortSignal,
): AsyncGenerator<AssistantEvent> {
  const stream = client.beta.messages.stream(
    {
      model: MODEL,
      max_tokens: 16000,
      system: knowledge.system,
      messages: buildMessages(req),
      output_config: { effort: EFFORT },
      // If a safety classifier misfires on a kitchen question (knives,
      // chemicals, burns), retry on the recommended model instead of failing.
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
    },
    { signal },
  );

  let sawText = false;
  for await (const event of stream) {
    if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
      sawText = true;
      yield { type: "delta", text: event.delta.text };
    }
  }

  const final = await stream.finalMessage();
  if (final.stop_reason === "refusal" && !sawText) {
    yield {
      type: "delta",
      text: "I can't help with that one. Check with Vanessa.",
    };
  }
  yield { type: "done", stopReason: final.stop_reason, servedBy: final.model };
}

export function describeError(error: unknown): string {
  if (error instanceof Anthropic.AuthenticationError) return "The server's Claude API key is wrong.";
  if (error instanceof Anthropic.RateLimitError) return "Too many requests. Try again in a few seconds.";
  if (error instanceof Anthropic.BadRequestError) return "The request was rejected. Check the server logs.";
  if (error instanceof Anthropic.APIConnectionError) return "Can't reach Claude right now.";
  if (error instanceof Anthropic.APIError) return `Claude error ${error.status ?? ""}.`.trim();
  return "Something went wrong on the server.";
}
