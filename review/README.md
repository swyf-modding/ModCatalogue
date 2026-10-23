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
  -e GITHUB_TOKEN=... \
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
GET  /            what the service is and what it answers
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

The default is `review-opencode.ts`, which sends the prompt and the facts to
Jev via [OpenCode's Zen API](https://opencode.ai/v2/docs/api)
(`POST /zen/v1/systemone`). Jev is a System One model: it takes unstructured
state plus a set of typed questions and returns structured, typed decisions —
exactly what a review needs. OpenCode is free and works headless in a
container with an API key.

Get an API key from OpenCode, then pass it to the container:

```sh
docker run -d --name swyf-review -p 8080:8080 \
  -e OPENCODE_BASE_URL=https://opencode.ai \
  -e OPENCODE_API_KEY=<your-opencode-api-key> \
  -e GITHUB_TOKEN=... \
  swyf-review
```

Set the model with `REVIEW_MODEL` (default `jev-1.13-free`):

```sh
-e REVIEW_MODEL=jev-1.13-free
```

The container needs to reach OpenCode and GitHub, and that is the whole list —
set an egress policy at the firewall or in front of the container accordingly.

If that ever stops working, the fix is in `service/review-opencode.ts` and
nowhere else, because it is the only place that knows how the agent is invoked.

Swapping in a different agent is one variable:

```sh
-e REVIEW_COMMAND=/app/service/review-something-else.ts
```

## Seeing why a review failed

A verdict of `unsure` that says *"the full review could not run (every reviewer model failed or
timed out)"* means stage 1 answered and stage 2 did not - the triage line in the same reason
shows what Jev made of it, so the network and the API key are fine and the reviewer is what
failed.

The service prints the reviewer's own output when that happens, one line per model, so:

```sh
docker logs -f swyf-review
```

and then ask it about one mod directly, without a submission:

```sh
sh tools/try-review.sh swyf-modding AI-Backend v1.2.1 http://127.0.0.1:8080
```

A test that fails there is the service's problem, not the workflow's.

### When the CLI is the problem

The default is `SMART_MODE=cli`: it runs the real `opencode` binary with a private empty `HOME`,
because that is how the free models are meant to be used. That also means it has no stored
credentials, and free model ids change. If the log shows the CLI failing for every model, the
HTTP path uses the same API key Jev just used, which is a good test of whether the key is fine:

```sh
docker run -d --name swyf-review -p 8080:8080 \
  -e SMART_MODE=http \
  -e OPENCODE_API_KEY=<the same key> \
  swyf-review
```

`SMART_MODELS` chooses the models in both modes; in `http` mode they are the provider's own
names, without the `opencode/` prefix.

## The GitHub token

A review makes two calls to GitHub - the release and the catalogue - and the
unauthenticated limit is 60 calls an hour. So the service takes a token, and
either of these is enough:

```sh
-e GITHUB_TOKEN=...            # the container's own token
```

or the caller hands one over per request, which is what the workflow does:

```text
x-github-token: ...
```

The token's job is **reading other people's repositories**, which is most of what a
review does, so it is deliberately not the app's installation token: an installation
token can only see the repositories its app is installed on, and the mod being reviewed
is somebody else's. A classic token with no scopes ticked is enough - public read needs
no permission, and the token's only other job is to raise the limit from 60 requests an
hour to 5000.

Without a token the service still works: public data needs no credential. It just costs
60 requests an hour, and after that a `502` saying the catalogue could not be read, which
is the honest answer when the limit is spent.

The token is for GitHub and for GitHub only. A release asset is served from
`github.com`, which redirects to a CDN, and the redirect is followed by hand so
that the token is left at the edge of GitHub rather than carried to whatever
host the redirect names.

## What it reads

The mod's release, downloaded from GitHub and unpacked. The binaries are
read by the catalogue's own scan — the same `tools/scan-capabilities.ps1`
the gate uses — so the agent is given facts rather than asked to derive
them: each file's hash, the host-reaching APIs it references, and what its
`[BepInPlugin]` attribute says.

The agent is asked one thing: whether the entry is consistent and honestly
described. It is not asked whether the mod is safe, because nothing here can
answer that, and the catalogue does not claim it can.
