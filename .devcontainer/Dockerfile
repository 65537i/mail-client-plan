FROM node:24.22.0-bookworm@sha256:14078204b6bb268c107ceff6d3c43f45a888105e5c2b18b14c32b3409d93a1b0

ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_BUILD_JOBS=2 \
    PATH=/usr/local/cargo/bin:${PATH}

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        build-essential \
        curl \
        dbus-x11 \
        file \
        libayatana-appindicator3-dev \
        librsvg2-dev \
        libssl-dev \
        libwebkit2gtk-4.1-dev \
        libxdo-dev \
        pkg-config \
        xauth \
        xvfb \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain 1.99.1 --component clippy --component rustfmt \
    && npm install --global pnpm@12.14.0 \
    && chown -R node:node "${CARGO_HOME}" "${RUSTUP_HOME}"

USER node
WORKDIR /workspaces/mail-client-plan
