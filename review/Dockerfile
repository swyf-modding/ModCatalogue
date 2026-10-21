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
# what actually does the reviewing; the default is the Freebuff CLI, which
# is free and needs no key. Swapping in something else is one variable.
#
# Bun runs the service: it runs TypeScript with no build step, so the image
# can be built from the checkout as it is.

FROM oven/bun:1 AS base
WORKDIR /app

# util-linux for `script`, which is what gives a terminal UI a pty to talk
# to. The Freebuff CLI is a terminal program, and a program that expects a
# terminal and is handed a pipe will not always behave.
#
# git for the source, which is cloned rather than shipped with the image so
# that a review is of the code as GitHub has it.
FROM base AS tools
RUN apt-get update \
 && apt-get install --no-install-recommends -y util-linux git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

FROM tools AS service
COPY package.json bun.lock ./
RUN bun install --production

# The agent, installed globally so it is on PATH the way the review command
# expects. Pinned by version at build time so the image is the same every
# time it runs, rather than whatever npm serves tomorrow.
RUN bun install -g freebuff@latest
RUN bun pm cache rm -rf

# The service itself.
COPY service/ /app/service/

# The service runs as a user that is not root, so a bug in it is not
# a bug in the container.
RUN useradd --create-home --shell /usr/sbin/nologin review
RUN chown -R review:review /app
USER review

ENV PORT=8080 \
    REVIEW_COMMAND=/app/service/review-freebuff.ts \
    REVIEW_MODEL= \
    MAX_MODS_PER_REQUEST=32

EXPOSE 8080

# Bun's own runtime check, so the healthcheck needs no shell in the image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD bun -e 'fetch(`http://127.0.0.1:${process.env.PORT}/health`).then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))'

CMD ["bun", "run", "/app/service/server.ts"]
