#!/bin/bash
#
# simlock-test.sh - runs with NO simulator and NO network.
#
# We point the state dir at a temp directory and replace `xcrun simctl` with a
# fake (via $SIMLOCK_SIMCTL) that logs every call and prints canned JSON. Every
# assertion runs against that call log, so nothing here boots a device.
#
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIMLOCK="$SCRIPT_DIR/../scripts/simlock"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/simlock-test.XXXXXX")"
export SIMLOCK_STATE_DIR="$TMP/state"
CALL_LOG="$TMP/simctl-calls.log"
FAKE="$TMP/bin"
mkdir -p "$FAKE"

# --- fake simctl ------------------------------------------------------------
cat > "$FAKE/simctl" <<'FAKE_EOF'
#!/bin/bash
# Fake `simctl`. Logs the exact argv, and answers `list devices` with one
# canned Booted device so name->udid resolution is deterministic.
printf '%s\n' "$*" >> "$FAKE_CALL_LOG"
case "$1 ${2:-}" in
  "list devices")
    cat <<JSON
{ "devices": { "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
  { "udid": "UDID-AAA", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true }
] } }
JSON
    ;;
esac
exit 0
FAKE_EOF
chmod +x "$FAKE/simctl"

# Route the script's simctl at the fake (both via the env knob and PATH).
export SIMLOCK_SIMCTL="$FAKE/simctl"
export FAKE_CALL_LOG="$CALL_LOG"
export PATH="$FAKE:$PATH"

# A stable owner token, so bare acquire/release across separate CLI invocations
# recognise the same owner (the documented pattern for non-`with` use).
export SIMLOCK_LABEL="test-suite"

# --- tiny test harness ------------------------------------------------------
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }
reset_state() { rm -rf "$SIMLOCK_STATE_DIR"; : > "$CALL_LOG"; }

# run simlock, capture rc + stdout, keeping the caller's PPID stable so the
# recorded owner pid == this test process (alive).
run() { "$SIMLOCK" "$@"; }

echo "simlock test suite"
echo "state dir: $SIMLOCK_STATE_DIR"
echo

# 1. acquire succeeds when free ---------------------------------------------
reset_state
out="$(run acquire --device "iPhone 17 Pro" --purpose "unit test" 2>/dev/null)"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "UDID-AAA" ]; then
  ok "acquire succeeds when free (resolved name -> UDID-AAA)"
else
  bad "acquire succeeds when free" "rc=$rc out='$out'"
fi

# 2. a second acquire fails fast --------------------------------------------
run acquire --device "iPhone 17 Pro" >/dev/null 2>&1; rc=$?
if [ "$rc" = 3 ]; then
  ok "second acquire fails fast (exit 3, held by live owner)"
else
  bad "second acquire fails fast" "expected rc=3 got rc=$rc"
fi

# 3. --wait gives up after its timeout --------------------------------------
start=$(date +%s)
run acquire --device "iPhone 17 Pro" --wait 2 >/dev/null 2>&1; rc=$?
elapsed=$(( $(date +%s) - start ))
if [ "$rc" = 7 ] && [ "$elapsed" -ge 2 ]; then
  ok "--wait times out (exit 7 after ~${elapsed}s)"
else
  bad "--wait times out" "rc=$rc elapsed=${elapsed}s (want rc=7, >=2s)"
fi

# 4. release is idempotent ---------------------------------------------------
run release >/dev/null 2>&1; rc1=$?
run release >/dev/null 2>&1; rc2=$?
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ ! -d "$SIMLOCK_STATE_DIR/lock" ]; then
  ok "release is idempotent (twice, rc 0, lock gone)"
else
  bad "release is idempotent" "rc1=$rc1 rc2=$rc2"
fi

# 5. release shuts down ONLY the recorded udid ------------------------------
reset_state
run acquire --device "iPhone 17 Pro" >/dev/null 2>&1
run release >/dev/null 2>&1
# grep -c already prints the count (0 included); never chain `|| echo 0`.
shutdowns="$(grep -c '^shutdown ' "$CALL_LOG" || true)"
only_aaa="$(grep '^shutdown ' "$CALL_LOG" | grep -vc 'shutdown UDID-AAA' || true)"
shutall="$(grep -c 'shutdown all' "$CALL_LOG" || true)"
if [ "$shutdowns" = 1 ] && [ "$only_aaa" = 0 ] && [ "$shutall" = 0 ]; then
  ok "release shuts down only the recorded udid (1x UDID-AAA, no 'shutdown all')"
else
  bad "release shuts down only recorded udid" "shutdowns=$shutdowns other=$only_aaa all=$shutall"
fi

# 6. a dead-pid lock is detected stale and stealable ------------------------
reset_state
mkdir -p "$SIMLOCK_STATE_DIR/lock"
DEADPID=999999   # not a live pid
printf '%s' "$DEADPID" > "$SIMLOCK_STATE_DIR/lock/pid"
printf '%s' "dead-owner" > "$SIMLOCK_STATE_DIR/lock/label"
printf '%s' "$(date +%s)" > "$SIMLOCK_STATE_DIR/lock/heartbeat"
printf '%s' "1800" > "$SIMLOCK_STATE_DIR/lock/ttl"
printf '%s' "1" > "$SIMLOCK_STATE_DIR/lock/supervised"   # a crashed `with` owner
printf '%s' "UDID-AAA" > "$SIMLOCK_STATE_DIR/lock/device"
# acquire should refuse with the "stale" code 4
run acquire --device "iPhone 17 Pro" >/dev/null 2>&1; arc=$?
run steal --force >/dev/null 2>&1; src=$?
if [ "$arc" = 4 ] && [ "$src" = 0 ] && [ ! -d "$SIMLOCK_STATE_DIR/lock" ]; then
  ok "dead-pid lock is stale (acquire exit 4) and stealable (steal exit 0)"
else
  bad "dead-pid lock stale+stealable" "acquire=$arc steal=$src"
fi
# and the steal is logged
if grep -q 'stolen_by' "$SIMLOCK_STATE_DIR/steal.log" 2>/dev/null; then
  ok "steal is written to the audit log"
else
  bad "steal is written to the audit log"
fi

# 7. a live lock refuses to be stolen ---------------------------------------
reset_state
mkdir -p "$SIMLOCK_STATE_DIR/lock"
printf '%s' "$$" > "$SIMLOCK_STATE_DIR/lock/pid"          # this test proc: alive
printf '%s' "live-owner" > "$SIMLOCK_STATE_DIR/lock/label"
printf '%s' "$(date +%s)" > "$SIMLOCK_STATE_DIR/lock/heartbeat"
printf '%s' "1800" > "$SIMLOCK_STATE_DIR/lock/ttl"
run steal --force >/dev/null 2>&1; rc=$?
if [ "$rc" = 6 ] && [ -d "$SIMLOCK_STATE_DIR/lock" ]; then
  ok "live lock refuses to be stolen (exit 6, lock intact)"
else
  bad "live lock refuses steal" "rc=$rc"
fi

# 8. with -- releases on a non-zero exit ------------------------------------
reset_state
run with -- sh -c 'exit 7' >/dev/null 2>&1; rc=$?
if [ "$rc" = 7 ] && [ ! -d "$SIMLOCK_STATE_DIR/lock" ]; then
  ok "with -- releases on non-zero exit (propagates rc=7, lock gone)"
else
  bad "with -- releases on non-zero exit" "rc=$rc lock_present=$([ -d "$SIMLOCK_STATE_DIR/lock" ] && echo yes || echo no)"
fi

# 9. with -- releases on SIGTERM --------------------------------------------
reset_state
"$SIMLOCK" with -- sleep 30 >/dev/null 2>&1 &
wpid=$!
# wait for the lock to be fully populated (pid file non-empty)
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$SIMLOCK_STATE_DIR/lock/pid" ] && break; sleep 0.3; done
kill -TERM "$wpid" 2>/dev/null
wait "$wpid" 2>/dev/null
if [ ! -d "$SIMLOCK_STATE_DIR/lock" ]; then
  ok "with -- releases on SIGTERM (lock gone after kill)"
else
  bad "with -- releases on SIGTERM" "lock still present"
fi

# 10. status --json is parseable --------------------------------------------
reset_state
# free case
free_json="$(run status --json 2>/dev/null)"
free_ok="$(printf '%s' "$free_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("y" if d["held"]==False else "n")' 2>/dev/null)"
# held case
run acquire --device "iPhone 17 Pro" --purpose "json test" >/dev/null 2>&1
held_json="$(run status --json 2>/dev/null)"; src=$?
held_ok="$(printf '%s' "$held_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("y" if d["held"] and d["device"]=="UDID-AAA" else "n")' 2>/dev/null)"
if [ "$free_ok" = y ] && [ "$held_ok" = y ] && [ "$src" = 3 ]; then
  ok "status --json is parseable (free + held, held exits 3)"
else
  bad "status --json is parseable" "free=$free_ok held=$held_ok status_rc=$src"
fi
run release >/dev/null 2>&1

# --- summary ----------------------------------------------------------------
echo
echo "-----------------------------------------"
echo "PASS: $PASS   FAIL: $FAIL"
rm -rf "$TMP"
[ "$FAIL" = 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
