#!/usr/bin/env bash
# tests/fm-omp-status-furniture.test.sh - omp 18.22 multi-row status furniture
# reads through the REAL bin/fm-send.sh and bin/fm-control.sh entry points
# against a stateful fake `herdr`.
#
# omp 18.22.x draws up to three furniture rows directly below its borderless
# composer (a bracketed model/hook-status row, a `Context` meter row, and a
# `pi`-led or bracket-led cells row), where omp 18.1.x drew one. The shared
# composer classifier treated the unrecognized rows as wrapped composer input,
# so a live fleet omp worker showing a `recap` block - or just those rows -
# read `pending`: fm-send skipped the doorbell ring, and fm-control exit
# refused to type /quit. Verified live through Herdr on omp 18.22.2; the
# viewport fixtures under tests/fixtures/omp-18.22-status-furniture/ are real
# Herdr `pane read --source visible [--format ansi]` captures of that screen.
#
# These tests pin, end to end:
#   1. A text steer to an idle omp worker showing the recap screen rings the
#      doorbell (the literal `pane send-text` carries the doorbell line).
#   2. `fm-control interrupt` delivers Escape on the same screen.
#   3. `fm-control exit` types /quit on the same screen, and the task stops
#      when the agent reports gone.
#   4. A composer that genuinely holds typed text on that screen still
#      reads pending: the ring is skipped and exit refuses - the new
#      furniture rows never mask real input.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
CONTROL="$ROOT/bin/fm-control.sh"

# LC_ALL=C is pinned inside run_tool: the fleet daemons that call these verbs
# run under the C locale, and multibyte bracket classes in the furniture regex
# only fail there - the environment that hid this defect from a UTF-8 shell.
FIXTURES="$ROOT/tests/fixtures/omp-18.22-status-furniture"

TMP_ROOT=$(fm_test_tmproot fm-omp-status-furniture)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# A task selector with no colon needs its meta. Herdr endpoint records carry
# session/workspace/tab/pane plus the exact task binding (contract:
# fm_backend_validate_task_endpoint), and window is <session>:<pane-id>.
TASK_ID=t1
HERDR_TARGET=default:w1:p1

# make_omp_herdr_fakebin: a STATEFUL `herdr` stub. It logs every call to
# $FM_HERDR_LOG, answers `pane read` with the fixture viewport named by
# $FM_HERDR_SCREEN (ansi/plain), reports the agent as a live idle `omp` until
# `/quit` + `enter` lands (then agent_not_found and a bare-shell foreground),
# and succeeds silently on the remaining calls the control plane makes.
make_omp_herdr_fakebin() { # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf '%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$FM_HERDR_LOG"
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"server":{"running":true}}\n'; exit 0 ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"/tmp"}}}\n' "$3"; exit 0 ;;
  "pane process-info")
    if [ -e "$FM_HERDR_AGENT_DEAD" ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"shell_pid":99,"foreground_processes":[{"argv":["zsh"],"argv0":"zsh","cmdline":"zsh","name":"zsh","pid":2}],"pane_id":"%s"}}}\n' "$FM_HERDR_PANE"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"shell_pid":99,"foreground_processes":[{"argv":["omp"],"argv0":"omp","cmdline":"omp","name":"omp","pid":2}],"pane_id":"%s"}}}\n' "$FM_HERDR_PANE"
    fi
    exit 0 ;;
  "agent get")
    if [ -e "$FM_HERDR_AGENT_DEAD" ]; then
      printf '{"error":{"code":"agent_not_found"}}\n'
    else
      printf '{"result":{"agent":{"agent":"omp","agent_status":"idle"}}}\n'
    fi
    exit 0 ;;
  "pane read")
    case "$*" in
      *--format\ ansi*) cat "$FM_HERDR_SCREEN.vt" ;;
      *) cat "$FM_HERDR_SCREEN.txt" ;;
    esac
    exit 0 ;;
  "pane send-text")
    # Record the literal so `enter` can submit an exit command.
    printf '%s' "$4" > "$FM_HERDR_LAST_TEXT"
    exit 0 ;;
  "pane send-keys")
    # enter submits the last literal; /quit exits the agent.
    if [ "$4" = enter ] && grep -qx '/quit' "$FM_HERDR_LAST_TEXT" 2>/dev/null; then
      : > "$FM_HERDR_AGENT_DEAD"
    fi
    exit 0 ;;
  *)
    exit 0 ;;
esac
SH
  chmod +x "$fb/herdr"
  cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_case() { # <name> <fixture-basename> -> echoes case dir
  local name=$1 screen=$2 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/worktree"
  make_omp_herdr_fakebin "$dir" >/dev/null
  fm_write_meta "$dir/home/state/$TASK_ID.meta" \
    "window=$HERDR_TARGET" \
    "backend=herdr" \
    "harness=omp" \
    "kind=ship" \
    "endpoint_task_id=$TASK_ID" \
    "herdr_session=default" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=tab1" \
    "herdr_pane_id=w1:p1" \
    "worktree=$dir/worktree" \
    "project=alpha"
  # The fake answers `pane read` from one screen basename: symlinks let the
  # same helper serve every verb without duplicating fixtures.
  ln -sf "$FIXTURES/$screen.vt" "$dir/screen.vt"
  ln -sf "$FIXTURES/$screen.txt" "$dir/screen.txt"
  printf '%s\n' "$dir"
}

run_tool() { # <case-dir> <err-file> <tool> <args...>
  local dir=$1 err=$2 tool=$3
  shift 3
  : >"$dir/herdr.log"
  rm -f "$dir/agent-dead" "$dir/last-text"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
    FM_SEND_SETTLE=0 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=5 \
    LC_ALL=C \
    FM_HERDR_LOG="$dir/herdr.log" FM_HERDR_PANE=w1:p1 \
    FM_HERDR_AGENT_DEAD="$dir/agent-dead" FM_HERDR_LAST_TEXT="$dir/last-text" \
    FM_HERDR_SCREEN="$dir/screen" \
    "$tool" "$@" >/dev/null 2>"$err"
}

test_recap_screen_rings_the_doorbell() {
  local dir err rc
  dir=$(setup_case recap-ring recap)
  err="$dir/err"
  run_tool "$dir" "$err" "$SEND" t1 "steer onto an idle omp worker"
  rc=$?
  expect_code 0 "$rc" "a steer to an idle omp composer should enqueue"
  [ -f "$dir/home/state/$TASK_ID.inbox/001.msg" ] || fail "the steer was not recorded"
  grep -q "pane.*send-text.*Firstmate instruction waiting" "$dir/herdr.log" \
    || fail "the doorbell was not typed under the recap screen:"$'\n'"$(cat "$dir/herdr.log")"
  pass "fm-send: an idle omp composer under a recap block rings the doorbell"
}

test_recap_screen_interrupt_delivers_escape() {
  local dir err rc
  dir=$(setup_case recap-int recap)
  err="$dir/err"
  run_tool "$dir" "$err" "$CONTROL" t1 interrupt
  rc=$?
  expect_code 0 "$rc" "interrupt on an idle omp composer should succeed"
  grep -q 'send-keys.*escape' "$dir/herdr.log" \
    || fail "Escape was not delivered:"$'\n'"$(cat "$dir/herdr.log")"
  [ ! -e "$dir/agent-dead" ] || fail "an interrupt killed the agent"
  pass "fm-control: interrupt delivers Escape on an idle omp composer under a recap block"
}

test_recap_screen_exit_types_quit() {
  local dir err rc
  dir=$(setup_case recap-exit recap)
  err="$dir/err"
  run_tool "$dir" "$err" "$CONTROL" t1 exit
  rc=$?
  expect_code 0 "$rc" "exit on an idle omp composer should succeed"
  grep -qx '/quit' "$dir/last-text" \
    || fail "/quit was not typed under the recap screen:"$'\n'"$(cat "$dir/herdr.log")"
  [ -e "$dir/agent-dead" ] || fail "the submitted /quit never stopped the agent"
  pass "fm-control: exit types /quit on an idle omp composer under a recap block"
}

test_typed_text_still_holds_the_ring_and_the_exit() {
  local dir err rc
  dir=$(setup_case recap-typed recap-typed)
  err="$dir/err"

  run_tool "$dir" "$err" "$SEND" t1 "steer past a held draft"
  rc=$?
  expect_code 0 "$rc" "a skipped ring is still a sent steer"
  [ -f "$dir/home/state/$TASK_ID.inbox/001.msg" ] || fail "the steer was not recorded"
  if grep -q 'pane.*send-text' "$dir/herdr.log"; then
    fail "a composer holding typed text must skip the doorbell:"$'\n'"$(cat "$dir/herdr.log")"
  fi

  run_tool "$dir" "$err" "$CONTROL" t1 exit
  rc=$?
  [ "$rc" -ne 0 ] || fail "exit must refuse while the composer holds typed text"
  assert_contains "$(cat "$err")" "pending" \
    "the exit refusal should name the pending composer"
  [ ! -e "$dir/agent-dead" ] || fail "the refused exit still killed the agent"
  pass "fm-omp status furniture: typed composer text still reads pending for the ring and exit"
}

test_recap_screen_rings_the_doorbell
test_recap_screen_interrupt_delivers_escape
test_recap_screen_exit_types_quit
test_typed_text_still_holds_the_ring_and_the_exit
