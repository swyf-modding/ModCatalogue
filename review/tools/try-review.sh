#!/bin/sh
# Ask a running review service about one mod, without the workflow.
#
#   sh tools/try-review.sh <owner> <repo> <release> [service url]
#   GITHUB_READ_TOKEN=... sh tools/try-review.sh swyf-modding AI-Backend v1.2.1
#
# The service is on http://127.0.0.1:8080 behind the container's port mapping. What comes back
# is the verdict and its reason, which is the same JSON the workflow puts in the issue - so a
# failure here is a failure of the service rather than of the submission.

set -eu

owner=${1:?usage: try-review.sh <owner> <repo> <release> [service url]}
repo=${2:?usage: try-review.sh <owner> <repo> <release> [service url]}
release=${3:?usage: try-review.sh <owner> <repo> <release> [service url]}
url=${4:-http://127.0.0.1:8080}
token=${GITHUB_READ_TOKEN:-}

if [ -n "$token" ]; then
  auth="x-github-token: $token"
else
  auth=""
fi

body=$(cat <<JSON
{"mods":[{"owner":"$owner","repo":"$repo","release":"$release",
"displayName":"$repo","summary":"a manual test of the review service","files":[]}]}
JSON
)

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
