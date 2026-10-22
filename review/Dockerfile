# The review service.
#
# It reviews mods. It never runs them.
#
# A mod is somebody else's code. The whole point of this container is that
# the code is read and never executed, so the image is built to make that
# hard to get wrong rather than merely intended:
#
#   - the mod's files are staged read-only, and the review runs in a
#     directory that is writable but is not the mod's;
#   - the prompt says to review and not to run, and the answer has to say
#     what was read;
#   - there is no docker socket, no host mount, and the egress is a
#     firewall the operator sets, not a default.
#
# The agent itself is a separate, swappable command. REVIEW_COMMAND decides
# what actually does the reviewing; the default is a two-stage review:
# Jev (OpenCode's System One API) does the triage, and a stronger model,
# run through the real opencode CLI with every tool switched off, makes the
# decision. Swapping in something else is one variable.
#
# Bun runs the service: it runs TypeScript with no build step, so the image
# can be built from the checkout as it is.

FROM oven/bun:1 AS base
WORKDIR /app

# git for the source, which is cloned rather than shipped with the image so
# that a review is of the code as GitHub has it.
FROM base AS tools
RUN apt-get update \
 && apt-get install --no-install-recommends -y git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# The opencode CLI, for the reviewer. npm's `opencode-ai` package is only a
# launcher whose postinstall links the real binary, and Bun does not run
# postinstall scripts, so the platform package that holds the binary is
# installed directly. It is installed here, as root, at build time: the
# running container is meant to be read-only and the service user has no
# business installing anything.
#
# The x64 build needs a CPU with AVX2. On an older CPU, use
# opencode-linux-x64-baseline instead (the build's --version check below
# fails loudly if the binary cannot run).
ARG OPENCODE_VERSION=1.19.3
RUN set -eu; \
    case "$(uname -m)" in \
      x86_64)  pkg=opencode-linux-x64 ;; \
      aarch64) pkg=opencode-linux-arm64 ;; \
      *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/opencode \
 && cd /opt/opencode \
 && echo '{}' > package.json \
 && bun add "${pkg}@${OPENCODE_VERSION}" \
 && ln -s "/opt/opencode/node_modules/${pkg}/bin/opencode" /usr/local/bin/opencode \
 && opencode --version

FROM tools AS service
COPY service/ /app/service/

# The service runs as a user that is not root, so a bug in it is not
# a bug in the container.
RUN useradd --create-home --shell /usr/sbin/nologin review
RUN chown -R review:review /app
USER review

ENV PORT=8080 \
    REVIEW_COMMAND=/app/service/review-opencode.ts \
    REVIEW_MODEL=jev-1.13-free \
    SMART_MODE=cli \
    MAX_MODS_PER_REQUEST=32

EXPOSE 8080

# Bun's own runtime check, so the healthcheck needs no shell in the image.
# It is string concatenation rather than a template literal because Docker
# expands ${...} in a CMD, and the URL must reach Bun intact.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD bun -e 'fetch("http://127.0.0.1:" + process.env.PORT + "/health").then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))'

CMD ["bun", "run", "/app/service/server.ts"]
