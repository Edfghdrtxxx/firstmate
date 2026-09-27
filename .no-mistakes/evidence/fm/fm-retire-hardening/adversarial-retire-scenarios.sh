#!/usr/bin/env bash
# adversarial-retire-scenarios.sh - live adversarial drives against the real
# bin/fm-teardown.sh / bin/fm-home-seed.sh for the retire-hardening change.
set -u
ROOT="/Users/leyi/.no-mistakes/worktrees/eb15410c16eb/01M3GZWGRNPEYCN8WET5ZCSSCR"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-retire-adversarial)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

echo "=== S-A: nested-prefix intermediate symlink under --force ==="
sa_home="$TMP_ROOT/sa-home"; sa_sub="$TMP_ROOT/sa-subhome"; sa_child="$TMP_ROOT/sa-childhome"
sa_gc="$TMP_ROOT/sa-gchome"; sa_ext="$TMP_ROOT/sa-external"
mkdir -p "$sa_home/state" "$sa_home/data" "$sa_sub/state" "$sa_sub/data" \
  "$sa_child/state" "$sa_child/data" "$sa_gc/state" "$sa_gc/data" "$sa_ext" \
  "$sa_home/data/domain/nested"
printf 'external sentinel\n' > "$sa_ext/keep"
mark_firstmate_home "$sa_sub"; mark_firstmate_home "$sa_child"; mark_firstmate_home "$sa_gc"
printf 'domain\n' > "$sa_sub/.fm-secondmate-home"
printf 'nested\n' > "$sa_child/.fm-secondmate-home"
printf 'gc\n' > "$sa_gc/.fm-secondmate-home"
printf 'grandchild learning\n' > "$sa_gc/data/learnings.md"
fm_write_secondmate_meta "$sa_home/state/domain.meta" "$sa_sub"
fm_write_secondmate_meta "$sa_sub/state/nested.meta" "$sa_child"
fm_write_secondmate_meta "$sa_child/state/gc.meta" "$sa_gc"
cat > "$sa_home/data/secondmates.md" <<REG
- domain - design domain (home: $sa_sub; scope: design domain; projects: alpha; added 2026-06-22)
- nested - nested domain (home: $sa_child; scope: nested domain; projects: beta; added 2026-06-22)
- gc - grandchild domain (home: $sa_gc; scope: grandchild domain; projects: gamma; added 2026-06-22)
REG
ln -s "$sa_ext" "$sa_home/data/domain/nested/nested"
sa_fake=$(make_fake_tmux "$TMP_ROOT/sa-fake")
sa_err="$TMP_ROOT/sa.err"
if PATH="$sa_fake:$PATH" FM_HOME="$sa_home" \
  FM_FAKE_TMUX_LOG="$TMP_ROOT/sa-fake/tmux.log" \
  FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/sa-fake/pane.txt" \
  "$ROOT/bin/fm-teardown.sh" domain --force >"$TMP_ROOT/sa.out" 2>"$sa_err"; then
  fail "S-A: force teardown accepted an intermediate nested-prefix symlink"
fi
grep -F 'retirement summary directory is unsafe' "$sa_err" >/dev/null \
  || fail "S-A: refusal did not explain the unsafe directory: $(cat "$sa_err")"
[ -L "$sa_home/data/domain/nested/nested" ] || fail "S-A: teardown replaced the intermediate symlink"
[ "$(cd "$sa_ext" && find . -mindepth 1 -print | sort)" = './keep' ] \
  || fail "S-A: teardown wrote through the intermediate symlink"
[ -d "$sa_sub" ] || fail "S-A: teardown removed the mate home after the refusal"
[ -f "$sa_home/state/domain.meta" ] || fail "S-A: teardown removed parent metadata after the refusal"
grep -F -- '- domain ' "$sa_home/data/secondmates.md" >/dev/null \
  || fail "S-A: teardown removed the registry route after the refusal"
pass "S-A: force teardown refuses a nested-prefix intermediate symlink before any write"

echo "=== S-B: planted *.tmp.\$\$ symlinks on a happy-path retire ==="
sb_home="$TMP_ROOT/sb-home"; sb_sub="$TMP_ROOT/sb-subhome"; sb_vics="$TMP_ROOT/sb-victims"
mkdir -p "$sb_home/state" "$sb_home/data" "$sb_sub/state" "$sb_sub/data/scout-x" "$sb_vics"
mark_firstmate_home "$sb_sub"
printf 'domain\n' > "$sb_sub/.fm-secondmate-home"
printf 'report content\n' > "$sb_sub/data/scout-x/report.md"
printf '# Backlog\n\n## Queued\n\n- [ ] sb-item - queued work (repo: alpha)\n' > "$sb_sub/data/backlog.md"
fm_write_secondmate_meta "$sb_home/state/domain.meta" "$sb_sub"
printf '%s\n' "- domain - design domain (home: $sb_sub; scope: design domain; projects: alpha; added 2026-06-22)" \
  > "$sb_home/data/secondmates.md"
sb_fake=$(make_fake_tmux "$TMP_ROOT/sb-fake")
printf 'victim summary\n' > "$sb_vics/summary"
printf 'victim report\n' > "$sb_vics/report"
printf 'victim registry\n' > "$sb_vics/registry"
printf 'victim retire\n' > "$sb_vics/retire"
PATH="$sb_fake:$PATH" \
  FM_HOME="$sb_home" \
  FM_FAKE_TMUX_LOG="$TMP_ROOT/sb-fake/tmux.log" \
  FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/sb-fake/pane.txt" \
  SB_HOME="$sb_home" SB_VICS="$sb_vics" ROOT="$ROOT" \
  /bin/bash -c '
p=$$
mkdir -p "$SB_HOME/data/domain/reports"
ln -s "$SB_VICS/summary"   "$SB_HOME/data/domain/retirement.md.tmp.$p"
ln -s "$SB_VICS/report"    "$SB_HOME/data/domain/reports/scout-x.md.tmp.$p"
ln -s "$SB_VICS/registry"  "$SB_HOME/data/secondmates.md.tmp.$p"
ln -s "$SB_VICS/retire"    "$SB_HOME/state/domain.home-retire.tmp.$p"
exec "$ROOT/bin/fm-teardown.sh" domain
' >"$TMP_ROOT/sb.out" 2>"$TMP_ROOT/sb.err" \
  || fail "S-B: happy-path retire failed under planted tmp symlinks: $(cat "$TMP_ROOT/sb.err")"
[ "$(cat "$sb_vics/summary")" = 'victim summary' ] || fail "S-B: summary tmp symlink redirected a write outside the parent"
[ "$(cat "$sb_vics/report")" = 'victim report' ] || fail "S-B: report tmp symlink redirected a write outside the parent"
[ "$(cat "$sb_vics/registry")" = 'victim registry' ] || fail "S-B: registry tmp symlink redirected a write outside the parent"
[ "$(cat "$sb_vics/retire")" = 'victim retire' ] || fail "S-B: retire-record tmp symlink redirected a write outside the parent"
# A state/domain.home-retire.tmp.$$ link is expected to survive: the obligation
# record is only written when home removal fails, and this retire succeeded.
[ -L "$sb_home/state/domain.home-retire.tmp."* ] 2>/dev/null || true
for f in "$sb_home/data/domain/retirement.md.tmp."* "$sb_home/data/secondmates.md.tmp."* \
         "$sb_home/data/domain/reports/scout-x.md.tmp."*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  fail "S-B: leftover tmp path survived the retire: $f"
done
[ -f "$sb_home/data/domain/retirement.md" ] && [ ! -L "$sb_home/data/domain/retirement.md" ] \
  || fail "S-B: retire did not archive a real retirement.md"
grep -F 'sb-item' "$sb_home/data/domain/retirement.md" >/dev/null \
  || fail "S-B: archived summary dropped the queued backlog row"
[ -f "$sb_home/data/domain/reports/scout-x.md" ] && [ ! -L "$sb_home/data/domain/reports/scout-x.md" ] \
  || fail "S-B: retire did not archive a real report capture"
grep -F 'report content' "$sb_home/data/domain/reports/scout-x.md" >/dev/null \
  || fail "S-B: archived report lost its content"
[ ! -d "$sb_sub" ] || fail "S-B: retire left the secondmate home on disk"
[ ! -e "$sb_home/state/domain.meta" ] || fail "S-B: retire left parent metadata"
! grep -F -- '- domain ' "$sb_home/data/secondmates.md" >/dev/null \
  || fail "S-B: retire left the registry route"
pass "S-B: happy-path retire ignores planted tmp symlinks, archives inside the parent"

echo "=== S-C: seed-rollback obligation tmp symlink ==="
sc_home="$TMP_ROOT/sc-home"; sc_acquired="$TMP_ROOT/sc-acquired"; sc_vics="$TMP_ROOT/sc-victims"
sc_err="$TMP_ROOT/sc.err"
mkdir -p "$sc_home/projects" "$sc_home/data" "$sc_home/state" "$sc_vics"
fm_git_init_commit "$sc_home/projects/alpha"
fm_git_add_origin "$sc_home/projects/alpha" "$TMP_ROOT/remotes/sc-alpha.git"
printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$sc_home/data/projects.md"
git clone --quiet "$ROOT" "$sc_acquired"
printf 'other\n' > "$sc_acquired/.fm-secondmate-home"
sc_fake=$(make_fake_tmux "$TMP_ROOT/sc-fake")
printf 'dash\n' > "$TMP_ROOT/sc-fake/lease"
printf 'victim obligation\n' > "$sc_vics/obligation"
if PATH="$sc_fake:$PATH" \
  FM_HOME="$sc_home" \
  FM_FAKE_TREEHOUSE_HOME="$sc_acquired" \
  FM_FAKE_TMUX_LOG="$TMP_ROOT/sc-fake/tmux.log" \
  FM_FAKE_TREEHOUSE_LEASE_FILE="$TMP_ROOT/sc-fake/lease" \
  FM_FAKE_TREEHOUSE_DESTROY_FAIL=1 \
  FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
  SC_HOME="$sc_home" SC_VICS="$sc_vics" ROOT="$ROOT" \
  /bin/bash -c '
p=$$
ln -s "$SC_VICS/obligation" "$SC_HOME/state/other.home-retire.tmp.$p"
exec "$ROOT/bin/fm-home-seed.sh" dash - alpha
' >"$TMP_ROOT/sc.out" 2>"$sc_err"; then
  fail "S-C: seed reused an acquired home when destroy was set to fail"
fi
grep -F 'already marked for other' "$sc_err" >/dev/null \
  || fail "S-C: seed did not reach the rollback path: $(cat "$sc_err")"
[ "$(cat "$sc_vics/obligation")" = 'victim obligation' ] \
  || fail "S-C: obligation tmp symlink redirected the seed-rollback write outside the parent"
[ -f "$sc_home/state/other.home-retire" ] && [ ! -L "$sc_home/state/other.home-retire" ] \
  || fail "S-C: seed rollback did not record the obligation as a real file"
grep -F 'id=other' "$sc_home/state/other.home-retire" >/dev/null \
  || fail "S-C: seed rollback obligation lost its content"
for f in "$sc_home/state/other.home-retire.tmp."*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  fail "S-C: leftover obligation tmp symlink survived: $f"
done
pass "S-C: seed rollback unlinks a planted obligation tmp symlink before writing"

echo "=== S-D: remote retire store tmp symlink over the fake-SSH boundary ==="
sd_parent="$TMP_ROOT/sd-parent"; sd_vics="$TMP_ROOT/sd-victims"
sd_remote_home="$TMP_ROOT/sd-remote-home"; sd_fake="$TMP_ROOT/sd-fakebin"
sd_remote_root="$TMP_ROOT/sd-remote-root"
mkdir -p "$sd_parent/data" "$sd_parent/state" "$sd_parent/config" "$sd_vics" \
  "$sd_fake" "$sd_remote_home"
# fm-on.sh requires the remote code root to be a real tracked checkout.
git clone --quiet "$ROOT" "$sd_remote_root"
REMOTE_ROOT_RESOLVED=$(cd "$sd_remote_root" && pwd -P)
cat > "$sd_fake/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
printf 'FM_RETIRE_SUMMARY_BEGIN\n'
printf 'fresh remote retirement summary\n'
printf 'FM_RETIRE_SUMMARY_END\n'
exit 0
SH
chmod +x "$sd_fake/fake-ssh"
fm_write_meta "$sd_parent/state/ios.meta" \
  "window=remote:ios" \
  "endpoint_task_id=ios" \
  "kind=secondmate" \
  "mode=secondmate" \
  "harness=codex" \
  "yolo=off" \
  "remote_host=remote-mac" \
  "remote_root=$REMOTE_ROOT_RESOLVED" \
  "remote_herdr_session=fm-remote" \
  "home=$sd_remote_home" \
  "projects=alpha"
printf '%s\n' "- ios - iOS delivery (host: remote-mac; root: $REMOTE_ROOT_RESOLVED; home: $sd_remote_home; scope: iOS work; projects: alpha; added 2026-08-04)" \
  > "$sd_parent/data/secondmates.md"
printf 'victim remote summary\n' > "$sd_vics/remote-summary"
printf 'victim remote registry\n' > "$sd_vics/remote-registry"
if PATH="$sd_fake:$PATH" \
  FM_HOME="$sd_parent" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT_RESOLVED" \
  FM_SSH_BIN="$sd_fake/fake-ssh" \
  SD_PARENT="$sd_parent" SD_VICS="$sd_vics" ROOT="$ROOT" \
  /bin/bash -c '
p=$$
mkdir -p "$SD_PARENT/data/ios"
ln -s "$SD_VICS/remote-summary"  "$SD_PARENT/data/ios/retirement.md.tmp.$p"
ln -s "$SD_VICS/remote-registry" "$SD_PARENT/data/secondmates.md.tmp.$p"
exec "$ROOT/bin/fm-teardown.sh" ios
' >"$TMP_ROOT/sd.out" 2>"$TMP_ROOT/sd.err"; then
  echo "S-D teardown rc=0"
else
  echo "S-D teardown rc=$?"; cat "$TMP_ROOT/sd.out" "$TMP_ROOT/sd.err"
fi
[ "$(cat "$sd_vics/remote-summary")" = 'victim remote summary' ] \
  || fail "S-D: remote summary tmp symlink redirected a write outside the parent"
[ "$(cat "$sd_vics/remote-registry")" = 'victim remote registry' ] \
  || fail "S-D: remote registry tmp symlink redirected a write outside the parent"
[ -f "$sd_parent/data/ios/retirement.md" ] && [ ! -L "$sd_parent/data/ios/retirement.md" ] \
  || fail "S-D: remote retire did not store a real parent-visible summary"
grep -F 'fresh remote retirement summary' "$sd_parent/data/ios/retirement.md" >/dev/null \
  || fail "S-D: stored summary did not carry this attempt's content"
pass "S-D: remote retire store ignores planted tmp symlinks and stores the fresh summary"


echo "=== S-E: local retire obligation tmp symlink on resisted removal ==="
se_home="$TMP_ROOT/se-home"; se_sub="$TMP_ROOT/se-subhome"; se_vics="$TMP_ROOT/se-victims"
se_root="$TMP_ROOT/se-fmroot"; se_err="$TMP_ROOT/se.err"
make_firstmate_git_root "$se_root"
git -C "$se_root" worktree add --quiet --detach "$se_sub" HEAD
mkdir -p "$se_home/state" "$se_home/data" "$se_sub/state" "$se_vics"
printf 'domain\n' > "$se_sub/.fm-secondmate-home"
fm_write_secondmate_meta "$se_home/state/domain.meta" "$se_sub"
printf '%s\n' "- domain - design domain (home: $se_sub; scope: design domain; projects: alpha; added 2026-06-22)" \
  > "$se_home/data/secondmates.md"
se_fake=$(make_fake_tmux "$TMP_ROOT/se-fake")
printf 'domain\n' > "$TMP_ROOT/se-fake/lease"
printf 'victim retire record\n' > "$se_vics/retire-record"
PATH="$se_fake:$PATH" \
  FM_ROOT_OVERRIDE="$se_root" FM_HOME="$se_home" \
  FM_FAKE_TMUX_LOG="$TMP_ROOT/se-fake/tmux.log" \
  FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/se-fake/pane.txt" \
  FM_FAKE_TREEHOUSE_LEASE_FILE="$TMP_ROOT/se-fake/lease" \
  FM_FAKE_TREEHOUSE_DESTROY_FAIL=1 \
  SE_HOME="$se_home" SE_VICS="$se_vics" ROOT="$ROOT" \
  /bin/bash -c '
p=$$
ln -s "$SE_VICS/retire-record" "$SE_HOME/state/domain.home-retire.tmp.$p"
exec "$ROOT/bin/fm-teardown.sh" domain
' >"$TMP_ROOT/se.out" 2>"$se_err" \
  || fail "S-E: teardown failed when the returned home resisted removal: $(cat "$se_err")"
[ "$(cat "$se_vics/retire-record")" = 'victim retire record' ] \
  || fail "S-E: retire-record tmp symlink redirected a write outside the parent"
[ -f "$se_home/state/domain.home-retire" ] && [ ! -L "$se_home/state/domain.home-retire" ] \
  || fail "S-E: teardown did not record a real retirement obligation"
grep -F 'id=domain' "$se_home/state/domain.home-retire" >/dev/null \
  || fail "S-E: retirement obligation lost its content"
for f in "$se_home/state/domain.home-retire.tmp."*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  fail "S-E: leftover retire-record tmp symlink survived: $f"
done
pass "S-E: local retire unlinks a planted obligation tmp symlink before writing"

echo "ALL ADVERSARIAL SCENARIOS PASSED"
