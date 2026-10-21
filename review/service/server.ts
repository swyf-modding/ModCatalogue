// The review service.
//
// It answers one question: is this catalogue entry honest? It reads the mod's
// code and never runs it, and it says "unsure" whenever it cannot tell - which
// holds the submission back for a person rather than listing something it is
// not sure about.
//
// The endpoint is shaped so that both jobs are the same call: a submission is
// one mod, and re-reviewing the whole catalogue is a list of them.
//
// Plain TypeScript, run by Bun: no build step, no compile before it can start.
//
// A review takes as long as a language model takes, and Bun closes a request
// that takes longer than a few minutes. So the request starts the job and
// comes back with an id, and the answer is fetched from /result. That is the
// whole reason for the two endpoints rather than one.

import { reviewMod, type ModToReview } from "./review";

const PORT = Number(process.env.PORT ?? 8080);
const MAX_MODS = Number(process.env.MAX_MODS_PER_REQUEST ?? 32);
const GITHUB_API = "https://api.github.com";

/**
 * The token to read GitHub with.
 *
 * A caller may hand one over for the request - the workflow has one and the
 * service does not need to hold it - and otherwise the container's own token
 * is used. Either way, one call is a review, so the 60-an-hour limit is the
 * difference between a few submissions and none.
 */
function tokenFor(req: Request): string | undefined {
  return req.headers.get("x-github-token") ?? process.env.GITHUB_TOKEN ?? undefined;
}

function json(res: Response, body: unknown, status = 200): Response {
  const text = JSON.stringify(body);
  return new Response(text, {
    status,
    headers: {
      "Content-Type": "application/json",
      "Content-Length": String(Buffer.byteLength(text)),
    },
  });
}

/** The catalogue's own list, so the whole thing can be re-reviewed. */
async function fetchCatalogue(token?: string) {
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "User-Agent": "swyf-modding-review",
  };
  if (token ?? process.env.GITHUB_TOKEN) {
    headers.Authorization = `Bearer ${token ?? process.env.GITHUB_TOKEN}`;
  }

  const repo = process.env.CATALOGUE_REPO ?? "swyf-modding/ModCatalogue";

  // The catalogue is read over the network, and the network fails. A failed
  // read is not an answer about any mod, so it is reported as "could not read
  // the catalogue" rather than thrown: the caller is told something is wrong
  // instead of being shown a connection that closed.
  let response: Response;
  try {
    response = await fetch(`${GITHUB_API}/repos/${repo}/contents/mods.json?ref=main`, {
      headers,
      signal: AbortSignal.timeout(30_000),
    });
  } catch {
    return [];
  }
  if (!response.ok) return [];

  const file = (await response.json().catch(() => null)) as
    | { content?: string; encoding?: string }
    | null;
  if (!file?.content) return [];

  const text = Buffer.from(file.content, (file.encoding as BufferEncoding) ?? "base64").toString("utf8");

  let catalogue: {
    mods?: {
      owner?: string;
      repo?: string;
      displayName?: string;
      summary?: string;
      approvedVersion?: string;
      files?: {
        fileName?: string;
        sha256?: string;
        capabilities?: string[];
        bepInPlugin?: string[];
      }[];
    }[];
  };
  try {
    catalogue = JSON.parse(text) as typeof catalogue;
  } catch {
    return [];
  }
  return (catalogue.mods ?? []).map((mod): ModToReview => {
    const owner = (mod.owner ?? "swyf-modding").trim();
    const repo = (mod.repo ?? "").trim();
    return {
      owner,
      repo,
      release: (mod.approvedVersion ?? "").trim(),
      displayName: (mod.displayName ?? "").trim(),
      summary: (mod.summary ?? "").trim(),
      files: (mod.files ?? [])
        .filter((file) => typeof file.fileName === "string" && file.fileName.trim())
        .map((file) => ({
          fileName: (file.fileName ?? "").trim(),
          sha256: typeof file.sha256 === "string" ? file.sha256 : "",
          capabilities: Array.isArray(file.capabilities)
            ? file.capabilities.filter((c) => typeof c === "string")
            : [],
          bepInPlugin: Array.isArray(file.bepInPlugin)
            ? file.bepInPlugin.filter((b) => typeof b === "string")
            : undefined,
        })),
    };
  });
}

// Jobs in flight and finished. A job is one request's work, whatever the
// caller asked for.
type Job = { id: string; mods: ModToReview[]; promise: Promise<unknown> };
const jobs = new Map<string, Job>();
let nextId = 1;

/** Start a job over a list of mods and hand back its id. */
async function start(mods: ModToReview[], token?: string): Promise<string> {
  const id = `job-${nextId++}`;
  const promise = (async () => {
    const results = [];
    for (const mod of mods) {
      // One at a time, on purpose: the agent is a person-sized thing, and a
      // queue of them all at once is a queue of them all at once.
      results.push({
        owner: mod.owner,
        repo: mod.repo,
        release: mod.release,
        ...(await reviewMod(mod, { token })),
      });
    }
    return results;
  })();

  jobs.set(id, { id, mods, promise });
  void promise.finally(() => {
    // Kept briefly so a client that asks a moment too early still gets an
    // answer, then dropped: nothing here is worth keeping for long.
    setTimeout(() => jobs.delete(id), 60_000).unref?.();
  });

  return id;
}

const server = Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);

    if (req.method === "GET" && url.pathname === "/health") {
      return json(new Response(), { ok: true });
    }

    if (req.method === "GET" && url.pathname === "/result") {
      const id = url.searchParams.get("id") ?? "";
      const job = jobs.get(id);
      if (!job) {
        return json(new Response(), { message: "no such job" }, 404);
      }

      // Settled rather than awaited, so a client polling sees the answer the
      // moment it is ready instead of whenever the request times out.
      const done = await Promise.race([
        job.promise.then(() => true),
        new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 50)),
      ]);
      if (!done) return json(new Response(), { pending: true });

      return json(new Response(), { results: await job.promise });
    }

    if (req.method === "POST" && (url.pathname === "/review" || url.pathname === "/review-all")) {
      let mods: ModToReview[];

      if (url.pathname === "/review-all") {
        mods = await fetchCatalogue(tokenFor(req));
      } else {
        let body: { mods?: ModToReview[] };
        try {
          body = await req.json();
        } catch {
          return json(new Response(), { message: "the request was not in the expected shape" }, 400);
        }
        mods = body.mods ?? [];
      }

      const chosen = mods.slice(0, MAX_MODS);
      if (chosen.length === 0) {
        return json(
          new Response(),
          { message: url.pathname === "/review-all" ? "the catalogue could not be read" : "no mods were given to review" },
          url.pathname === "/review-all" ? 502 : 400,
        );
      }

      return json(new Response(), { id: await start(chosen, tokenFor(req)) });
    }

    return json(new Response(), { message: "not found" }, 404);
  },
});

console.log(`the review service is listening on ${server.port}`);
