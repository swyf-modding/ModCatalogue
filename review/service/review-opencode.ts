// The OpenCode review runner.
//
// Reads prompt.md and facts.json from the work directory, sends them to an
// OpenCode instance via /api/experimental/generate, and writes verdict.json
// back to the work directory.
//
// OpenCode's HTTP API is experimental and session-based. The operator pairs
// once (POST /api/pair, then GET /auth/connect/{code} with Accept: JSON) to
// obtain a session token, which is passed as OPENCODE_API_TOKEN. The model is
// chosen with REVIEW_MODEL.
//
// Plain TypeScript, run by Bun: no build step, no compile before it can start.

import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

/** Find the last JSON object in text that contains a "verdict" field. */
function extractVerdictFromText(text: string): { verdict: string; reason: string; read?: string[] } | null {
  // Walk the text tracking brace depth so we capture whole JSON objects even
  // when the model narrates around them.
  const candidates: string[] = [];
  let depth = 0;
  let start = -1;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "{") {
      if (depth === 0) start = i;
      depth++;
    } else if (text[i] === "}") {
      depth--;
      if (depth === 0 && start >= 0) {
        candidates.push(text.slice(start, i + 1));
        start = -1;
      }
    }
  }

  // Try from last to first: a narrating model may emit several JSON objects;
  // the last one is most likely to be the considered answer.
  for (let i = candidates.length - 1; i >= 0; i--) {
    try {
      const parsed = JSON.parse(candidates[i]) as { verdict?: unknown; reason?: unknown; read?: unknown };
      if (typeof parsed.verdict !== "string") continue;

      return {
        verdict: parsed.verdict,
        reason: typeof parsed.reason === "string" ? parsed.reason : "",
        read: Array.isArray(parsed.read) ? parsed.read.filter((r) => typeof r === "string") : undefined,
      };
    } catch {
      // Not valid JSON. Keep looking.
    }
  }

  return null;
}

async function main(): Promise<void> {
  const workDir = process.argv[2];
  if (!workDir) {
    console.error("usage: review-opencode.ts <work-dir>");
    process.exit(2);
  }

  const prompt = await readFile(join(workDir, "prompt.md"), "utf8");
  const facts = await readFile(join(workDir, "facts.json"), "utf8");

  const baseUrl = (process.env.OPENCODE_BASE_URL ?? "http://localhost:3456").replace(/\/+$/, "");
  const apiToken = process.env.OPENCODE_API_TOKEN;
  if (!apiToken) {
    console.error("OPENCODE_API_TOKEN is not set");
    console.error("Pair once: POST /api/pair, then GET /auth/connect/<code> with Accept: application/json");
    process.exit(1);
  }

  // The model OpenCode should use (e.g. anthropic/claude-3-5-sonnet).
  const model = process.env.REVIEW_MODEL ?? "anthropic/claude-3-5-sonnet";

  const body = JSON.stringify({
    prompt,
    model,
  });

  const response = await fetch(`${baseUrl}/api/experimental/generate`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiToken}`,
      "Content-Type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const text = await response.text().catch(() => "");
    console.error(`OpenCode API error ${response.status}: ${text}`);
    process.exit(1);
  }

  const data = await response.json() as { data?: { text?: string } };
  const content = data.data?.text ?? "";

  if (!content) {
    console.error("OpenCode returned an empty response");
    process.exit(1);
  }

  const verdict = extractVerdictFromText(content);
  if (!verdict) {
    console.error("OpenCode did not return a structured verdict");
    console.error(content);
    process.exit(1);
  }

  await writeFile(
    join(workDir, "verdict.json"),
    JSON.stringify(
      {
        verdict: verdict.verdict === "ok" || verdict.verdict === "refuse" ? verdict.verdict : "unsure",
        reason: typeof verdict.reason === "string" ? verdict.reason : "",
        read: Array.isArray(verdict.read) ? verdict.read.filter((r) => typeof r === "string") : undefined,
      },
      null,
      2,
    ),
    "utf8",
  );

  process.exit(0);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
