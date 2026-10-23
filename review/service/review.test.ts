// The pure half of the review: what the agent is asked, how its answer is read, and what the
// service will not fetch. Bun's test runner, `bun test`.

import { describe, expect, test, afterEach } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildPrompt, getGitHub, headersForHost, parseVerdict, readVerdict } from "./review";
import { readStream } from "./review-opencode";

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

describe("what the agent left behind", () => {
  async function workspace(files: Record<string, string>): Promise<string> {
    const dir = await mkdtemp(join(tmpdir(), "swyf-verdict-test-"));
    for (const [name, content] of Object.entries(files)) {
      await writeFile(join(dir, name), content, "utf8");
    }
    return dir;
  }

  test("the file the agent wrote is the answer", async () => {
    const dir = await workspace({
      "verdict.json": '{"verdict": "ok", "reason": "it matches"}',
    });
    try {
      expect(readVerdict(dir)?.verdict).toBe("ok");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("a transcript does not overrule the file", async () => {
    // The agent wrote a verdict and then kept talking. The talk is not the answer.
    const dir = await workspace({
      "verdict.json": '{"verdict": "ok", "reason": "it matches"}',
      "agent-output.txt": 'I read the file.\n{"verdict": "unsure", "reason": "hmm"}\n',
    });
    try {
      expect(readVerdict(dir)?.verdict).toBe("ok");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("a transcript alone is still an answer", async () => {
    const dir = await workspace({
      "agent-output.txt": '{"verdict": "refuse", "reason": "no"}',
    });
    try {
      expect(readVerdict(dir)?.verdict).toBe("refuse");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("nothing at all is no answer", async () => {
    const dir = await workspace({});
    try {
      expect(readVerdict(dir)).toBeNull();
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});

describe("a streamed reply", () => {
  const encoder = new TextEncoder();
  const event = (delta: string) =>
    `data: ${JSON.stringify({ choices: [{ delta: { content: delta } }] })}\n\n`;

  async function streamed(...chunks: string[]): Promise<string> {
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
        controller.close();
      },
    });

    return readStream(
      new Response(stream, { headers: { "content-type": "text/event-stream" } }),
    );
  }

  test("is joined back together", async () => {
    expect(await streamed(event('{"verdict":"ok"}'), "data: [DONE]\n\n")).toBe('{"verdict":"ok"}');
  });

  test("survives a line split across two reads", async () => {
    // The reset this is protecting against happens mid-connection, so a chunk boundary is
    // routinely in the middle of a line rather than neatly after one.
    const body = event('{"verdict":"ok"}') + "data: [DONE]\n\n";
    const cut = Math.floor(body.length / 2);

    expect(await streamed(body.slice(0, cut), body.slice(cut))).toBe('{"verdict":"ok"}');
  });

  test("ignores keep-alives and anything that is not a chunk", async () => {
    expect(await streamed(": ping\n\n", "data: {not json}\n\n", event('{"verdict":"ok"}'))).toBe(
      '{"verdict":"ok"}',
    );
  });
});

describe("where the token goes", () => {
  const headers = {
    Accept: "application/vnd.github+json",
    "User-Agent": "swyf-modding-review",
    Authorization: "Bearer ghp_secret",
  };

  test("github gets the token", () => {
    expect(headersForHost(headers, "api.github.com").Authorization).toBe("Bearer ghp_secret");
    expect(headersForHost(headers, "github.com").Authorization).toBe("Bearer ghp_secret");
  });

  test("anybody else does not", () => {
    // A release asset redirects to a CDN. The token has no business going there.
    const sent = headersForHost(headers, "objects.githubusercontent.com");
    expect(sent.Authorization).toBeUndefined();
    expect(sent["User-Agent"]).toBe("swyf-modding-review");
  });

  test("the headers that are sent are not the ones that were given", () => {
    headersForHost(headers, "elsewhere.example");
    expect(headers.Authorization).toBe("Bearer ghp_secret");
  });
});

describe("a token that cannot see the repository", () => {
  const realFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  test("is dropped and the request tried again", async () => {
    // An installation token only sees the app's own repositories, and the mod being
    // reviewed is usually somebody else's. Public data needs no permission, so the
    // token is set aside rather than reported as a release that does not exist.
    const calls: (string | undefined)[] = [];

    globalThis.fetch = (async (_url: RequestInfo | URL, init?: RequestInit) => {
      const auth = new Headers(init?.headers).get("Authorization") ?? undefined;
      calls.push(auth);

      return auth
        ? new Response("{}", { status: 404, headers: { "Content-Type": "application/json" } })
        : new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
    }) as typeof fetch;

    const response = await getGitHub("https://api.github.com/repos/someone/Thing/releases", {
      Authorization: "Bearer ghs_installation",
    });

    expect(response?.status).toBe(200);
    expect(calls).toEqual(["Bearer ghs_installation", undefined]);
  });

  test("is not dropped when the answer was fine", async () => {
    const calls: (string | undefined)[] = [];

    globalThis.fetch = (async (_url: RequestInfo | URL, init?: RequestInit) => {
      calls.push(new Headers(init?.headers).get("Authorization") ?? undefined);
      return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
    }) as typeof fetch;

    await getGitHub("https://api.github.com/repos/someone/Thing/releases", {
      Authorization: "Bearer ghs_installation",
    });

    expect(calls).toEqual(["Bearer ghs_installation"]);
  });
});
