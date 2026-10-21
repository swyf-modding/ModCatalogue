// The Jev review runner.
//
// Reads prompt.md and facts.json from the work directory, sends them to Jev
// via OpenRouter, and writes verdict.json back to the work directory.
//
// Jev is a System One model: it takes unstructured text plus a set of
// questions and returns structured, typed decisions — exactly what a review
// needs. It is accessed through OpenRouter, so it works headless in a
// container with an API key (OPENROUTER_API_KEY), unlike Freebuff which
// requires interactive browser login.
//
// Plain TypeScript, run by Bun: no build step, no compile before it can start.

import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

async function main(): Promise<void> {
  const workDir = process.argv[2];
  if (!workDir) {
    console.error("usage: review-jev.ts <work-dir>");
    process.exit(2);
  }

  const prompt = await readFile(join(workDir, "prompt.md"), "utf8");
  const facts = await readFile(join(workDir, "facts.json"), "utf8");

  const apiKey = process.env.OPENROUTER_API_KEY;
  if (!apiKey) {
    console.error("OPENROUTER_API_KEY is not set");
    process.exit(1);
  }

  // Jev is reached through OpenRouter; the model is chosen with REVIEW_MODEL.
  const model = process.env.REVIEW_MODEL ?? "typesafe/jev";

  const body = JSON.stringify({
    model,
    messages: [
      {
        role: "system",
        content:
          "You are Jev, a structured decision model. Return typed decisions only — no prose, no narration.",
      },
      {
        role: "user",
        content:
          prompt +
          "\n\n---\n\n## Facts (read from the mod's release and source)\n" +
          facts,
      },
    ],
    // Ask for structured JSON output so the answer is machine-readable.
    response_format: { type: "json_object" },
  });

  const response = await fetch(
    "https://openrouter.ai/api/v1/chat/completions",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/swyf-modding/ModCatalogue",
        "X-Title": "swyf-modding-review",
      },
      body,
    },
  );

  if (!response.ok) {
    const text = await response.text().catch(() => "");
    console.error(`Jev API error ${response.status}: ${text}`);
    process.exit(1);
  }

  const data = await response.json();
  const content = data.choices?.[0]?.message?.content ?? "";

  // Jev returns structured JSON; parse it as a verdict.
  let verdict: { verdict?: string; reason?: string; read?: string[] };
  try {
    verdict = JSON.parse(content);
  } catch {
    // Fall back: extract the last JSON object from the response.
    const match = content.match(/\{[^{}]*"verdict"[^{}]*\}/);
    if (!match) {
      console.error("Jev did not return a structured verdict");
      console.error(content);
      process.exit(1);
    }
    verdict = JSON.parse(match[0]);
  }

  await writeFile(
    join(workDir, "verdict.json"),
    JSON.stringify(verdict, null, 2),
    "utf8",
  );

  process.exit(0);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
