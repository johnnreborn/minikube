#!/usr/bin/env bash
# AC-9.1 clean rebuild (SPEC §6.9 task 2), unattended from start to finish:
#   make down -> make cluster-up cni -> phases 1-2 -> make gitops-bootstrap -> make wait-sync -> make up (idempotency)
#   -> phases 3-8 -> record -> phase 9 without the release ACs (9.6 and 9.8 are checked when the release is made).
# `make up` runs as its three stages with phases 1-2 in between: AC-2.4's cluster-wide checks (packet drops, agent logs
# and restarts) only mean something on a Cilium-only cluster, where phase 2 was accepted (SPEC §6.9 AC-9.1 note).
# "make up" duration = the sum of the three stages. Fault-injection tests are on (DESTRUCTIVE=1, §7.6).
# DELETES THE CLUSTER: run only after the user approved it:  CONFIRM=yes scripts/rebuild.sh
# Log: tests/results/rebuild-<UTC>.log. Record read by AC-9.1: tests/.cache/rebuild-last.json.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
# shellcheck source=bootstrap/scripts/lib.sh
source bootstrap/scripts/lib.sh
load_env
export PATH="$HOME/.local/bin:$PATH"
[[ "${CONFIRM:-}" == yes ]] || die "this deletes the cluster: run CONFIRM=yes scripts/rebuild.sh only after the user approved it"
require_cmd docker kind kubectl jq git make
: "${GITOPS_REVISION:?set GITOPS_REVISION in .env}"
git fetch -q origin "$GITOPS_REVISION" || die "git fetch failed"
[[ -z "$(git status --porcelain)" && "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$GITOPS_REVISION")" ]] ||
  die "needs a clean working tree equal to origin/$GITOPS_REVISION (the tests push probe commits)"

mkdir -p tests/results tests/.cache
LOG=tests/results/rebuild-$(date -u +%Y%m%dT%H%M%SZ).log
RECORD=tests/.cache/rebuild-last.json
rm -f "$RECORD"
exec > >(tee -a "$LOG") 2>&1

commit=$(git rev-parse HEAD)
started=$(date -u +%FT%TZ)
STEP_RC=0; STEP_S=0
step() {  # <name> <command...>: run, time it, keep going; the result is in STEP_RC / STEP_S
  local name=$1 t=$SECONDS; shift
  echo "=== $name (start $(date -u +%FT%TZ))"
  "$@"; STEP_RC=$?
  STEP_S=$((SECONDS - t))
  echo "=== $name: rc=$STEP_RC after ${STEP_S}s"
}

echo "clean rebuild of $commit"
step "make down" env CONFIRM=yes make --no-print-directory down
(( STEP_RC == 0 )) || die "make down failed"
down_s=$STEP_S

up_s=0; up_rc=0; stages='{}'
up_stage() {  # <make target>: one stage of `make up`; a failure ends the unattended run
  step "make $1" make --no-print-directory "$1"
  up_s=$((up_s + STEP_S))
  stages=$(jq -c --arg k "$1" --argjson v "$STEP_S" '.[$k] = $v' <<<"$stages")
  (( STEP_RC == 0 )) || die "make $1 failed after ${STEP_S}s - the unattended rebuild did not pass (log $LOG)"
}
phases='{}'; verify_s=0; failed=0
verify_phase() {
  local n=$1 phase_log summary
  step "verify phase $n" env DESTRUCTIVE=1 bash scripts/verify-phase.sh "$n"
  verify_s=$((verify_s + STEP_S))
  # shellcheck disable=SC2012
  phase_log=$(ls -t tests/results/phase-"$n"-[0-9]*.log | head -1)
  summary=$(grep '^SUMMARY' "$phase_log" | tail -1)
  phases=$(jq -c --arg n "$n" --argjson rc "$STEP_RC" --argjson s "$STEP_S" --arg sum "${summary:-no summary}" --arg log "$phase_log" \
    '.[$n] = {rc: $rc, seconds: $s, summary: $sum, log: $log}' <<<"$phases")
  (( STEP_RC == 0 )) || failed=1
}

up_stage cluster-up
up_stage cni
verify_phase 1
verify_phase 2
up_stage gitops-bootstrap
step "make wait-sync" env WAIT_SYNC_TIMEOUT=1200 make --no-print-directory wait-sync
sync_rc=$STEP_RC; sync_s=$STEP_S
step "make up (second run, idempotency)" make --no-print-directory up
up2_rc=$STEP_RC; up2_s=$STEP_S
created=$(kubectl --context kind-boutique get ns kube-system -o jsonpath='{.metadata.creationTimestamp}')
for n in 3 4 5 6 7 8; do verify_phase "$n"; done

jq -n --arg commit "$commit" --arg started "$started" --arg created "$created" --arg log "$LOG" --argjson phases "$phases" \
  --argjson down "$down_s" --argjson up "$up_s" --argjson uprc "$up_rc" --argjson sync "$sync_s" --argjson syncrc "$sync_rc" \
  --argjson up2 "$up2_s" --argjson up2rc "$up2_rc" --argjson verify "$verify_s" --argjson stages "$stages" \
  '{commit: $commit, started: $started, cluster_created: $created, log: $log, down_seconds: $down, up_seconds: $up,
    up_stage_seconds: $stages, up_rc: $uprc, wait_sync_seconds: $sync, wait_sync_rc: $syncrc, up_again_seconds: $up2, up_again_rc: $up2rc,
    verify_seconds: $verify, phases: $phases}' >"$RECORD"
echo "record: $RECORD"

step "verify phase 9 (runtime ACs)" env DESTRUCTIVE=1 AC_ONLY=AC-9.1,AC-9.2,AC-9.3,AC-9.4,AC-9.5,AC-9.7 bash scripts/verify-phase.sh 9
(( STEP_RC == 0 )) || failed=1

echo "=== summary: down ${down_s}s, up ${up_s}s $(jq -c . <<<"$stages"), wait-sync ${sync_s}s (rc $sync_rc), second up ${up2_s}s (rc $up2_rc), phases 1-8 ${verify_s}s"
jq -r '.phases | to_entries[] | "phase \(.key): rc=\(.value.rc) \(.value.summary)"' "$RECORD"
(( sync_rc == 0 && up2_rc == 0 && failed == 0 )) || { echo "=== REBUILD VERIFICATION FAILED (log $LOG)"; exit 1; }
echo "=== REBUILD VERIFICATION PASSED (log $LOG)"
