// The OpenCode review runner.
//
// Drives the OpenCode CLI headlessly: hands it the review prompt and facts,
// reads whatever it prints, and extracts a verdict JSON object to write to
// verdict.json.
//
// OpenCode is an interactive terminal agent by design, so this is a thin
// wrapper around its CLI. It works headless as long as OpenCode can reach its
// model provider - for free models like Jev that means OPENROUTER_API_KEY,
// which OpenCode reads from the environment the same way its own docs describe.
//
// Plain TypeScript, run by Bun: no build step, no compile before it can start.

import { execFile } from "node:child_process";
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

  const apiKey = process.env.OPENROUTER_API_KEY;
  if (!apiKey) {
    console.error("OPENROUTER_API_KEY is not set (OpenCode needs it for free models)");
    process.exit(1);
  }

  const model = process.env.REVIEW_MODEL ?? "openrouter/jev";

  // OpenCode is handed the full task on stdin/stdout and asked to answer once.
  // TERM=dumb and NO_COLOR=1 keep its output parseable.
  const input = [
    "You are reviewing a mod submission for a public catalogue. Read only - do not modify, build, run, install or test anything.",
    "",
    prompt,
    "",
    "## Facts (read from the mod's release and source)",
    facts,
    "",
    "Answer with JSON only, nothing else:",
    '{ "verdict": "ok" | "unsure" | "refuse", "reason": "one sentence", "read": ["files you read"] }',
  ].join("\n");

  const output = await new Promise<string>((resolve, reject) => {
    execFile(
      "opencode",
      [input],
      {
        cwd: workDir,
        timeout: 15 * 60 * 1000,
        maxBuffer: 16 * 1024 * 1024,
        env: {
          ...process.env,
          OPENROUTER_API_KEY: apiKey,
          TERM: "dumb",
          NO_COLOR: "1",
        },
      },
      (error, stdout, stderr) => {
        // OpenCode exits with a status, but its output is what matters.
        resolve(`${stdout ?? ""}\n${stderr ?? ""}`);
      },
    );
  });

  // Keep the transcript for debugging.
  await writeFile(join(workDir, "agent-output.txt"), output, "utf8");

  // OpenCode should answer with JSON only; if it narrates, take the last JSON object.
  const candidates = [...output.matchAll(/\{[^{}]*"verdict"[^{}]*\}/gs)].map((m) => m[0]);
  let verdict: { verdict?: string; reason?: string; read?: string[] } | null = null;
  for (let i = candidates.length - 1; i >= 0; i--) {
    try {
      const parsed = JSON.parse(candidates[i]);
      if (parsed && typeof parsed.verdict === "string") {
        verdict = parsed;
        break;
      }
    } catch {
      // Not the one. Keep looking.
    }
  }

  if (!verdict) {
    console.error("OpenCode did not answer with a verdict");
    console.error(output);
    process.exit(1);
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
