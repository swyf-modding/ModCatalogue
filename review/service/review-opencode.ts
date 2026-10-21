// The Jev review runner via OpenCode's Zen API.
//
// Reads prompt.md and facts.json from the work directory, sends them to Jev
// via OpenCode's System One API (POST /zen/v1/systemone), and writes
// verdict.json back to the work directory.
//
// Jev is a System One model: it takes unstructured state plus a set of typed
// questions and returns structured, typed decisions — exactly what a review
// needs. It works headless in a container with an API key.
//
// Plain TypeScript, run by Bun: no build step, no compile before it can start.

import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

async function main(): Promise<void> {
  const workDir = process.argv[2];
  if (!workDir) {
    console.error("usage: review-opencode.ts <work-dir>");
    process.exit(2);
  }

  const prompt = await readFile(join(workDir, "prompt.md"), "utf8");
  const facts = await readFile(join(workDir, "facts.json"), "utf8");

  const baseUrl = (process.env.OPENCODE_BASE_URL ?? "https://opencode.ai").replace(
    /\/+$/,
    "",
  );
  const apiKey = process.env.OPENCODE_API_KEY;
  if (!apiKey) {
    console.error("OPENCODE_API_KEY is not set");
    process.exit(1);
  }

  const model = process.env.REVIEW_MODEL ?? "jev-1.13-free";

  // The state is the review task plus the facts read from the mod's release
  // and source. Jev answers the questions below from this state.
  const state =
    prompt +
    "\n\n---\n\n## Facts (read from the mod's release and source)\n" +
    facts;

  const questions = {
    verdict: {
      type: "enum",
      instructions:
        "ok if the catalogue entry is consistent and honestly described. " +
        "unsure if anything does not add up or you cannot tell. " +
        "refuse if something in it should stop a player installing it.",
    },
    reason: {
      type: "string",
      instructions: "One sentence explaining the verdict.",
    },
    read: {
      type: "array",
      instructions:
        "List of files read to reach this verdict, from ./mod and ./source.",
    },
  };

  const body = JSON.stringify({
    model,
    state,
    questions,
  });

  const response = await fetch(`${baseUrl}/zen/v1/systemone`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const text = await response.text().catch(() => "");
    console.error(`OpenCode API error ${response.status}: ${text}`);
    process.exit(1);
  }

  const data = await response.json();

  // Jev returns structured output matching the questions schema: verdict,
  // reason, read. It may be at the top level or nested under a result key.
  const result =
    data.verdict !== undefined
      ? data
      : data.result ?? data.decision ?? data.answers ?? data;

  const verdictStr = result.verdict;
  if (verdictStr !== "ok" && verdictStr !== "unsure" && verdictStr !== "refuse") {
    console.error("Jev did not return a valid verdict:");
    console.error(JSON.stringify(result, null, 2));
    process.exit(1);
  }

  await writeFile(
    join(workDir, "verdict.json"),
    JSON.stringify(
      {
        verdict: verdictStr,
        reason: typeof result.reason === "string" ? result.reason : "",
        read: Array.isArray(result.read)
          ? result.read.filter((r: unknown) => typeof r === "string")
          : undefined,
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
