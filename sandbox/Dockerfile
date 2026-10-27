# Sandbox image for mac-exec. Commands run as the unprivileged user "agent" (uid 1000), with the
# root file system mounted read-only by the server; only /workspace, /tmp, and the home folder are writable.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq less nodejs npm procps python3 python3-pip python3-venv unzip wget xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 1000 --create-home --shell /bin/bash agent

# pip and npm install into the user's home folder, which is a temporary file system at run time.
ENV HOME=/home/agent \
    PIP_USER=1 PIP_BREAK_SYSTEM_PACKAGES=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NPM_CONFIG_PREFIX=/home/agent/.npm-global \
    PATH=/home/agent/.local/bin:/home/agent/.npm-global/bin:/usr/local/bin:/usr/bin:/bin

USER agent
WORKDIR /workspace
