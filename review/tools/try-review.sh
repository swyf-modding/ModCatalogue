#!/bin/sh
# Ask a running review service about one mod, without the workflow.
#
#   sh tools/try-review.sh <owner> <repo> <release> [service url]
#   GITHUB_READ_TOKEN=... sh tools/try-review.sh swyf-modding AI-Backend v1.2.1
#
# The entry comes from the live catalogue, so this asks the same question a submission does: the
# summary, the files and their capabilities are the listed ones, not a placeholder. Without that,
# a summary that does not describe the code is exactly what the reviewer is built to catch - and
# it will catch the placeholder.
#
# What comes back is the same JSON the workflow puts in the issue, so a failure here is a
# failure of the service rather than of the submission.

set -eu

owner=${1:?usage: try-review.sh <owner> <repo> <release> [service url]}
repo=${2:?usage: try-review.sh <owner> <repo> <release> [service url]}
release=${3:?usage: try-review.sh <owner> <repo> <release> [service url]}
url=${4:-http://127.0.0.1:8080}
catalogue=${CATALOGUE_URL:-https://raw.githubusercontent.com/swyf-modding/ModCatalogue/main/mods.json}
token=${GITHUB_READ_TOKEN:-}

if [ -n "$token" ]; then
  auth="x-github-token: $token"
else
  auth=""
fi

# The real entry, when the catalogue can be read and has one. python3 is used rather than jq
# because it is on every base image and this is one line of parsing.
body=$(curl -fsS "$catalogue" 2>/dev/null | python3 -c '
import json, sys

owner, repo, release = sys.argv[1:4]
try:
    mods = json.load(sys.stdin).get("mods", [])
except Exception:
    sys.exit(0)

for mod in mods:
    if mod.get("repo") == repo and (mod.get("owner") or "swyf-modding") == owner:
        print(json.dumps({"mods": [{
            "owner": owner,
            "repo": repo,
            "release": release,
            "displayName": mod.get("displayName") or repo,
            "summary": mod.get("summary") or "",
            "files": mod.get("files") or [],
        }]}))
        break
' "$owner" "$repo" "$release" 2>/dev/null || true)

if [ -n "$body" ]; then
  echo "using the catalogue entry for $owner/$repo"
else
  echo "no catalogue entry read; using a placeholder summary, which the reviewer will flag"
  body=$(cat <<JSON
{"mods":[{"owner":"$owner","repo":"$repo","release":"$release",
"displayName":"$repo","summary":"a manual test of the review service","files":[]}]}
JSON
)
fi

if [ -n "$auth" ]; then
  started=$(curl -fsS -X POST "$url/review" -H 'Content-Type: application/json' -H "$auth" -d "$body")
else
  started=$(curl -fsS -X POST "$url/review" -H 'Content-Type: application/json' -d "$body")
fi

id=$(printf '%s' "$started" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
if [ -z "$id" ]; then
  echo "the service did not return a job id: $started" >&2
  exit 1
fi

echo "job $id"
while :; do
  sleep 3
  if [ -n "$auth" ]; then
    out=$(curl -fsS "$url/result?id=$id" -H "$auth")
  else
    out=$(curl -fsS "$url/result?id=$id")
  fi

  case "$out" in
    *'"pending":true'*) printf '.' ;;
    *)
      echo
      echo "$out"
      exit 0
      ;;
  esac
done
