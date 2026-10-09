#!/usr/bin/env bash
set -uo pipefail

usage() {
  echo "usage: $0 [en|pl]" >&2
  echo "  one cheap live run through the Claude subscription CLI (Haiku, 1 angle, 1 round), then quorum-engine check" >&2
  echo "  engine: QUORUM_ENGINE_BIN, else the installed ~/Applications/Quorum.app, else engine/dist/quorum-engine" >&2
  echo "  env: CANARY_DIR (a throwaway brain folder, default ~/.quorum-canary/<timestamp>), CANARY_MAX_SECONDS (270), CANARY_MAX_USD (3)," >&2
  echo "       CANARY_MIN_SNAPSHOTS (1)" >&2
  exit 2
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAX_SECONDS="${CANARY_MAX_SECONDS:-270}"
MAX_USD="${CANARY_MAX_USD:-3}"
MIN_SNAPSHOTS="${CANARY_MIN_SNAPSHOTS:-1}"
INSTALLED_APP="$HOME/Applications/Quorum.app"

LANGUAGE="${1:-}"
if [[ -z "$LANGUAGE" ]]; then
  if (( $(date +%j | sed 's/^0*//') % 2 == 0 )); then LANGUAGE=en; else LANGUAGE=pl; fi
fi
case "$LANGUAGE" in
  en) QUESTION="What do the EU AI Act's obligations for general-purpose AI models require, and from when?" ;;
  pl) QUESTION="Jakie wymagania RODO dotyczą danych o zdrowiu i diecie w aplikacjach do zamawiania posiłków?" ;;
  *) usage ;;
esac

if [[ -n "${QUORUM_ENGINE_BIN:-}" ]]; then
  ENGINE="$QUORUM_ENGINE_BIN"
elif [[ -x "$INSTALLED_APP/Contents/Resources/quorum-engine" ]]; then
  ENGINE="$INSTALLED_APP/Contents/Resources/quorum-engine"
else
  ENGINE="$ROOT/engine/dist/quorum-engine"
fi
[[ -x "$ENGINE" ]] || { echo "FAIL no engine at $ENGINE (run scripts/install.sh)"; exit 1; }

BRAIN_DIR="${CANARY_DIR:-$HOME/.quorum-canary/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$BRAIN_DIR"

HANDSHAKE="$("$ENGINE" version)"
ENGINE_BUILD="$(plutil -extract build raw -o - - <<<"$HANDSHAKE" 2>/dev/null || echo unknown)"

FAILURES=()
fail() { FAILURES+=("$1"); }

if [[ "$ENGINE" == "$INSTALLED_APP"/* ]]; then
  EXPECTED_BUILD="$(/usr/libexec/PlistBuddy -c "Print :QuorumEngineBuild" "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || echo "")"
  [[ -n "$EXPECTED_BUILD" && "$EXPECTED_BUILD" != "$ENGINE_BUILD" ]] \
    && fail "engine build $ENGINE_BUILD differs from the build $EXPECTED_BUILD baked into the installed app"
fi

CONFIG="$(cat <<JSON
{"question":"$QUESTION","angleCount":1,"angleModel":"claude-code/claude-haiku-4-5","synthesisModel":"claude-code/claude-haiku-4-5","validatorModel":"claude-code/claude-haiku-4-5","effort":"low","perTopicBudgetUSD":0.5,"runBudgetUSD":1.5,"perTopicTimeoutSec":150,"maxTurns":10,"rounds":1,"spawnMode":"off","runDeadlineSec":$MAX_SECONDS,"brainDir":"$BRAIN_DIR"}
JSON
)"

STARTED="$(date +%s)"
printf '%s\n' "$CONFIG" | "$ENGINE" run > "$BRAIN_DIR/stdout.ndjson" 2> "$BRAIN_DIR/stderr.log" &
RUN_PID=$!
( sleep $((MAX_SECONDS + 60)); kill "$RUN_PID" 2>/dev/null ) &
WATCHDOG=$!
wait "$RUN_PID"
RUN_EXIT=$?
kill "$WATCHDOG" 2>/dev/null
wait "$WATCHDOG" 2>/dev/null
SECONDS_TAKEN=$(( $(date +%s) - STARTED ))

RUN_DIR="$(head -n 1 "$BRAIN_DIR/stdout.ndjson" | plutil -extract run_dir raw -o - - 2>/dev/null || echo "")"
if [[ -z "$RUN_DIR" || ! -d "$RUN_DIR" ]]; then
  echo "FAIL ${SECONDS_TAKEN}s the engine named no run directory (see $BRAIN_DIR/stderr.log)"
  exit 1
fi

REPORT="$("$ENGINE" check "$RUN_DIR" --json)"
CHECK_EXIT=$?
field() { plutil -extract "$1" raw -o - - <<<"$REPORT" 2>/dev/null || echo ""; }

STATUS="$(field run.status)"
COST="$(field run.total_cost_usd)"
SNAPSHOTS="$(field run.snapshots)"
CLAIMS="$(field run.claims_checked)"
GROUNDING="$(field run.grounding)"
VALIDATION="$(field run.validation)"
REFUSAL="$(field run.refusal)"
RUN_BUILD="$(field run.build)"
TRUST="$(field run.trust_level)"
CITED="$(field run.sources_cited)"
STRIPPED="$(field run.stripped_markers)"

if [[ "$RUN_EXIT" == 3 ]]; then
  echo "FAIL ${SECONDS_TAKEN}s \$${COST:-0} refused ($REFUSAL): $(field run.note) · $RUN_DIR"
  exit 1
fi
[[ "$RUN_EXIT" != 0 && "$RUN_EXIT" != 3 ]] && fail "engine exited $RUN_EXIT (see $BRAIN_DIR/stderr.log)"
[[ "$CHECK_EXIT" != 0 ]] && fail "quorum-engine check failed: $("$ENGINE" check "$RUN_DIR" | grep '^FAIL' | tr '\n' ';')"
(( SECONDS_TAKEN > MAX_SECONDS )) && fail "took ${SECONDS_TAKEN}s, limit ${MAX_SECONDS}s"
awk -v c="${COST:-0}" -v m="$MAX_USD" 'BEGIN { exit !(c > m) }' && fail "cost \$$COST exceeds \$$MAX_USD"
[[ "$STATUS" == "halted" || -z "$STATUS" ]] && fail "run ended '${STATUS:-without a result}'"
[[ "$GROUNDING" != "captured" ]] && fail "grounding is '${GROUNDING:-unknown}', not captured"
(( ${SNAPSHOTS:-0} < MIN_SNAPSHOTS )) && fail "${SNAPSHOTS:-0} snapshot(s), need $MIN_SNAPSHOTS"
[[ "$VALIDATION" != "validated" ]] && fail "validation is '${VALIDATION:-missing}', not validated"
(( ${CLAIMS:-0} < 1 )) && fail "no claim was checked against a quote"
[[ -n "$RUN_BUILD" && "$RUN_BUILD" != "$ENGINE_BUILD" ]] && fail "run stamped build $RUN_BUILD, engine says $ENGINE_BUILD"
[[ -z "$TRUST" ]] && fail "the run wrote no record (run.json)"
ls "$BRAIN_DIR"/answers/*.md >/dev/null 2>&1 || fail "no markdown export in $BRAIN_DIR/answers"

DURATION="$((SECONDS_TAKEN / 60))m$(printf '%02d' $((SECONDS_TAKEN % 60)))s"
SUMMARY="$DURATION \$${COST:-0} build $ENGINE_BUILD · $LANGUAGE · status ${STATUS:-none} · trust ${TRUST:-none} · ${CITED:-0} cited · ${SNAPSHOTS:-0} snapshots · ${CLAIMS:-0} claims checked · ${STRIPPED:-0} markers stripped · $RUN_DIR"

if (( ${#FAILURES[@]} == 0 )); then
  echo "PASS $SUMMARY"
  exit 0
fi
echo "FAIL $SUMMARY"
for reason in "${FAILURES[@]}"; do echo "  - $reason"; done
exit 1
