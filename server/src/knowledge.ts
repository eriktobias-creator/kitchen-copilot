import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import type Anthropic from "@anthropic-ai/sdk";

const STORE_EXTENSIONS = new Set([".md", ".txt", ".csv"]);

export interface Knowledge {
  system: Anthropic.Beta.BetaTextBlockParam[];
  files: string[];
}

/**
 * Builds the system prompt: the assistant instructions, then every store file
 * in filename order. Output is deterministic for unchanged files, so the
 * prompt cache keeps hitting; editing a file just rebuilds it once.
 */
export async function loadKnowledge(rootDir: string): Promise<Knowledge> {
  const instructions = await readFile(path.join(rootDir, "prompt", "system.md"), "utf8");

  const storeDir = path.join(rootDir, "store");
  const names = (await readdir(storeDir))
    .filter((n) => STORE_EXTENSIONS.has(path.extname(n).toLowerCase()))
    .filter((n) => n.toLowerCase() !== "readme.md")
    .sort();

  const sections: string[] = [];
  for (const name of names) {
    const body = (await readFile(path.join(storeDir, name), "utf8")).trim();
    sections.push(`<store_file name="${name}">\n${body}\n</store_file>`);
  }

  const storeText =
    sections.length > 0
      ? `<store_files>\n${sections.join("\n\n")}\n</store_files>`
      : "<store_files>No store files uploaded yet.</store_files>";

  return {
    files: names,
    system: [
      { type: "text", text: instructions.trim() },
      // 1h cache: a shift has long gaps between questions; this keeps the
      // whole prompt cached across them.
      { type: "text", text: storeText, cache_control: { type: "ephemeral", ttl: "1h" } },
    ],
  };
}
