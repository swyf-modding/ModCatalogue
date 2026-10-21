// The pure half of the review, which is the half that can go wrong.
//
// Bun's test runner. These are the things that need a decision rather than a
// wire: what the agent is asked, how its answer is read, and what the service
// will not fetch.

import { describe, expect, test } from "bun:test";
import { buildPrompt, parseVerdict } from "./review";

const mod = {
  owner: "swyf-modding",
  repo: "AI-Backend",
  release: "v1.2.1",
  displayName: "AI Backend",
  summary: "Routes the game's AI calls to your own LLM.",
  files: [
    {
      fileName: "ScamWYF.AiBackend.dll",
      sha256: "a".repeat(64),
      capabilities: ["dynamic-code", "network"],
      bepInPlugin: ["guid | name | 1.2.1"],
    },
  ],
};

describe("the task the agent is given", () => {
  test("says to read and not to run", () => {
    const prompt = buildPrompt(mod);
    expect(prompt).toContain("Read only");
    expect(prompt.toLowerCase()).toContain("do not run");
    expect(prompt).toContain("Do not modify");
  });

  test("gives the agent the facts the scan found", () => {
    const prompt = buildPrompt(mod);
    expect(prompt).toContain("ScamWYF.AiBackend.dll");
    expect(prompt).toContain("a".repeat(64));
    expect(prompt).toContain("dynamic-code, network");
    expect(prompt).toContain("guid | name | 1.2.1");
  });

  test("points the agent at both the release and the source", () => {
    const prompt = buildPrompt(mod);
    expect(prompt).toContain("./mod");
    expect(prompt).toContain("./source");
  });

  test("asks for a shape the service can read", () => {
    const prompt = buildPrompt(mod);
    expect(prompt).toContain('"verdict"');
    expect(prompt).toContain("ok");
    expect(prompt).toContain("unsure");
    expect(prompt).toContain("refuse");
  });
});

describe("reading the answer", () => {
  test("accepts a clean verdict", () => {
    const verdict = parseVerdict(
      '{"verdict": "ok", "reason": "it matches", "read": ["Mod.cs"]}',
    );
    expect(verdict?.verdict).toBe("ok");
    expect(verdict?.reason).toBe("it matches");
    expect(verdict?.read).toEqual(["Mod.cs"]);
  });

  test("takes the last one when the agent narrates", () => {
    const verdict = parseVerdict(
      'I read the file.\n{"verdict": "ok", "reason": "a"}\nDone.\n{"verdict": "unsure", "reason": "b"}',
    );
    expect(verdict?.verdict).toBe("unsure");
  });

  test("an unrecognised verdict is unsure", () => {
    // The agent is told what to answer; if it answers something else, the
    // answer is not a pass.
    expect(parseVerdict('{"verdict": "looks fine", "reason": "ok"}')?.verdict).toBe("unsure");
    expect(parseVerdict('{"verdict": ""}')?.verdict).toBe("unsure");
  });

  test("no verdict at all is unsure, not ok", () => {
    expect(parseVerdict("")).toBeNull();
    expect(parseVerdict("not json at all")).toBeNull();
    expect(parseVerdict('{"reason": "missing the verdict"}')).toBeNull();
  });

  test("a refusal is kept as a refusal", () => {
    expect(parseVerdict('{"verdict": "refuse", "reason": "it installs other mods"}')?.verdict).toBe(
      "refuse",
    );
  });
});
