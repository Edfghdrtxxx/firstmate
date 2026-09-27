# Secondmate project storage

How a local secondmate home stores its project checkouts, why, and what was evaluated instead.
`bin/fm-home-seed.sh` `clone_project` owns the mechanism; this note owns the rationale.

## Current mechanism

Each seeded project is a hardlinked local clone of the parent's checkout: `git clone --local <parent>/projects/<name> <home>/projects/<name>`, followed by `git remote set-url origin <url>` so the seeded repo's remote is identical to a clone from the origin URL.
`--local` hardlinks the parent's object files at seed time, so the duplicated `.git` object store a full network clone would pay - ~1.7 GB in the 2026-09-26 audit of one secondmate home - is stored once.
From the moment the clone completes the two repositories are fully independent: the mate owns its own `.git`, refs, config, and `origin`, and `fm-fleet-sync.sh` and mate workers never touch the parent's repository state.
If the parent's packs are later repacked or replaced, a hardlinked mate keeps the old bytes by inode; it never corrupts, it merely stops sharing.
When the local clone fails, seeding falls back to cloning the origin URL.

## Evaluated alternatives

`git worktree add` was rejected.
A linked worktree shares the parent's ref namespace and `.git/config`, so the mate's `fetch --prune`, branch creation, and `no-mistakes init` would write the parent's repository state, and the parent's checked-out default branch would force every seeded project into a detached HEAD - `fm-fleet-sync.sh` reads that as a stuck project it cannot re-attach.
Deleting a linked worktree with `rm -rf`, which home removal does, also leaves stale `worktrees/` admin entries in the parent's repo until `git worktree prune` runs.
The existing-destination origin check would become tautological, reading the parent's own shared `origin` config.

`git clone --shared` and `git clone --reference` were rejected.
Both write `.git/objects/info/alternates` pointing at the parent's object store, a permanent dependency the referenced repository never learns about: repacking, pruning, or recloning the parent's project silently corrupts the mate.
Their only gain over `--local` is deduplicating future fetches, which is exactly the coupling that makes them unsafe.

## Invariants the choice preserves

- A seeded project is always a standalone clone with its own `.git` directory, refs, and config; `seeded_origin_url` keeps proving the seeded `origin` matches the parent's recorded URL.
- The seeded checkout lands on origin's default branch, matching a clone straight from the URL: after repointing `origin`, a `fetch --prune` reconciles remote-tracking refs and prunes the local-only branches `--local` copied, and the seed checks out that default; the parent's currently checked-out or unpushed topic branch never becomes the mate's baseline.
- Project checkouts stay inside `projects/`, which is gitignored and never swept by the tracked-file fast-forward channel (`bin/fm-ff-lib.sh` syncs only the home checkout).
- `fm-fleet-sync.sh` runs per home over that home's `projects/`; under `--local` each home's fetches prune and update only its own remote-tracking refs.
- Remote secondmate provisioning is unaffected: it operates on another host where the parent's clone does not exist, and its checks assume a plain `.git` directory - `--local` produces exactly that.
- Post-seed growth is not deduplicated: each home downloads its own new objects on fetch. That bound is deliberate - it is the price of full repository independence.

## Regression coverage

`tests/fm-secondmate-safety.test.sh` covers seeded-project origin identity, `local-only` refusal, and destination-safety checks, all of which hold under `--local`.
`tests/fm-secondmate-lifecycle-e2e.test.sh` pins the end-to-end seed, including that seed-time `no-mistakes init` state must not appear in the parent's clone - the isolation invariant that rules out linked worktrees.
