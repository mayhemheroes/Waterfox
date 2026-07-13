# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — RUST target (cargo-fuzz) for gfx/qcms. Builds ON TOP of the
# org C/C++ base, adding a pinned Rust nightly + cargo-fuzz under /opt/toolchains/rust,
# then runs the per-repo mayhem/build.sh (fuzz target) + mayhem/test.sh (qcms suite).
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t waterfox-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS

# ── Rust toolchain @ a fixed, lockable, $HOME-independent prefix ───────────────
# Nightly is required for -Zsanitizer=address (the OSS-Fuzz Rust ASan path).
ARG RUST_CHANNEL=nightly-2025-01-15
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root
RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && rustup component add rust-src --toolchain "${RUST_CHANNEL}" \
 && cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rm -f /tmp/rustup-init.sh \
 # The toolchain's prebuilt sanitizer runtimes (librustc-*_rt.*.a) ship DWARF-5 debug
 # info; linked first, they make the fuzz binary's first .debug_info CU DWARF-5 and fail
 # the DWARF<4 triage gate. Strip debug from these RUNTIME archives (not project code —
 # compiler-rt line info is irrelevant to Mayhem triage); the project/std/libfuzzer CUs
 # stay at DWARF-3 via RUST_DEBUG_FLAGS.
 && SR="$(RUSTUP_TOOLCHAIN=${RUST_CHANNEL} rustc --print sysroot)" \
 && for a in "$SR"/lib/rustlib/*/lib/librustc-*_rt.*.a; do strip --strip-debug "$a" || true; done \
 && chown -R 2000:2000 /opt/toolchains/rust

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz target(s)
# + the qcms unit-test suite.
RUN bash mayhem/build.sh

# Run the project's functional suite at build time (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
