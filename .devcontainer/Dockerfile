FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    ca-certificates \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# yq (YAML processor)
RUN curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# ShellCheck for script validation
RUN apt-get update && apt-get install -y --no-install-recommends shellcheck \
    && rm -rf /var/lib/apt/lists/*

# actionlint (GitHub Actions linter)
RUN curl -fsSL https://github.com/rhysd/actionlint/releases/latest/download/actionlint_$(curl -fsSL https://api.github.com/repos/rhysd/actionlint/releases/latest | jq -r '.tag_name' | sed 's/v//')_linux_amd64.tar.gz | tar -xz -C /usr/local/bin actionlint
