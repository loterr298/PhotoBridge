#!/usr/bin/env bash
set -euo pipefail

# One reproducible local/CI gate for the shippable parts of PhotoBridge.
# It never turns device-only checks into a pass: those remain in the evidence
# matrix and must be supplied by a real iPhone/Mac run.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MODE="${1:-local}"
OUT_DIR="$ROOT_DIR/build/verification"
mkdir -p "$OUT_DIR"
RUN_LOG="$OUT_DIR/delivery-gate.log"
REPORT="$OUT_DIR/delivery-gate.json"
: > "$RUN_LOG"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$RUN_LOG"
}

run() {
  local label="$1"
  shift
  log "START $label"
  "$@" 2>&1 | tee -a "$RUN_LOG"
  log "PASS  $label"
}

required=(
  AGENTS.md PROJECT_PROMPT.md Package.swift project.yml
  docs/TECHNICAL_ARCHITECTURE.md docs/UI_DESIGN.md docs/ACCEPTANCE_TESTS.md
  docs/IMPLEMENTATION_STATUS.md
  apps/iOS/PhotoBridgeApp.swift apps/iOS/OriginalExportService.swift apps/iOS/RestoreService.swift
  Sources/PhotoBridgeMac/PhotoBridgeMac.swift
  scripts/album_export.py scripts/album_restore.py scripts/album_resume.py scripts/upload_resume.py
)
for file in "${required[@]}"; do
  test -f "$file" || { log "FAIL missing required file: $file"; exit 1; }
done

run "git diff --check" git diff --check
log "START Swift package tests"
if swift test 2>&1 | tee -a "$RUN_LOG"; then
  log "PASS  Swift package tests"
else
  # Apple XCTest is not shipped with the standalone Command Line Tools. Keep
  # the executable CoreChecks below as the local fallback, while CI with Xcode
  # remains required for the XCTest suite.
  if ! xcrun --find xctest >/dev/null 2>&1 && grep -q "no such module: XCTest\|no such module 'XCTest'" "$RUN_LOG"; then
    log "BLOCKED Swift package XCTest: Xcode/XCTest is unavailable in this environment"
  else
    log "FAIL Swift package tests"
    exit 1
  fi
fi
run "CoreChecks" swift run CoreChecks
run "MemoryChecks" swift run MemoryChecks
run "StagingChecks" swift run StagingChecks
run "RecoveryChecks" swift run RecoveryChecks
run "Python tests" python3 -m unittest discover -s tests -q
run "iOS Swift syntax parse" swiftc -parse apps/iOS/*.swift

if [[ "$MODE" != "--core-only" ]]; then
  run "Intel macOS release package" bash scripts/build-mac.sh
fi

python3 - "$MODE" "$REPORT" <<'PY' | tee -a "$RUN_LOG"
import json, pathlib, plistlib, subprocess, sys, time
mode, report_path = sys.argv[1:]
root = pathlib.Path.cwd()
def capture(*args):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()
    except Exception as exc:
        return f"unavailable: {exc}"
report = {
    "schemaVersion": 1,
    "generatedAtUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "mode": mode,
    "commit": capture("git", "rev-parse", "HEAD"),
    "branch": capture("git", "branch", "--show-current"),
    "packageVersion": capture("awk", '/MARKETING_VERSION/{print $2; exit}', "project.yml"),
    "packageBuild": capture("awk", '/CURRENT_PROJECT_VERSION/{print $2; exit}', "project.yml"),
    "macPackageVersion": plistlib.loads((root / "apps/macOS/Info.plist").read_bytes())["CFBundleShortVersionString"],
    "macPackageBuild": plistlib.loads((root / "apps/macOS/Info.plist").read_bytes())["CFBundleVersion"],
    "coreGate": "PASS",
    "deviceAcceptance": "REQUIRES_REAL_DEVICE_EVIDENCE",
    "notes": [
        "This gate covers reproducible source checks, tests, iOS syntax, and optional Intel packaging.",
        "It does not claim Photos manual-order, signed-install, Live Photo, or cross-version device acceptance.",
    ],
}
path = pathlib.Path(report_path)
path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print("WROTE", path)
PY

log "DELIVERY GATE PASS (device acceptance remains evidence-gated)"
