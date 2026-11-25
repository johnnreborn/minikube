#!/usr/bin/env bash
# Run tests/phase-<N>.sh and keep the log in tests/results/ (gitignored). Usage: scripts/verify-phase.sh <N>
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
n=${1:?usage: verify-phase.sh <phase number>}
script="tests/phase-${n}.sh"
[[ -f "$script" ]] || { echo "[FAIL] $script does not exist (phase $n has no tests yet)" >&2; exit 1; }
mkdir -p tests/results
log="tests/results/phase-${n}-$(date -u +%Y%m%dT%H%M%SZ).log"
bash "$script" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
echo "log: $log"
exit "$rc"
