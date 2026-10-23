// The message a person reads, which is the half of the reviewer that leaves
// the container. It is read by the submitter and by the maintainer, so these
// tests are about plain language, not JSON: what the code did, what happens
// next, and nothing about the models behind the answer.

import { describe, expect, test } from "bun:test";
import { composeVerdict, type Decision, type Triage } from "./review-opencode";

const calm: Triage = { ok: true, tier: "low", flagged: [] };

const matches: Decision = {
  verdict: "ok",
  reason: "The summary matches what the code does.",
  model: "deepseek-v4.1-flash",
};

const decide = (decision: Decision | null, overrides: Partial<Parameters<typeof composeVerdict>[0]> = {}) =>
  composeVerdict({
    decision,
    triage: calm,
    incompleteReasons: [],
    coverage: "All 3 source files were read.",
    ...overrides,
  });

describe("the review message", () => {
  test("a pass reads as a message for a person", () => {
    const { verdict, reason } = decide(matches);
    expect(verdict).toBe("ok");
    expect(reason).toBe(
      "The summary matches what the code does. It is ready to be listed. All 3 source files were read.",
    );
  });

  test("never names the models that answered", () => {
    for (const decision of [
      matches,
      { ...matches, verdict: "unsure" as const, reason: "Something does not add up.", model: "glm-5.3-flash" },
      { ...matches, verdict: "refuse" as const, reason: "It installs another mod.", model: "jev-1.13-free" },
    ]) {
      const { reason } = decide(decision);
      expect(reason).not.toContain(decision.model);
      expect(reason.toLowerCase()).not.toContain("deepseek");
      expect(reason.toLowerCase()).not.toContain("glm");
      expect(reason.toLowerCase()).not.toContain("jev");
    }
  });

  test("code that was only partly read is held, and says why in plain words", () => {
    const { verdict, reason } = decide(matches, {
      incompleteReasons: ["2 source files could not be read", "1 file was only partly read"],
      coverage: "3 of 6 source files were read.",
    });
    expect(verdict).toBe("unsure");
    expect(reason).toContain(
      "Not everything could be checked automatically: 2 source files could not be read and 1 file was only partly read.",
    );
    expect(reason).toContain("A maintainer will take a look before it is listed.");
  });

  test("an unfinished review still tells the submitter what happens next", () => {
    const { verdict, reason } = decide(null, {
      triage: { ok: false, tier: "unknown", flagged: [] },
    });
    expect(verdict).toBe("unsure");
    expect(reason).toBe(
      "The automated review could not be completed, so a maintainer will take a look before this is listed. All 3 source files were read.",
    );
  });

  test("a refusal says the mod was not listed", () => {
    const { verdict, reason } = decide(
      {
        verdict: "refuse",
        reason: "It downloads and runs another program.",
        model: "deepseek-v4.1-flash",
      },
      { triage: { ...calm, tier: "medium" } },
    );
    expect(verdict).toBe("refuse");
    expect(reason).toBe(
      "It downloads and runs another program. It was not listed. All 3 source files were read.",
    );
  });

  test("a refusal the first pass did not expect goes to a person", () => {
    const { verdict, reason } = decide(
      { verdict: "refuse", reason: "It downloads and runs another program.", model: "deepseek-v4.1-flash" },
      { triage: { ...calm, tier: "low" } },
    );
    expect(verdict).toBe("unsure");
    expect(reason).toContain("The answer was not clear-cut, so it needs a person to decide.");
  });
});
