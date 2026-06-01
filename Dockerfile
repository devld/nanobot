FROM node:24-bookworm-slim AS webui-builder

WORKDIR /app
COPY webui/package.json webui/package-lock.json ./webui/
WORKDIR /app/webui
RUN npm ci
COPY webui/ ./
COPY packages/client-events/ /app/packages/client-events/
RUN mkdir -p /app/nanobot/web && npm run build

FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl wget unzip zip jq gnupg git bubblewrap openssh-client libmagic1 && \
    rm -rf /var/lib/apt/lists/*

RUN export DEBIAN_FRONTEND=noninteractive && \
    mkdir -p /usr/share/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg && \
    chmod 644 /usr/share/keyrings/nodesource.gpg && \
    NODE_MAJOR=24 && \
    ARCH="$(dpkg --print-architecture)" && \
    printf 'Types: deb\nURIs: https://deb.nodesource.com/node_%s.x\nSuites: nodistro\nComponents: main\nArchitectures: %s\nSigned-By: /usr/share/keyrings/nodesource.gpg\n' "$NODE_MAJOR" "$ARCH" \
        > /etc/apt/sources.list.d/nodesource.sources && \
    curl -fsSL -o /usr/share/keyrings/xpra.asc https://xpra.org/xpra.asc && \
    curl -fsSL -o /etc/apt/sources.list.d/xpra.sources \
        "https://raw.githubusercontent.com/Xpra-org/xpra/master/packaging/repos/$(grep -e '^VERSION_CODENAME=' /etc/os-release | awk -F= '{print $2}' | sed 's/\"//g')/xpra.sources" && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        file \
        fonts-noto-cjk \
        fonts-noto-color-emoji \
        nodejs \
        tmux \
        xauth \
        xpra \
        xpra-html5 \
        xpra-x11 && \
    npx --yes playwright install-deps chromium && \
    npm install --global --prefix /usr/local @playwright/cli@latest @steipete/summarize && \
    apt-get purge -y gnupg && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Keep the runtime environment writable by the non-root nanobot user. Enabled
# channels may install their manifest-declared dependencies at startup.
ENV VIRTUAL_ENV=/app/.venv
ENV PATH="/app/.venv/bin:$PATH"
RUN uv venv --seed "$VIRTUAL_ENV"

# Install Python dependencies first (cached layer). Hatch reads the custom build
# hook from hatch_build.py even for this metadata-only install.
ARG NANOBOT_EXTRAS=
COPY pyproject.toml README.md LICENSE THIRD_PARTY_NOTICES.md hatch_build.py ./
RUN mkdir -p nanobot && touch nanobot/__init__.py && \
    if [ -n "$NANOBOT_EXTRAS" ]; then \
        NANOBOT_SKIP_WEBUI_BUILD=1 uv pip install \
            --python "$VIRTUAL_ENV/bin/python" --no-cache ".[${NANOBOT_EXTRAS}]"; \
    else \
        NANOBOT_SKIP_WEBUI_BUILD=1 uv pip install \
            --python "$VIRTUAL_ENV/bin/python" --no-cache .; \
    fi && \
    rm -rf nanobot

# Copy the full source and install
COPY nanobot/ nanobot/
COPY scripts/install_channel_dependencies.py scripts/
COPY --from=webui-builder /app/nanobot/web/dist/ nanobot/web/dist/
RUN NANOBOT_SKIP_WEBUI_BUILD=1 uv pip install --python "$VIRTUAL_ENV/bin/python" --no-cache .

# Preinstall selected channel dependencies from their manifests. A comma-separated
# list keeps the image configurable while preserving WhatsApp and Discord in the default image.
ARG NANOBOT_CHANNELS=whatsapp,discord
RUN for channel in $(printf '%s' "$NANOBOT_CHANNELS" | tr ',' ' '); do \
        python -m scripts.install_channel_dependencies "$channel"; \
    done

# Render deploy template (see render.yaml): committed gateway config that wires
# secrets through ${ANTHROPIC_API_KEY} / ${NANOBOT_WEB_TOKEN} env vars (resolved
# at startup). Lives in the code dir (/app), not the data dir, so a mounted disk
# won't shadow it. Only used when RENDER=true; ignored by local runs.
COPY render-config.json ./

# Create the non-root user and hand ownership of the writable virtualenv to it.
RUN useradd -m -u 1000 -s /bin/bash nanobot && \
    mkdir -p /home/nanobot/.nanobot && \
    mkdir -p /home/nanobot/.local/bin && \
    mkdir -p /run/user/1000 && \
    chmod 700 /run/user/1000 && \
    printf 'prefix=/home/nanobot/.local\n' > /home/nanobot/.npmrc && \
    chown -R nanobot:nanobot /home/nanobot /app/.venv /run/user/1000

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/start-xpra docker/headed-playwright-cli-open /usr/local/bin/
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && \
    chmod +x \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/start-xpra \
        /usr/local/bin/headed-playwright-cli-open

# Start as root so the entrypoint can chown the data dir (on Render, the
# freshly-mounted root-owned persistent disk) before dropping to the non-root
# nanobot user via setpriv. The entrypoint drops privileges on every root start
# and fails closed if it cannot, so the agent never runs as root (see
# entrypoint.sh).
USER root
ENV HOME=/home/nanobot
# Ensure crash output reaches Render logs (app output is otherwise swallowed on
# non-graceful exit).
ENV PYTHONUNBUFFERED=1 PYTHONFAULTHANDLER=1
ENV XDG_RUNTIME_DIR=/run/user/1000
ENV NPM_CONFIG_PREFIX=/home/nanobot/.local
ENV PATH="/home/nanobot/.local/bin:${PATH}"

# Gateway health endpoint, optional WebUI/WebSocket channel, and xpra HTML5 ports
EXPOSE 18790 8765 14500

ENTRYPOINT ["entrypoint.sh"]
CMD ["status"]
