// Staging a mod for review, and asking for a verdict.
//
// The code is downloaded and read, never run: files are staged read-only and the review runs
// somewhere else. The agent is a separate program named by REVIEW_COMMAND, given a directory,
// and it must leave a verdict.json behind - so it can be swapped without touching this.
//
// Plain TypeScript, run by Bun: no build step.

import { execFile } from "node:child_process";
import { mkdtemp, rm, mkdir, chmod, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { inflateRawSync } from "node:zlib";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";

const GITHUB_API = "https://api.github.com";
const MAX_ZIP_BYTES = 256 * 1024 * 1024;
/** How much a release may expand to once it is unpacked. */
const MAX_UNPACKED_BYTES = 512 * 1024 * 1024;

/** One file the review knows about, as the catalogue's scan found it. */
export interface ReviewFile {
  fileName: string;
  sha256: string;
  capabilities: string[];
  /** What its [BepInPlugin] attribute says, when it has one. */
  bepInPlugin?: string[];
}

/** A mod to review, as the workflow found it. */
export interface ModToReview {
  owner: string;
  repo: string;
  release: string;
  displayName: string;
  summary: string;
  files: ReviewFile[];
}

export interface Verdict {
  verdict: "ok" | "unsure" | "refuse";
  reason: string;
  /** The files the agent says it read, when it says. */
  read?: string[];
}

/** The task the agent is given. */
export function buildPrompt(mod: ModToReview): string {
  const files = mod.files
    .map(
      (f) =>
        `- ${f.fileName}  sha256 ${f.sha256}\n` +
        `  capabilities: ${
          f.capabilities.length
            ? f.capabilities.join(", ")
            : "none - it touches nothing outside the game process"
        }\n` +
        (f.bepInPlugin && f.bepInPlugin.length
          ? `  declares: ${f.bepInPlugin.join(" | ")}\n`
          : "  declares no [BepInPlugin] attribute\n"),
    )
    .join("");

  return [
    "Review this game modification for a public catalogue. This is a REVIEW, not a change.",
    "",
    "Do not modify, build, run, install or test anything. Do not run the mod's code. Read only.",
    "",
    "Answer whether the catalogue entry is honest and complete, and nothing else:",
    "",
    "  - does the summary describe what the code does?",
    "  - do the capabilities account for what the code appears to reach?",
    "  - is there anything here a player would not expect a mod to do?",
    "",
    "The release is in ./mod and the source is in ./source. The facts below were read",
    "out of the binaries by the same scan the catalogue's own gate uses.",
    "",
    "## The mod",
    `Repository: ${mod.owner}/${mod.repo}`,
    `Release: ${mod.release}`,
    `Display name: ${mod.displayName}`,
    `Summary: ${mod.summary}`,
    "",
    "## What the binaries say",
    files,
    "",
    "## What to answer",
    "",
    "Answer with JSON only, and nothing else:",
    "",
    '{ "verdict": "ok" | "unsure" | "refuse", "reason": "one sentence", "read": ["the files you read"] }',
    "",
    '"ok" only if the entry is consistent and honestly described.',
    '"unsure" if anything does not add up, or if you cannot tell.',
    '"refuse" if something in it should stop a player installing it.',
    "",
    "An unsure answer holds the submission back for a person. That is the right answer when",
    "you are not certain - a submission that is not listed is a nuisance, and one that is",
    "listed and should not have been is a mod running in somebody's game.",
  ].join("\n");
}

/** Run a command, capture its output, and never let a failure be silent. */
function run(
  file: string,
  args: string[],
  options: { cwd?: string; timeout?: number; maxBuffer?: number; env?: Record<string, string> } = {},
): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      file,
      args,
      {
        cwd: options.cwd,
        timeout: options.timeout,
        maxBuffer: options.maxBuffer ?? 8 * 1024 * 1024,
        env: { ...process.env, TERM: "dumb", NO_COLOR: "1" },
      },
      (error, stdout, stderr) => {
        if (error) reject(error);
        else resolve(`${stdout}\n${stderr}`);
      },
    );
  });
}

/** The hosts the GitHub token is sent to. An asset is served from github.com and redirects to a
 *  CDN, so the redirects are followed by hand and the header is left behind at GitHub. */
const TOKEN_HOSTS = new Set(["api.github.com", "github.com"]);

/** The headers to send to a host: the token for GitHub, everything else without it. */
export function headersForHost(
  headers: Record<string, string>,
  host: string,
): Record<string, string> {
  if (TOKEN_HOSTS.has(host)) return { ...headers };
  const sent = { ...headers };
  delete sent.Authorization;
  return sent;
}

/** Fetch a URL, following redirects by hand so the token's host can be decided per hop. */
async function fetchWithRedirects(
  url: string,
  headers: Record<string, string>,
  limit = 5,
): Promise<Response | null> {
  let current = url;

  for (let hop = 0; hop < limit; hop++) {
    let host: string;
    try {
      host = new URL(current).host;
    } catch {
      return null;
    }

    const response = await fetch(current, {
      headers: headersForHost(headers, host),
      redirect: "manual",
      // Bounded: a stalled connection should come back as "could not read it", not as a job
      // that sits at "pending" until somebody notices.
      signal: AbortSignal.timeout(120_000),
    });

    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) return null;
      current = new URL(location, current).toString();
      continue;
    }

    return response;
  }

  return null;
}

/**
 * A GitHub request, retried without the token when the token is what failed.
 *
 * An installation token only sees the app's own repositories, and the mod being reviewed is
 * somebody else's. Public data needs no permission, so a 403 or 404 is retried unauthenticated
 * rather than reported as a missing release.
 */
export async function getGitHub(
  url: string,
  headers: Record<string, string>,
): Promise<Response | null> {
  const first = await fetchWithRedirects(url, headers);
  if (first && first.ok) return first;
  if (!headers.Authorization) return first;
  if (!first || (first.status !== 403 && first.status !== 404)) return first;

  const without = { ...headers };
  delete without.Authorization;
  return fetchWithRedirects(url, without);
}

/** Download the release's zip. It is opened, never run. */
async function downloadRelease(
  mod: ModToReview,
  workDir: string,
  token?: string,
): Promise<Uint8Array | null> {
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "User-Agent": "swyf-modding-review",
  };
  // A token raises the GitHub limit from 60 calls an hour to 5000, and a review makes two.
  if (token ?? process.env.GITHUB_TOKEN) {
    headers.Authorization = `Bearer ${token ?? process.env.GITHUB_TOKEN}`;
  }

  const response = await getGitHub(
    `${GITHUB_API}/repos/${mod.owner}/${mod.repo}/releases/tags/${encodeURIComponent(mod.release)}`,
    headers,
  );
  if (!response || !response.ok) return null;

  const body = (await response.json()) as {
    assets?: { name?: string; browser_download_url?: string; size?: number }[];
  };
  const zip = (body.assets ?? []).find(
    (a) => typeof a.name === "string" && a.name.toLowerCase().endsWith(".zip"),
  );
  if (!zip?.browser_download_url) return null;

  const declared = Number(zip.size ?? 0);
  if (declared > MAX_ZIP_BYTES) return null;

  const download = await getGitHub(zip.browser_download_url, headers);
  if (!download || !download.ok) return null;

  const bytes = new Uint8Array(await download.arrayBuffer());
  if (bytes.length > MAX_ZIP_BYTES) return null;

  return bytes;
}

/**
 * Unpack a zip with node's own zlib.
 *
 * Node has no zip in the standard library, but an entry is either stored or deflated and zlib
 * can inflate a raw deflate stream. Doing it here rather than shelling out to unzip means
 * there is no system program to be missing from the image.
 */
async function unpack(zipBytes: Uint8Array, modDir: string): Promise<string[]> {
  await mkdir(modDir, { recursive: true });

  const view = new DataView(zipBytes.buffer, zipBytes.byteOffset, zipBytes.byteLength);

  // The end-of-central-directory record is at the end, after an optional comment, so it
  // is found by scanning backwards for its signature.
  let eocd = -1;
  for (let i = zipBytes.length - 22; i >= 0 && i > zipBytes.length - 22 - 65536; i--) {
    if (view.getUint32(i, true) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return [];

  const count = view.getUint16(eocd + 10, true);
  let offset = view.getUint32(eocd + 16, true);

  const names: string[] = [];
  let unpacked = 0;

  for (let i = 0; i < count; i++) {
    if (offset + 46 > zipBytes.length) break;
    if (view.getUint32(offset, true) !== 0x02014b50) break;

    const method = view.getUint16(offset + 10, true);
    const compressedSize = view.getUint32(offset + 20, true);
    const uncompressedSize = view.getUint32(offset + 24, true);
    const nameLength = view.getUint16(offset + 28, true);
    const extraLength = view.getUint16(offset + 30, true);
    const commentLength = view.getUint16(offset + 32, true);
    const localOffset = view.getUint32(offset + 42, true);

    const name = new TextDecoder().decode(
      zipBytes.subarray(offset + 46, offset + 46 + nameLength),
    );

    if (!name.endsWith("/")) {
      // A zip bomb: the directory declares the sizes, so they are read before anything is
      // written.
      unpacked += uncompressedSize;
      if (uncompressedSize > MAX_UNPACKED_BYTES || unpacked > MAX_UNPACKED_BYTES) {
        throw new Error(`the release expands to more than ${MAX_UNPACKED_BYTES} bytes`);
      }

      // The local header has its own name and extra lengths, which are the ones that
      // decide where the data starts.
      const localNameLength = view.getUint16(localOffset + 26, true);
      const localExtraLength = view.getUint16(localOffset + 28, true);
      const dataStart = localOffset + 30 + localNameLength + localExtraLength;
      const data = zipBytes.subarray(dataStart, dataStart + compressedSize);

      let content: Buffer | null;
      try {
        content = method === 0 ? Buffer.from(data) : method === 8 ? inflateRawSync(data) : null;
      } catch {
        content = null;
      }

      if (content) {
        // A zip can name a file outside its own tree; the review is not going to be
        // the thing that writes one.
        const parts = name.split("/").filter((part) => part && part !== "..");
        if (parts.length) {
          const target = join(modDir, ...parts);
          mkdirSync(dirname(target), { recursive: true });
          writeFileSync(target, content);
          names.push(parts.join("/"));
        }
      }
    }

    offset += 46 + nameLength + extraLength + commentLength;
  }

  // Read-only, so nothing the agent does can change what it is reviewing.
  await run("chmod", ["-R", "a-w", modDir], { timeout: 10_000 }).catch(() => undefined);

  return names;
}

/**
 * Stage the mod's source, read-only.
 *
 * The question - does the summary describe the code? - cannot be answered from binaries, so
 * the source is cloned at the release's tag. A clone does not run what it fetches: no remote
 * hooks, nothing built or started.
 */
async function stageSource(mod: ModToReview, workDir: string): Promise<string[]> {
  const dir = join(workDir, "source");
  const url = `https://github.com/${mod.owner}/${mod.repo}.git`;

  try {
    await run("git", ["clone", "--depth", "1", "--quiet", "--branch", mod.release, url, dir], {
      timeout: 5 * 60_000,
      maxBuffer: 4 * 1024 * 1024,
    });
  } catch {
    // No git, no tag, or a repository that does not have one. The review can still
    // be done on the binaries and the facts, and the prompt says so.
    return [];
  }

  await run("chmod", ["-R", "a-w", dir], { timeout: 10_000 }).catch(() => undefined);

  const names: string[] = [];
  const walk = async (current: string, prefix = ""): Promise<void> => {
    let entries;
    try {
      entries = await readdir(current, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.name === ".git") continue;
      const name = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) await walk(join(current, entry.name), name);
      else names.push(name);
    }
  };
  await walk(dir);

  return names;
}

/**
 * Read a verdict out of what the agent printed.
 *
 * The agent is asked to answer with JSON only, but an agent that also narrates
 * is an agent, so the last JSON object in the output is taken rather than the
 * only one. An answer that is not a verdict is not a pass: it is held back.
 *
 * One place for this, because both the agent's driver and the service read the
 * answer, and two places would be two opinions about what an answer means.
 */
export function extractVerdict(output: string): Verdict | null {
  const candidates = [...output.matchAll(/\{[^{}]*"verdict"[^{}]*\}/gs)].map((m) => m[0]);

  for (let i = candidates.length - 1; i >= 0; i--) {
    let parsed: { verdict?: unknown; reason?: unknown; read?: unknown };
    try {
      parsed = JSON.parse(candidates[i]) as typeof parsed;
    } catch {
      continue;
    }

    if (typeof parsed.verdict !== "string") continue;

    return {
      verdict: parsed.verdict === "ok" || parsed.verdict === "refuse" ? parsed.verdict : "unsure",
      reason: typeof parsed.reason === "string" ? parsed.reason : "",
      read: Array.isArray(parsed.read) ? parsed.read.filter((r) => typeof r === "string") : undefined,
    };
  }

  return null;
}

/**
 * Read a verdict.json and check that it is a verdict.
 *
 * A verdict file is the answer, so it goes through the same reading as the
 * answer itself: a file that says something else is not a verdict.
 */
export function parseVerdict(text: string): Verdict | null {
  return extractVerdict(text);
}

/**
 * Read a verdict out of what the agent left behind.
 *
 * verdict.json is what the agent wrote down, and it is the answer. The transcript is
 * supplementary: an agent that narrates may print a JSON object of its own, and that
 * object does not get to overrule the file the agent deliberately left.
 */
export function readVerdict(workDir: string): Verdict | null {
  const verdictFile = join(workDir, "verdict.json");
  const transcriptFile = join(workDir, "agent-output.txt");

  if (existsSync(verdictFile)) {
    const verdict = parseVerdict(readFileSync(verdictFile, "utf8"));
    if (verdict) return verdict;
  }

  if (existsSync(transcriptFile)) {
    return parseVerdict(readFileSync(transcriptFile, "utf8"));
  }

  return null;
}

/**
 * Review one mod.
 *
 * Returns the verdict, or an "unsure" saying why it could not be reviewed.
 * It never throws: one mod failing to review is not a reason for the rest to
 * be refused, and it is not a reason for the service to be down.
 */
export async function reviewMod(
  mod: ModToReview,
  options: { token?: string } = {},
): Promise<Verdict> {
  let workDir: string | null = null;

  try {
    workDir = await mkdtemp(join(tmpdir(), "swyf-review-"));
    const modDir = join(workDir, "mod");
    await mkdir(modDir, { recursive: true });

    const zipBytes = await downloadRelease(mod, workDir, options.token);
    const fileNames = zipBytes ? await unpack(zipBytes, modDir) : [];

    const sourceNames = await stageSource(mod, workDir);

    await Bun.write(join(workDir, "prompt.md"), buildPrompt(mod));
    await Bun.write(
      join(workDir, "facts.json"),
      JSON.stringify({ mod, files: fileNames, source: sourceNames }, null, 2),
    );

    // The agent runs with the mod as read-only input and the working
    // directory somewhere it can write, so anything it produces is separate
    // from what it is reviewing.
    await chmod(workDir, 0o755);

    const command = process.env.REVIEW_COMMAND ?? "/app/service/review-opencode.ts";
    const output = await run(process.execPath, [command, workDir], {
      cwd: workDir,
      timeout: 15 * 60_000,
      maxBuffer: 8 * 1024 * 1024,
      // The agent is told not to run anything, and this makes it a little harder.
      env: { ...process.env, REVIEW_MODEL: process.env.REVIEW_MODEL ?? "", REVIEW_READ_ONLY_DIR: modDir },
    });

    // Keep what the agent printed. When every model fails, its output is the only place the
    // reason exists - and it is what somebody needs after "the review could not run".
    if (output.trim()) {
      try {
        writeFileSync(join(workDir, "agent-output.txt"), output, "utf8");
      } catch {
        // A transcript is a nicety; losing it must not lose the review.
      }
    }

    // The agent is asked for JSON only, but if it narrated, the last JSON object
    // in what it printed is the verdict. The transcript is supplementary: a
    // driver that writes a verdict and no transcript is still a verdict.
    //
    // verdict.json comes first, and on its own: it is what the agent left behind,
    // and a transcript that disagrees with it is narration, not an answer.
    const verdict = readVerdict(workDir);

    // The agent is a child process: nothing it prints reaches this service's log unless it is
    // forwarded, and when a model fails that output is the only explanation there is. Kept for
    // anything that is not a clean pass, so the log is not a stream of successful reviews.
    if (output.trim() && (!verdict || verdict.verdict !== "ok")) {
      const text = output.trim();
      console.error(`review agent:\n${text.length > 4000 ? "…\n" + text.slice(-4000) : text}`);
    }

    // A review that could not read the code is not a review. If nothing arrived -
    // no release and no source - then the answer is "unsure" whatever the agent
    // said, because it said it about a summary and a list of hashes.
    if (!verdict) {
      return {
        verdict: "unsure",
        reason:
          "The automated review did not finish, so a maintainer will take a look " +
          "before this is listed.",
      };
    }

    if (verdict.verdict === "ok" && fileNames.length === 0 && sourceNames.length === 0) {
      return {
        verdict: "unsure",
        reason:
          "The automated review could not read the mod's code, so a maintainer will " +
          "take a look before this is listed.",
        read: [],
      };
    }

    return {
      verdict: verdict.verdict,
      reason: verdict.reason || "The review did not give a reason.",
      read: verdict.read,
    };
  } catch (error) {
    // A driver that exits non-zero says why on its stderr, and that is the only copy.
    const stderr = (error as { stderr?: string }).stderr;
    if (stderr && stderr.trim()) console.error(`review agent failed:\n${stderr.trim().slice(-2000)}`);
    return {
      verdict: "unsure",
      reason:
        "The automated review could not be completed, so a maintainer will take a " +
        "look before this is listed.",
    };
  } finally {
    if (workDir) await rm(workDir, { recursive: true, force: true }).catch(() => undefined);
  }
}
