#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the qcms crate's OWN unit-test suite (built by mayhem/build.sh).
# This is the project's real functional suite (gfx/qcms/src: gtest.rs known-answer /
# assertion tests + transform_util self-tests) — it asserts computed colour-management
# values, so a PATCH that neuters the code to exit(0) FAILS here. Emits a CTRF summary.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TESTDIR=/tmp/qcms-test
TESTBIN="$(cat "$TESTDIR"/testbin.path 2>/dev/null || true)"
if [ -z "$TESTBIN" ] || [ ! -x "$TESTBIN" ]; then
  echo "ERROR: qcms test binary missing ($TESTBIN) — build.sh must build it first" >&2
  emit_ctrf "cargo-test" 0 1 0
  exit 1
fi

# RUN the pre-built libtest binary (do NOT recompile here). libtest prints a machine-
# readable line: "test result: ok. <P> passed; <F> failed; <I> ignored; ...".
# CWD must be the crate dir: several tests load ICC profiles by CWD-relative path.
log="$(mktemp)"
( cd "$TESTDIR" && "$TESTBIN" --test-threads=1 ) 2>&1 | tee "$log" || true

read -r passed failed ignored < <(python3 - "$log" <<'PY'
import re, sys
txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
p = f = i = 0
for m in re.finditer(r'test result:\s+\w+\.\s+(\d+)\s+passed;\s+(\d+)\s+failed;\s+(\d+)\s+ignored', txt):
    p += int(m.group(1)); f += int(m.group(2)); i += int(m.group(3))
# If no result line was printed at all (e.g. the binary was neutered), treat as failure.
if not re.search(r'test result:', txt):
    f = max(f, 1)
print(p, f, i)
PY
)

emit_ctrf "cargo-test" "${passed:-0}" "${failed:-0}" "${ignored:-0}"
