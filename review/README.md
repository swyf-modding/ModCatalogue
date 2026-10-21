# The review service

It reviews mods. It never runs them.

A mod is somebody else's code, and the thing a review has to do is look at
it — read the source, compare it with what the catalogue says about it, and
say whether that entry is honest. Executing it would answer a different
question, and answer it in a way that runs unknown code on the machine that
holds the review.

So the container is built to make that hard to get wrong rather than merely
intended:

- The mod's files are staged **read-only**, and the review runs in a
  directory that is writable but is not the mod's.
- The prompt says to review and not to run, and the answer has to say what
  it read.
- There is no docker socket, no host mount, and the egress is a firewall
  the operator sets rather than a default.
- The image runs as a user that is not root.

## Running it

On the VM:

```sh
docker build -t swyf-review .
docker run -d --name swyf-review \
  -p 8080:8080 \
  --read-only \
  --tmpfs /tmp:rw,size=1g \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 256 \
  --memory 2g \
  -e OPENROUTER_API_KEY=sk-or-... \
  -e GITHUB_TOKEN=ghp_... \
  swyf-review
```

The flags are the point as much as the Dockerfile is. `--read-only` with a
writable `/tmp` is where the working files go; `--cap-drop ALL` and
`--security-opt no-new-privileges` mean a bug in the agent is a bug in a
container with no privileges; `--pids-limit` and `--memory` are there because
the agent is a language model process and those are the two ways it can take
the machine down.

To let it reach the model provider and nothing else, add an egress policy
at the firewall or in front of it. The agent needs to reach its provider
and GitHub, and that is the whole list.

## The interface

```text
POST /review      { "mods": [ ... ] }
                  -> { "id": "job-3" }

GET  /result?id=job-3
                  -> { "pending": true } while it runs,
                     { "results": [ { owner, repo, release, verdict, reason, read } ] } when it is done

POST /review-all
                  -> { "id": "..." } and the same polling

GET  /health
```

The request starts the job and comes back with an id, and the answer is fetched
from `/result`. A review takes as long as a language model takes — a download, a
clone and a read — and Bun closes a request that takes longer than a few
minutes, so the work is not done inside the request at all.

`verdict` is `ok`, `unsure` or `refuse`. `unsure` is the safe answer and
the common one: a submission that is not listed is a nuisance, and one that
is listed and should not have been is a mod running in somebody's game.
The service never refuses to answer — a mod that cannot be reviewed comes
back as `unsure` with the reason, so the caller always has something to
show.

## The agent

`REVIEW_COMMAND` names the program that does the reviewing. It is given a
working directory and has to leave a `verdict.json` in it:

```json
{ "verdict": "ok", "reason": "one sentence", "read": ["the files it read"] }
```

The default is `review-jev.ts`, which sends the prompt and the facts to
[Jev](https://jev.typesafe.ai) via [OpenRouter](https://openrouter.ai).
Jev is a System One model: it takes unstructured text plus a set of questions
and returns structured, typed decisions — exactly what a review needs. It works
headless in a container with an API key (`OPENROUTER_API_KEY`).

Set the model with `REVIEW_MODEL` (default `typesafe/jev`):

```sh
-e REVIEW_MODEL=typesafe/jev
```

Jev needs to reach OpenRouter and nothing else; add an egress policy at the
firewall or in front of the container so it can reach OpenRouter and GitHub,
and that is the whole list.

If that ever stops working, the fix is in `service/review-jev.ts` and nowhere
else, because it is the only place that knows how the agent is invoked.

## Using OpenCode instead

OpenCode provides free models (including Jev) through OpenRouter, so it can be
the review agent too. Point `REVIEW_COMMAND` at `review-opencode.ts`:

```sh
-e REVIEW_COMMAND=/app/service/review-opencode.ts
```

Auth is the same `OPENROUTER_API_KEY` that OpenCode reads from the environment
for its free models — there is no separate OpenCode login. OpenCode is an
interactive terminal agent by design, so this runner is a thin wrapper around
its CLI: it hands the review prompt and facts to `opencode` on stdin/stdout and
parses the verdict JSON from what comes back.

```sh
-e OPENROUTER_API_KEY=sk-or-... \
-e REVIEW_COMMAND=/app/service/review-opencode.ts
```

Swapping in yet another agent is one variable:

```sh
-e REVIEW_COMMAND=/app/service/review-something-else.ts
```

## The GitHub token

A review makes two calls to GitHub - the release and the catalogue - and the
unauthenticated limit is 60 calls an hour. So the service takes a token, and
either of these is enough:

```sh
-e GITHUB_TOKEN=ghp_...        # the container's own token
```

or the caller hands one over per request, which is what the workflow does, since
the workflow already has one and the container does not need to hold a secret:

```text
x-github-token: ghp_...
```

A token raises the limit to 5000 calls an hour. Without one the service still
works - a few submissions and then a `502` saying the catalogue could not be
read, which is the honest answer when the limit is spent.

## What it reads

The mod's release, downloaded from GitHub and unpacked. The binaries are
read by the catalogue's own scan — the same `tools/scan-capabilities.ps1`
the gate uses — so the agent is given facts rather than asked to derive
them: each file's hash, the host-reaching APIs it references, and what its
`[BepInPlugin]` attribute says.

The agent is asked one thing: whether the entry is consistent and honestly
described. It is not asked whether the mod is safe, because nothing here can
answer that, and the catalogue does not claim it can.
