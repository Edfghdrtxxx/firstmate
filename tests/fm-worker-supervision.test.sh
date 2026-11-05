#!/usr/bin/env bash
# tests/fm-worker-supervision.test.sh - a ship or scout worker supervises no
# home, so firstmate's own supervision surface must not reach it:
#   1. fm-guard.sh inside a worker prints no supervision instruction at all -
#      no "drain them with bin/fm-wake-drain.sh" queued-wake warning and no
#      watcher-down banner or repair line - and records no stale-episode
#      marker that would steal firstmate's first full banner.
#   2. fm-wake-drain.sh run by a worker refuses before presenting or mutating:
#      one stderr line, nonzero exit, stdout empty, queue byte-identical.
#   3. The same commands run by an actor carrying no task-worker marker keep
#      today's behavior unchanged: the queued-wake warning still prints on a
#      guarded send, and the drain still presents and acknowledges for a
#      firstmate or a secondmate in its own home.
# The worker identity is the FM_TASK_ID marker bin/fm-spawn.sh exports only
# into ship and scout panes; a secondmate launch is deliberately unmarked, so
# the unmarked-drain case IS the secondmate-in-own-home case. The incident this
# pins: research workers routing each other through bin/fm-send.sh read the
# guard's queued-wake warning as their own instruction, drained and
# acknowledged firstmate's wake queue, and hid wakes before firstmate saw
# them. The test runner itself usually runs inside a worker pane, so every
# case below pins the marker explicitly in both directions.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-supervision)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# --- fm-send fixture ----------------------------------------------------------
# Stub tmux exactly as fm-send-inbox.test.sh does: log literal typed text to
# FM_SEND_LOG and answer the composer/settle probes cleanly.
make_send_stubs() { # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows) printf 'fm-t1\nwin\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# <name> -> case dir with home/state, one in-flight task meta, and fakebin.
make_send_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_send_stubs "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  printf '%s\n' "$dir"
}

# run_send <case-dir> <err-file> [env...] -- <fm-send args...>
run_send() {
  local dir=$1 err=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"$dir/send.log"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_SETTLE=0 ${envs[@]+"${envs[@]}"} \
    "$SEND" "$@" >/dev/null 2>"$err"
}

assert_no_supervision_output() { # <stderr-file> <state-dir> <case-name>
  local err=$1 state=$2 name=$3
  ! grep -F 'drain them with bin/fm-wake-drain.sh' "$err" >/dev/null \
    || fail "$name: the queued-wake warning reached a task worker: $(cat "$err")"
  ! grep -F 'WATCHER DOWN' "$err" >/dev/null \
    || fail "$name: the watcher-down banner reached a task worker: $(cat "$err")"
  ! grep -F 'watcher still down' "$err" >/dev/null \
    || fail "$name: the watcher-down reminder reached a task worker: $(cat "$err")"
  ! grep -F 'left untouched because this session lacks verified fleet-lock ownership' "$err" >/dev/null \
    || fail "$name: the read-only warning reached a task worker: $(cat "$err")"
  [ ! -e "$state/.guard-watcher-stale-banner" ] \
    || fail "$name: a task worker claimed this home's stale-banner episode marker"
}

# A worker running fm-send while wakes are queued is the reported defect: the
# guard treated it as the supervisor and told it to drain firstmate's queue.
test_worker_send_gets_no_supervision_instruction() {
  local dir state err
  dir=$(make_send_case worker-send)
  state="$dir/home/state"
  err="$dir/send.err"
  append_wake "$state" signal peer.status "signal: peer.status" \
    || fail "queueing a wake in the fixture home failed"

  run_send "$dir" "$err" FM_TASK_ID=fm-guard-worker-wake-ack -- t1 "ring the peer doorbell" \
    || fail "the worker's send failed: $(cat "$err")"

  assert_no_supervision_output "$err" "$state" worker-send
  [ -f "$state/t1.inbox/001.msg" ] \
    || fail "suppressing the supervision warning must not block the doorbell's durable record"
  pass "a task worker's fm-send stays silent on supervision and still delivers"
}

# Without the worker marker the same send must keep warning: firstmate's own
# sessions, lock-refused sessions, and a secondmate supervising its own home
# all rely on this line.
test_unmarked_send_still_warns_about_queued_wakes() {
  local dir state err
  dir=$(make_send_case unmarked-send)
  state="$dir/home/state"
  err="$dir/send.err"
  append_wake "$state" signal peer.status "signal: peer.status" \
    || fail "queueing a wake in the fixture home failed"

  run_send "$dir" "$err" FM_TASK_ID= -- t1 "ring the peer doorbell" \
    || fail "the unmarked send failed: $(cat "$err")"

  grep -F 'drain them with bin/fm-wake-drain.sh before anything else' "$err" >/dev/null \
    || fail "the unmarked caller lost the queued-wake warning: $(cat "$err")"
  pass "an unmarked fm-send still prints the queued-wake drain warning"
}

# The drain is the queue's only presenter/acknowledger; a worker must be
# refused before touching it in every mode, including --ack-through, which the
# incident's workers also ran.
test_worker_drain_is_refused() {
  local dir state queue_before out err rc
  dir=$(make_case worker-drain)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  append_wake "$state" signal peer.status "signal: peer.status" \
    || fail "queueing a wake in the fixture home failed"
  queue_before=$(sha256sum "$state/.wake-queue" | cut -d' ' -f1)

  FM_STATE_OVERRIDE="$state" FM_TASK_ID=fm-guard-worker-wake-ack \
    "$DRAIN" >"$out" 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a worker's drain presented instead of refusing"
  grep -F 'refused' "$err" >/dev/null \
    || fail "the worker drain refusal lacks its clear stderr line: $(cat "$err")"
  [ ! -s "$out" ] || fail "a refused worker drain presented rows: $(cat "$out")"
  [ "$(sha256sum "$state/.wake-queue" | cut -d' ' -f1)" = "$queue_before" ] \
    || fail "a refused worker drain changed the queue"
  [ ! -e "$state/.branch-eligible-rows" ] && [ ! -e "$state/.branch-eligible-owner" ] \
    || fail "a refused worker drain touched the branch grant records"

  FM_STATE_OVERRIDE="$state" FM_TASK_ID=fm-guard-worker-wake-ack \
    "$DRAIN" --ack-through 1 --recovery-generation gen-test >"$out" 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a worker's --ack-through acknowledged instead of refusing"
  grep -F 'refused' "$err" >/dev/null \
    || fail "the worker ack refusal lacks its clear stderr line: $(cat "$err")"
  [ ! -s "$out" ] || fail "a refused worker ack printed output: $(cat "$out")"
  [ "$(sha256sum "$state/.wake-queue" | cut -d' ' -f1)" = "$queue_before" ] \
    || fail "a refused worker --ack-through changed the queue"
  pass "a task worker's fm-wake-drain and --ack-through are refused without touching the queue"
}

# The unmarked drain is the supervisor path: main in this home and a
# secondmate in its own home are both unmarked, so this single case pins both.
test_unmarked_drain_presents_and_acknowledges() {
  local dir state out err seq gen
  dir=$(make_case unmarked-drain)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  append_wake "$state" signal peer.status "signal: peer.status" \
    || fail "queueing a wake in the fixture home failed"

  FM_STATE_OVERRIDE="$state" env -u FM_TASK_ID \
    "$DRAIN" >"$out" 2>"$err" \
    || fail "the unmarked drain failed: $(cat "$err")"
  grep -F 'peer.status' "$out" >/dev/null \
    || fail "the unmarked drain presented nothing: $(cat "$out")"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] \
    || fail "the unmarked drain emitted no acknowledgement command: $(cat "$err")"
  FM_STATE_OVERRIDE="$state" env -u FM_TASK_ID \
    "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >>"$out" 2>>"$err" \
    || fail "the unmarked acknowledgement failed: $(cat "$err")"
  pass "an unmarked drain presents and acknowledges, covering a secondmate in its own home"
}

# The incident's actual shape: a pane revived outside fm-spawn (a backend
# session restore) loses the FM_TASK_ID export, but its shell still sits in
# the task's recorded worktree - the same detection covers both commands.
test_restored_pane_in_recorded_worktree_is_still_a_worker() {
  local dir state wt err out rc
  dir=$(make_send_case restored-send)
  state="$dir/home/state"
  wt="$dir/worktree"
  mkdir -p "$wt"
  err="$dir/send.err"
  # Record the task's worktree the way fm-spawn does, so the caller's cwd
  # identifies it even without the launch export.
  printf 'worktree=%s\n' "$wt" >> "$state/t1.meta"
  append_wake "$state" signal peer.status "signal: peer.status" \
    || fail "queueing a wake in the fixture home failed"

  ( cd "$wt" && run_send "$dir" "$err" FM_TASK_ID= -- t1 "ring the peer doorbell" ) \
    || fail "the restored worker's send failed: $(cat "$err")"
  assert_no_supervision_output "$err" "$state" restored-send
  [ -f "$state/t1.inbox/001.msg" ] \
    || fail "the restored worker's doorbell was not delivered"

  local queue_before
  queue_before=$(sha256sum "$state/.wake-queue" | cut -d' ' -f1)
  out="$dir/drain.out"
  ( cd "$wt" && env -u FM_TASK_ID FM_STATE_OVERRIDE="$state" "$DRAIN" ) >"$out" 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a restored worker's drain presented instead of refusing"
  grep -F 'refused' "$err" >/dev/null \
    || fail "the restored worker drain refusal lacks its clear stderr line: $(cat "$err")"
  [ ! -s "$out" ] || fail "a refused restored-worker drain presented rows: $(cat "$out")"
  [ "$(sha256sum "$state/.wake-queue" | cut -d' ' -f1)" = "$queue_before" ] \
    || fail "a refused restored-worker drain changed the queue"
  pass "a pane restored inside a recorded worktree is refused drain and spared guard output"
}

test_worker_send_gets_no_supervision_instruction
test_unmarked_send_still_warns_about_queued_wakes
test_worker_drain_is_refused
test_unmarked_drain_presents_and_acknowledges
test_restored_pane_in_recorded_worktree_is_still_a_worker

