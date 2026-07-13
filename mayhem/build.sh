#!/usr/bin/env bash
#
# mayhem/build.sh — build the qcms cargo-fuzz target as a sanitized libFuzzer binary
# (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS) AND build the qcms unit-test
# suite (normal flags) so mayhem/test.sh only has to RUN it.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier / verify-repo re-run THIS script with
# NO network. The registry cache under $CARGO_HOME (populated by this first online build)
# plus the committed fuzz/Cargo.lock are the cache — do NOT hard-code --offline here (it
# would break the first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV, with defaults. SANITIZER_FLAGS is referenced for the
# spec-gate contract; the Rust ASan path is driven through RUSTFLAGS below.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# RUST_DEBUG_FLAGS keeps the fuzz binary's DWARF < 4 (Mayhem triage can't read >=4).
: "${RUST_DEBUG_FLAGS:=-C debuginfo=1 -C force-frame-pointers=yes -Z dwarf-version=3}"
: "${MAYHEM_JOBS:=$(nproc)}"
# mozilla-central ships a root rust-toolchain.toml pinning STABLE (1.90.0), which would
# override the image's pinned nightly and break -Zsanitizer / -Z dwarf-version. Force the
# nightly toolchain the Dockerfile installed (RUSTUP_TOOLCHAIN wins over rust-toolchain.toml).
: "${RUSTUP_TOOLCHAIN:=nightly-2025-01-15}"
export SANITIZER_FLAGS RUST_DEBUG_FLAGS MAYHEM_JOBS RUSTUP_TOOLCHAIN
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

TRIPLE="x86_64-unknown-linux-gnu"

# ── 1) sanitized libFuzzer fuzz target (upstream's own gfx/qcms/fuzz crate) ──────────
# The fuzz crate declares its own [workspace], so this build is isolated from the huge
# mozilla-central workspace and only compiles qcms + libfuzzer-sys + libc.
FUZZ_DIR="gfx/qcms/fuzz"
FUZZ_TARGET="fuzz_target_qcms"

# OSS-Fuzz Rust libFuzzer+ASan flags. --cfg fuzzing matches libfuzzer-sys; ASan is the
# nightly -Zsanitizer=address path. RUST_DEBUG_FLAGS pins DWARF-3 debug info.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address $RUST_DEBUG_FLAGS"
# libfuzzer-sys compiles the C++ libFuzzer runtime via the `cc` crate; force DWARF-3 there
# too (plain clang -g emits DWARF-5) so no clang CU exceeds the triage limit.
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$FUZZ_TARGET"
bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$FUZZ_TARGET"
[ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
cp "$bin" "/mayhem/$FUZZ_TARGET"
echo "built /mayhem/$FUZZ_TARGET"

# ── 2) qcms unit-test suite (normal flags — a clean, non-sanitized build) ────────────
# gfx/qcms is a path-dependency of mozilla-central (built via toolkit/library/rust), not
# a member of the root workspace, so `cargo test` cannot run there directly. Copy the
# crate into an isolated workspace (add an empty [workspace]) and build its unit tests
# with the project's normal flags. test.sh then RUNS the pre-built test binary.
TESTDIR=/tmp/qcms-test
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"
# Keep fuzz/samples + profiles/ + *.icc — the unit tests read them relative to
# CARGO_MANIFEST_DIR / the crate dir; drop only build artifacts.
cp -a gfx/qcms/. "$TESTDIR"/
rm -rf "$TESTDIR"/fuzz/target "$TESTDIR"/target
printf '\n[workspace]\n' >> "$TESTDIR"/Cargo.toml
# Committed lockfile: makes the test-crate resolution deterministic AND lets the
# air-gapped re-run build from the registry cache without touching the index.
cp mayhem/fuzz-target-qcms/qcms-test.Cargo.lock "$TESTDIR"/Cargo.lock

echo "=== building qcms unit-test suite (normal flags) ==="
( cd "$TESTDIR"
  env -u RUSTFLAGS cargo test --no-run --locked --features c_bindings 2>&1
  # Locate the freshly built libtest binary and record its path for test.sh.
  env -u RUSTFLAGS cargo test --no-run --locked --features c_bindings --message-format=json 2>/dev/null \
    | python3 -c '
import sys, json
exe = None
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("reason") == "compiler-artifact" and m.get("profile", {}).get("test") \
       and m.get("target", {}).get("name") == "qcms" and m.get("executable"):
        exe = m["executable"]
print(exe or "", end="")
' > "$TESTDIR"/testbin.path
)
TESTBIN="$(cat "$TESTDIR"/testbin.path)"
[ -n "$TESTBIN" ] && [ -x "$TESTBIN" ] || { echo "ERROR: qcms test binary not built (got '$TESTBIN')" >&2; exit 1; }
echo "built qcms test binary: $TESTBIN"

echo "build.sh complete"
