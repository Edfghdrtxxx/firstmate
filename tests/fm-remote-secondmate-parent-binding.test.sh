#!/usr/bin/env bash
# tests/fm-remote-secondmate-parent-binding.test.sh - regression coverage for the
# fm-remote-sm-cleanup-parent-binding-s1 scout report: finished-worker cleanup
# inside a REMOTE second-mate home refused forever with "cannot resolve the
# primary home ... durable parent binding", because the remote launch hands the
# child the remote code checkout as its parent home (bin/fm-spawn.sh's sole
# writer of FM_PUBLIC_FOLLOWUP_PRIMARY_HOME receives FM_HOME=$FM_ROOT from
# bin/fm-remote-secondmate-control.sh's host-local launch), and that path can
# never carry the parent's real state or registry.
#
# The fix (report section 7, captain-approved same-machine scope): a durable
# .fm-secondmate-parent record, written once at seeding next to the
# .fm-secondmate-home identity marker, names this home's route to its parent as
# "local" or "remote". bin/fm-teardown.sh's cleanup gate reads it and treats a
# remote parent as OUT OF SCOPE (never refuses purely for being cross-machine,
# since the whole promised-public-reply subsystem is same-filesystem by
# construction) while still refusing on a genuine same-filesystem signal
# committed directly to this home's own .env file - never on an unrelated
# process-environment export, which is what let the remote host's own login
# shell mask into this home's binding before.
#
# This drives the REAL remote route (fm-remote-home-seed.sh -> fm-on.sh ->
# fm-remote-entrypoint.sh -> the host-local fm-remote-secondmate-control.sh ->
# the real bin/fm-spawn.sh --secondmate) across the repo's own deterministic SSH
# boundary and Herdr fixture, then runs the real bin/fm-teardown.sh for a
# finished child worker inside the produced remote home - never source-text
# matching.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-parent-binding)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"
DOCTOR_LOG="$TMP_ROOT/doctor.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
CLAIMS="$TMP_ROOT/claims"
PUBLISH_PID=
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"

cleanup() {
  local worker_pid=''
  if [ -n "$PUBLISH_PID" ]; then
    touch "$PUBLISH_RELEASE" 2>/dev/null || true
    kill "$PUBLISH_PID" 2>/dev/null || true
    wait "$PUBLISH_PID" 2>/dev/null || true
  fi
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    kill "$worker_pid" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

PUBLISH_HOME="$TMP_ROOT/publication-home"
PUBLISH_FAKEBIN=$(fm_fakebin "$TMP_ROOT/publication-fake")
PUBLISH_ENTERED="$TMP_ROOT/publication-marker-entered"
PUBLISH_RELEASE="$TMP_ROOT/publication-marker-release"
PUBLISH_MANIFEST="$TMP_ROOT/publication.manifest"
REAL_MV=$(command -v mv)
cat > "$PUBLISH_FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
case "$destination" in
  */.fm-secondmate-home)
    touch "$FM_TEST_PUBLISH_ENTERED"
    while [ ! -f "$FM_TEST_PUBLISH_RELEASE" ]; do sleep 0.02; done
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
chmod +x "$PUBLISH_FAKEBIN/mv"
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nparent_host_b64=%s\nproject_count=0\n' \
  "$(printf publication | base64 | tr -d '\n')" \
  "$(printf 'Publication-order regression charter.\n' | base64 | tr -d '\n')" \
  "$(printf publish-host | base64 | tr -d '\n')" > "$PUBLISH_MANIFEST"
PATH="$PUBLISH_FAKEBIN:$PATH" FM_HOME="$PUBLISH_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_TEST_REAL_MV="$REAL_MV" FM_TEST_PUBLISH_ENTERED="$PUBLISH_ENTERED" \
  FM_TEST_PUBLISH_RELEASE="$PUBLISH_RELEASE" \
  "$ROOT/bin/fm-remote-home-provision.sh" < "$PUBLISH_MANIFEST" >/dev/null 2>&1 &
PUBLISH_PID=$!
publish_wait=0
while [ ! -f "$PUBLISH_ENTERED" ]; do
  kill -0 "$PUBLISH_PID" 2>/dev/null || fail "remote provisioning exited before its completion marker"
  publish_wait=$((publish_wait + 1))
  [ "$publish_wait" -le 250 ] || fail "remote provisioning never reached its completion marker"
  sleep 0.02
done
cmp -s "$PUBLISH_HOME/.fm-secondmate-parent" <(
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=publish-host\n'
) || fail "remote provisioning exposed completion before publishing the durable parent record"
assert_absent "$PUBLISH_HOME/.fm-secondmate-home" \
  "the remote identity marker must remain absent until durable parent publication completes"
touch "$PUBLISH_RELEASE"
wait "$PUBLISH_PID" || fail "remote provisioning failed after publishing durable state"
PUBLISH_PID=
assert_present "$PUBLISH_HOME/.fm-secondmate-home" \
  "remote provisioning must publish its identity marker as the completion point"
pass "remote provisioning publishes durable parent state before its completion marker"

# --- the remote host's tracked code root, real git repos, one project --------
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'
REMOTE_ORIGIN="$TMP_ROOT/firstmate-origin.git"
git init -q --bare "$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" remote add origin "file://$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$REMOTE_ORIGIN" symbolic-ref HEAD refs/heads/main

git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -qm init
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
git --git-dir="$TMP_ROOT/alpha.git" symbolic-ref HEAD refs/heads/main
printf -- '- alpha [direct-PR] - alpha project (added 2026-08-04)\n' > "$PARENT/data/projects.md"
printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"

# The primary home is the X-mode / relay home: the captain's real activation.
printf 'FMX_PAIRING_TOKEN=repro-token\n' > "$PARENT/.env"

# --- deterministic SSH boundary, identical shape to the lifecycle e2e suite --
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..2]);
' "$argv_b64")
IFS=$'\t' read -r command_name _command_action command_rel <<EOF
$command_fields
EOF
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf 'check herdr=ok: /usr/bin/herdr\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
if [ "$command_name" = fm-remote-secondmate-control.sh ] \
   && [ "$_command_action" = launch ] \
   && [ -n "${FM_TEST_PUBLICATION_TARGET:-}" ]; then
  out=$("$FM_FAKE_REMOTE_ENTRYPOINT" "$@")
  rc=$?
  rm -f "$FM_TEST_PUBLICATION_TARGET"
  ln -s "$FM_TEST_PUBLICATION_FOREIGN" "$FM_TEST_PUBLICATION_TARGET" || exit 94
  printf '%s\n' "$out"
  exit "$rc"
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha \
  >/dev/null || fail "real remote secondmate seeding failed"

# --- the durable record itself: the fundamental part of the fix -------------
assert_present "$REMOTE_HOME/.fm-secondmate-parent" \
  "real remote provisioning must write a durable parent record"
cmp -s "$REMOTE_HOME/.fm-secondmate-parent" <(
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote-mac\n'
) || fail "real remote provisioning must write the exact durable remote parent record"

remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null \
  || fail "real remote secondmate launch failed"

STAGED_LAUNCH=$(sed -n "s/^pane send-text [^ ]* \\. '\([^']*\)' --session [^ ]*\$/\1/p" "$HERDR_LOG" | tail -1)
[ -n "$STAGED_LAUNCH" ] && [ -f "$STAGED_LAUNCH" ] \
  || fail "the remote launch did not deliver a staged command to assert against"
DELIVERED_LINE=$(grep -F 'FM_PUBLIC_FOLLOWUP_PRIMARY_HOME' "$STAGED_LAUNCH" | tail -1 || true)
DELIVERED=$(printf '%s\n' "$DELIVERED_LINE" | tr ' ' '\n' \
  | sed -n "s/^FM_PUBLIC_FOLLOWUP_PRIMARY_HOME='\{0,1\}\([^']*\)'\{0,1\}\$/\1/p" | tail -1)
[ -n "$DELIVERED" ] || fail "the remote launch did not deliver a primary-home binding to assert against"
case "$DELIVERED" in
  "$REMOTE_ROOT") : ;;
  *) fail "test setup drifted: expected the remote code root to be delivered as the (wrong) parent binding, got: $DELIVERED" ;;
esac

# --- a finished child worker inside the remote secondmate home --------------
CHILD_WT="$REMOTE_HOME/projects/alpha"
mkdir -p "$REMOTE_HOME/state"
# This regression exercises remote-parent binding, not backlog mutation. Keep
# its synthetic child home on the supported hand-edited backend so teardown's
# fused automatic close is correctly exempt without requiring a tasks-axi mock.
printf '%s\n' manual > "$REMOTE_HOME/config/backlog-backend"
write_child_meta() {
  fm_write_meta "$REMOTE_HOME/state/work-child.meta" \
    "window=firstmate:fm-work-child" "endpoint_task_id=work-child" \
    "worktree=$CHILD_WT" "project=$CHILD_WT" "harness=codex" "kind=ship" \
    "mode=local-only" "yolo=off"
}
mkdir -p "$TMP_ROOT/childfake"
for t in tmux treehouse no-mistakes gh gh-axi tasks-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/childfake/$t"
  chmod +x "$TMP_ROOT/childfake/$t"
done

run_child_teardown() { # <extra env assignments...>
  local out rc=0
  write_child_meta
  out=$(env "$@" PATH="$TMP_ROOT/childfake:$PATH" \
    FM_HOME="$REMOTE_HOME" FM_STATE_OVERRIDE="$REMOTE_HOME/state" \
    FM_DATA_OVERRIDE="$REMOTE_HOME/data" FM_CONFIG_OVERRIDE="$REMOTE_HOME/config" \
    "$REMOTE_ROOT/bin/fm-teardown.sh" work-child 2>&1) || rc=$?
  CHILD_TEARDOWN_OUT=$out
  CHILD_TEARDOWN_RC=$rc
}

# Case B-equivalent: the delivered (wrong) binding points at the remote code
# root, and that root itself carries an X-mode .env - a plausible real-world
# state (a captain who also runs Firstmate directly on the build Mac). Before
# the fix this refused; the durable record now makes it out of scope.
printf 'FMX_PAIRING_TOKEN=remote-host-token\n' > "$REMOTE_ROOT/.env"
run_child_teardown FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$DELIVERED"
rm -f "$REMOTE_ROOT/.env"
[ "$CHILD_TEARDOWN_RC" -eq 0 ] \
  || fail "a remote-routed child must allow cleanup when only the remote code root looks relay-active (rc=$CHILD_TEARDOWN_RC): $CHILD_TEARDOWN_OUT"
assert_not_contains "$CHILD_TEARDOWN_OUT" "cannot resolve the primary home" \
  "a cross-machine parent must never be reported as an unresolved binding"
pass "a remote secondmate's finished worker cleans up when the remote code root's own .env looked relay-active"

# Case C-equivalent: FMX_PAIRING_TOKEN exported directly in the process
# environment, simulating the remote host's own login-shell export reaching the
# agent's pane. fm_pf_relay_active's environment-wins rule would make this look
# identical to a genuine same-home commitment; the fix must tell them apart by
# reading only $FM_HOME/.env, never the process environment, once the durable
# record says the parent is remote.
run_child_teardown FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$DELIVERED" FMX_PAIRING_TOKEN=ambient-login-token
[ "$CHILD_TEARDOWN_RC" -eq 0 ] \
  || fail "a remote-routed child must allow cleanup when only an ambient exported token looks relay-active (rc=$CHILD_TEARDOWN_RC): $CHILD_TEARDOWN_OUT"
assert_not_contains "$CHILD_TEARDOWN_OUT" "cannot resolve the primary home" \
  "an ambient exported token from the remote host's own shell must never bind this child"
pass "a remote secondmate's finished worker cleans up when only an ambient exported token looked relay-active"

# Baseline: no signal anywhere. Must keep succeeding exactly as before the fix.
run_child_teardown
[ "$CHILD_TEARDOWN_RC" -eq 0 ] \
  || fail "a remote-routed child with no relay signal anywhere must allow cleanup (rc=$CHILD_TEARDOWN_RC): $CHILD_TEARDOWN_OUT"
pass "a remote secondmate's finished worker cleans up with no relay signal anywhere"

# Protection-preserved case: THIS home's own .env file (not the process
# environment, not the remote code root) carries a real token. That is a
# genuine same-filesystem signal this child's own home could hold, so it must
# still refuse even though the parent route is remote.
printf 'FMX_PAIRING_TOKEN=child-own-token\n' > "$REMOTE_HOME/.env"
run_child_teardown
rm -f "$REMOTE_HOME/.env"
[ "$CHILD_TEARDOWN_RC" -ne 0 ] \
  || fail "a remote secondmate's own committed .env token must still refuse cleanup, got rc=0: $CHILD_TEARDOWN_OUT"
assert_contains "$CHILD_TEARDOWN_OUT" "cannot resolve the primary home" \
  "a genuine same-filesystem token on this home must remain an actionable refusal"
assert_present "$REMOTE_HOME/state/work-child.meta" \
  "a genuine refusal must preserve the child work metadata"
pass "a remote secondmate's own committed relay token still refuses cleanup"

FOREIGN_META="$TMP_ROOT/foreign-ios.meta"
LOCAL_META="$PARENT/state/ios.meta"
printf 'foreign sentinel\n' > "$FOREIGN_META"
cp "$LOCAL_META" "$TMP_ROOT/ios-meta-before-publication"
rm -f "$LOCAL_META"
PUBLICATION_RC=0
PUBLICATION_OUT=$(FM_TEST_PUBLICATION_TARGET="$LOCAL_META" \
  FM_TEST_PUBLICATION_FOREIGN="$FOREIGN_META" \
  remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) || PUBLICATION_RC=$?
[ "$PUBLICATION_RC" -ne 0 ] \
  || fail "remote secondmate publication accepted a target resolving outside its home"
assert_contains "$PUBLICATION_OUT" "task record could not be published" \
  "remote secondmate publication did not report its record-boundary refusal"
cmp -s "$FOREIGN_META" <(printf 'foreign sentinel\n') \
  || fail "remote secondmate publication wrote through the foreign target"
[ -L "$LOCAL_META" ] \
  || fail "remote secondmate publication replaced the refused target boundary"
pass "remote secondmate publication refuses targets outside its home"

# The parent-side retirement archive must reject a pre-existing symlink before
# it can write the summary returned by the remote host. Drop the in-flight
# child left by the refusal case above so this retire can finish on the host
# and actually emit a summary. The remote home is intentionally consumed; the
# parent route and metadata must remain for a safe retry after the path is
# repaired.
rm -f "$REMOTE_HOME/state/work-child.meta"
rm -f "$LOCAL_META"
cp "$TMP_ROOT/ios-meta-before-publication" "$LOCAL_META"
REMOTE_SUMMARY_EXTERNAL="$TMP_ROOT/remote-summary-external"
mkdir -p "$REMOTE_SUMMARY_EXTERNAL"
printf 'external sentinel\n' > "$REMOTE_SUMMARY_EXTERNAL/keep"
rm -rf "$PARENT/data/ios"
ln -s "$REMOTE_SUMMARY_EXTERNAL" "$PARENT/data/ios"
if remote_env "$ROOT/bin/fm-teardown.sh" ios > "$TMP_ROOT/remote-summary-symlink.out" 2>&1; then
  fail "remote teardown accepted a symlinked parent retirement summary directory"
fi
grep -F 'retirement summary directory is unsafe' "$TMP_ROOT/remote-summary-symlink.out" >/dev/null \
  || fail "remote teardown did not refuse the symlinked parent retirement summary directory: $(cat "$TMP_ROOT/remote-summary-symlink.out")"
[ -L "$PARENT/data/ios" ] || fail "remote teardown replaced the parent retirement summary symlink"
[ "$(cd "$REMOTE_SUMMARY_EXTERNAL" && find . -mindepth 1 -print | sort)" = './keep' ] \
  || fail "remote teardown changed the external retirement summary target"
assert_absent "$REMOTE_HOME" \
  "remote summary symlink refusal did not consume the already-retired remote home"
assert_present "$PARENT/state/ios.meta" \
  "remote summary symlink refusal removed the parent endpoint metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" \
  "remote summary symlink refusal removed the registry route"
pass "remote parent retirement refuses a symlinked summary directory before writing"

# A stale same-id summary must not satisfy a later default remote retirement
# when the remote host reports that the home was already gone and emits no new
# summary block.
rm -f "$PARENT/data/ios"
mkdir -p "$PARENT/data/ios"
printf 'stale summary from an earlier retirement\n' > "$PARENT/data/ios/retirement.md"
if [ -e "$REMOTE_HOME" ] || [ -L "$REMOTE_HOME" ]; then
  fail "remote home returned before the stale retire: $(ls -ld "$REMOTE_HOME" 2>&1; find "$REMOTE_HOME" -maxdepth 2 2>&1 | head -40)"
fi
if remote_env "$ROOT/bin/fm-teardown.sh" ios > "$TMP_ROOT/remote-stale-summary.out" 2>&1; then
  fail "remote teardown accepted a stale same-id retirement summary: $(cat "$TMP_ROOT/remote-stale-summary.out")"
fi
grep -F 'could not record a parent-visible retirement summary' "$TMP_ROOT/remote-stale-summary.out" >/dev/null \
  || fail "stale remote summary refusal did not preserve the parent route: $(cat "$TMP_ROOT/remote-stale-summary.out")"
grep -F 'already-retired:' "$TMP_ROOT/remote-stale-summary.out" >/dev/null \
  || fail "stale retire was not an already-gone home (home now: $(ls -ld "$REMOTE_HOME" 2>&1)): $(cat "$TMP_ROOT/remote-stale-summary.out")"
grep -F 'stale summary from an earlier retirement' "$PARENT/data/ios/retirement.md" >/dev/null \
  || fail "stale remote summary refusal replaced the pre-existing summary"
assert_present "$PARENT/state/ios.meta" \
  "stale remote summary refusal removed the parent endpoint metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" \
  "stale remote summary refusal removed the registry route"
pass "remote retirement requires a summary emitted by the current attempt"

# --force remains the discard path for a completed remote retire that printed
# no summary. It must still finish after the refusal above.
if ! remote_env "$ROOT/bin/fm-teardown.sh" ios --force > "$TMP_ROOT/remote-force-no-summary.out" 2>&1; then
  fail "remote --force did not finish a completed retire that emitted no summary: $(cat "$TMP_ROOT/remote-force-no-summary.out")"
fi
grep -F 'no parent-visible retirement summary' "$TMP_ROOT/remote-force-no-summary.out" >/dev/null \
  || fail "remote --force did not report continuing without a summary: $(cat "$TMP_ROOT/remote-force-no-summary.out")"
grep -F 'stale summary from an earlier retirement' "$PARENT/data/ios/retirement.md" >/dev/null \
  || fail "remote --force replaced the pre-existing summary it was allowed to skip"
assert_absent "$PARENT/state/ios.meta" \
  "remote --force left the parent endpoint metadata in place"
assert_no_grep '- ios ' "$PARENT/data/secondmates.md" \
  "remote --force left the registry route in place"
pass "remote --force finishes a completed retire that emitted no summary"

echo "ALL TESTS PASSED"
