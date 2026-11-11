FROM node:26.13.1-bookworm@sha256:b7087bc4d973034b30854b378ba107f9fab622b47514cb7e2592e41b8bab8d49

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
