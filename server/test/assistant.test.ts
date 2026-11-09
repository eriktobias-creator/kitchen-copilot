import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { AskRequest, buildMessages } from "../src/assistant.js";
import { loadKnowledge } from "../src/knowledge.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

describe("loadKnowledge", () => {
  it("loads instructions plus store files in order, skipping README", async () => {
    const k = await loadKnowledge(root);
    expect(k.files).toEqual(["01-store-profile.md", "02-par-levels.csv"]);
    expect(k.system[0]!.text).toContain("Kitchen Leader");
    expect(k.system[1]!.text).toContain('<store_file name="02-par-levels.csv">');
    expect(k.system[1]!.cache_control).toEqual({ type: "ephemeral", ttl: "1h" });
  });

  it("is deterministic so the prompt cache hits", async () => {
    const [a, b] = await Promise.all([loadKnowledge(root), loadKnowledge(root)]);
    expect(JSON.stringify(a.system)).toBe(JSON.stringify(b.system));
  });
});

describe("buildMessages", () => {
  it("adds time prefix and ends with the question", () => {
    const req = AskRequest.parse({ question: "how much chicken", localTime: "Saturday 10:40 AM" });
    const msgs = buildMessages(req);
    expect(msgs).toHaveLength(1);
    expect(JSON.stringify(msgs[0])).toContain("(Saturday 10:40 AM) how much chicken");
  });

  it("repairs broken history so roles alternate starting with user", () => {
    const req = AskRequest.parse({
      question: "next?",
      history: [
        { role: "assistant", text: "orphan" },
        { role: "user", text: "a" },
        { role: "user", text: "dup" },
        { role: "assistant", text: "b" },
        { role: "user", text: "dangling" },
      ],
    });
    const roles = buildMessages(req).map((m) => m.role);
    expect(roles).toEqual(["user", "assistant", "user"]);
  });

  it("appends a rush-mode system message after the question", () => {
    const msgs = buildMessages(AskRequest.parse({ question: "who's on grill", rush: true }));
    expect(msgs.map((m) => m.role)).toEqual(["user", "system"]);
  });

  it("puts an image before the text", () => {
    const msgs = buildMessages(AskRequest.parse({ question: "is this pan low", imageJpegBase64: "AAAA" }));
    const content = msgs[0]!.content as { type: string }[];
    expect(content.map((b) => b.type)).toEqual(["image", "text"]);
  });
});
