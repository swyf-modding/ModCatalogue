// The Freebuff CLI, driven without a person.
//
// The CLI is a terminal program, and the documentation is clear that it has
// no headless mode: it is an interactive terminal UI with no prompt
// argument. So it is given what it needs - a terminal, and the prompt on
// its standard input - and what comes back is read.
//
// If this ever stops working, the fix is here and nowhere else: the rest of
// the service only knows that some program leaves a verdict.json behind.
//
// Plain TypeScript, run by Bun.
//
// Two things are worth knowing about how it is driven:
//
//   - `script` gives the program a pty. A program that expects a terminal
//     and is handed a pipe does not always behave, and this is the standard
//     way of giving it one.
//   - The prompt is fed on standard input and the session is ended with
//     ctrl-d, so the agent reads the task, answers, and stops.

import { execFile } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { extractVerdict } from "./review";

async function main(): Promise<void> {
  const workDir = process.argv[2];
  if (!workDir) {
    console.error("usage: review-freebuff.ts <work-dir>");
    process.exit(2);
  }

  const prompt = await readFile(join(workDir, "prompt.md"), "utf8");

  // The agent is told what to do in the prompt, and the model is chosen with
  // the flag the CLI documents. An empty model means the CLI's own default.
  const model = process.env.REVIEW_MODEL ? ` --model ${process.env.REVIEW_MODEL}` : "";

  // `script` is given the prompt on standard input and ends the session with
  // ctrl-d, so the agent reads the task, answers and stops.
  const command = `freebuff${model}`;

  const output = await new Promise<string>((resolve, reject) => {
    execFile(
      "script",
      ["-qec", command, "/dev/null"],
      {
        cwd: workDir,
        timeout: 15 * 60 * 1000,
        maxBuffer: 16 * 1024 * 1024,
        env: { ...process.env, TERM: "dumb", NO_COLOR: "1" },
      },
      (error, stdout, stderr) => {
        // The agent exits with a status, but the session is what matters and it
        // is read either way: a refusal to answer is itself a refusal.
        resolve(`${stdout ?? ""}\n${stderr ?? ""}`);
      },
    );
  });

  // The transcript is kept: when a review is refused, the reason should be
  // readable, and the agent's own words are the reason.
  await writeFile(join(workDir, "agent-output.txt"), output, "utf8");

  const verdict = extractVerdict(output);
  if (!verdict) {
    console.error("the agent did not answer with a verdict");
    process.exit(1);
  }

  await writeFile(join(workDir, "verdict.json"), JSON.stringify(verdict, null, 2), "utf8");
  process.exit(0);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
