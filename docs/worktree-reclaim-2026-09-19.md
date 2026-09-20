# Worktree disk reclaim, 2026-09-19

One-off manual pass. The recurring sweeper is a separate ticket and is not built here.

## Result

| | before | after |
|---|---|---|
| used | 875.9G | 727.6G |
| available | 20.8G | 169.2G |
| capacity | 98% | 82% |

**148.4G reclaimed**, measured with `df` on `/System/Volumes/Data` before and after, not by summing `du`.
APFS clonefile makes `du` overstate badly on this machine, so the per-tree `du` figures below rank trees but do not add up to the reclaim.

Worktrees: 64 on disk before, 20 after. `git worktree list` 66 -> 21 (the extra entry is the main checkout).

## How a worktree was cleared for removal

All five had to hold, each checked directly rather than inferred:

1. `git status --porcelain` empty - no modifications, no untracked files.
2. No unpushed commits: either an upstream with an empty `@{u}..HEAD`, or no commits of its own at all.
3. Merged into `origin/main` - `merge-base --is-ancestor HEAD origin/main`. A branch with **no upstream and commits not on main** was kept, since that case is invisible to `gh` and looks tidy without being tidy.
4. No live session, proven two independent ways, live if **either** says so: the daemon's `/api/sessions` on `:4280` filtered to `status == running` (reading both `cwd` and `worktreePath`), and `lsof -a -d cwd` for any process whose cwd is under the path.
5. Not the main checkout, and not the directory the launchd plist names.

Liveness and cleanliness were re-checked **immediately before each individual removal**, not once from the opening snapshot - the live set changes while the pass runs. Removal used `git worktree remove` with **no `--force`**, so a git refusal would have skipped that tree and been recorded. None refused.

## Two traps worth recording

**`git stash list` is repo-global, not per-worktree.** The first verdict pass read one shared stash entry from all 59 candidate trees and kept every one of them. There is exactly one stash, `3a660e77` (`orphan-reap WIP ... parked to build main 2026-09-10`), it lives in the shared `.git`, every worktree reports it, and removing a worktree cannot delete it. It is intact and was never a per-tree signal. Confirmed present after the pass.

**`dormant` is not a liveness signal.** The daemon returned 918 sessions, 609 of them `exited` + `dormant`. Dormant is session history, not a resumable session holding a tree. Only `status == running` means live - 8 trees at the start of the pass.

## Removed (44)

| worktree | du | branch | reason |
|---|---|---|---|
| 9b2a2db2 | 9.9G | juancode/9b2a2db2 | merged into origin/main |
| c2284350 | 8.5G | juancode/c2284350 | merged into origin/main |
| b4dfefc1 | 7.6G | juancode/b4dfefc1 | merged into origin/main |
| 9dff1843 | 7.3G | juancode/9dff1843 | merged into origin/main |
| 30953574 | 7.0G | juancode/30953574 | merged into origin/main |
| 75c5b03c | 6.2G | juancode/75c5b03c | merged into origin/main |
| ce3535c3 | 5.7G | juancode/ce3535c3 | merged into origin/main |
| e070db0c | 5.7G | juancode/e070db0c | merged into origin/main |
| 5cb53a18 | 5.5G | juancode/5cb53a18 | merged into origin/main |
| f90f8d27 | 5.4G | juancode/f90f8d27 | merged into origin/main |
| ef55ac9b | 5.3G | juancode/ef55ac9b | merged into origin/main |
| 7c86b2f0 | 5.3G | juancode/7c86b2f0 | merged into origin/main |
| c57e9150 | 5.3G | juancode/c57e9150 | merged into origin/main |
| 568466f5 | 5.3G | juancode/568466f5 | merged into origin/main |
| ea0a1a4b | 5.3G | juancode/ea0a1a4b | merged into origin/main |
| 78e42404 | 4.7G | juancode/78e42404 | merged into origin/main |
| d59556a9 | 4.6G | juancode/d59556a9 | merged into origin/main |
| 145cba5c | 4.4G | juancode/145cba5c | merged into origin/main |
| 82964616 | 4.2G | juancode/82964616 | merged into origin/main |
| 1ed99c8c | 4.1G | juancode/1ed99c8c | merged into origin/main |
| e62ef3fe | 3.6G | juancode/e62ef3fe | merged into origin/main |
| b2498382 | 2.8G | juancode/b2498382 | merged into origin/main |
| 3f172076 | 2.8G | juancode/3f172076 | merged into origin/main |
| 92a31d58 | 2.8G | juancode/92a31d58 | merged into origin/main |
| 71b173f8 | 2.8G | juancode/71b173f8 | merged into origin/main |
| d4820687 | 2.8G | juancode/d4820687 | merged into origin/main |
| eb10451b | 2.7G | juancode/eb10451b | merged into origin/main |
| 99c71513 | 2.4G | juancode/99c71513 | merged into origin/main |
| 40686caa | 2.3G | juancode/40686caa | merged into origin/main |
| 0d93c181 | 2.2G | juancode/0d93c181 | merged into origin/main |
| 9b46fbb5 | 2.2G | juancode/9b46fbb5 | merged into origin/main |
| 0bbde86f | 1.9G | juancode/0bbde86f | merged into origin/main |
| 875cc367 | 0.8G | juancode/875cc367 | merged into origin/main |
| 4615bce2 | 0.7G | juancode/4615bce2 | merged into origin/main |
| 81ae97f9 | 0.0G | juancode/81ae97f9 | merged into origin/main |
| 8ba9ebd8 | 0.0G | juancode/8ba9ebd8 | merged into origin/main |
| c385fd32 | 0.0G | juancode/c385fd32 | merged into origin/main |
| dc257894 | 0.0G | juancode/dc257894 | merged into origin/main |
| 6f571945 | 0.0G | juancode/6f571945 | merged into origin/main |
| 7472ef55 | 0.0G | juancode/7472ef55 | merged into origin/main |
| 73bf6644 | 0.0G | juancode/73bf6644 | merged into origin/main |
| 5ad4fa32 | 0.0G | juancode/5ad4fa32 | merged into origin/main |
| e1cfc5f4 | 0.0G | juancode/e1cfc5f4 | merged into origin/main |
| 036b8aa2 | 0.0G | juancode/036b8aa2 | merged into origin/main |

## Kept (20)

| worktree | du | branch | reason |
|---|---|---|---|
| ec7ea006 | 5.9G | juancode/ec7ea006 | live session in this worktree |
| 792b6bf2 | 4.1G | juancode/792b6bf2 | live session in this worktree |
| d81ec564 | 3.5G | juancode/d81ec564 | not provably merged into origin/main |
| dc424f42 | 3.0G | juancode-uchf-global-pause | not provably merged into origin/main |
| 242d917b | 2.8G | juancode/242d917b | live session in this worktree |
| 0fc8d490 | 2.8G | juancode/0fc8d490 | not provably merged into origin/main |
| 6c706483 | 2.6G | juancode/6c706483 | not provably merged into origin/main |
| 0602eb22 | 2.3G | juancode/0602eb22 | not provably merged into origin/main |
| 7913c781 | 2.0G | juancode/7913c781 | not provably merged into origin/main |
| 46c74c61 | 1.9G | juancode/46c74c61 | not provably merged into origin/main |
| 63936f40 | 0.8G | juancode/63936f40 | 1 unpushed commits |
| 458f90cd | 0.8G | juancode/458f90cd | not provably merged into origin/main |
| b93f7407 | 0.8G | juancode/b93f7407 | no upstream, 3 commits not on origin/main |
| e4671be3 | 0.7G | juancode/e4671be3 | not provably merged into origin/main |
| 027e0ce5 | 0.0G | juancode/027e0ce5 | live session in this worktree |
| 1e6aa209 | 0.0G | juancode/1e6aa209 | live session in this worktree (executor's own tree) |
| 2001ba63 | 0.0G | juancode/2001ba63 | not provably merged into origin/main |
| 8a7beb6e | 0.0G | juancode/8a7beb6e | not provably merged into origin/main |
| 5396b7e8 | 0.0G | juancode/5396b7e8 | not provably merged into origin/main |
| 5d6cbacf | 0.0G | juancode/4pmw-ci-gate | not provably merged into origin/main |

Of the kept trees, 13 are branches pushed to origin but not merged into main, 5 held live sessions, 1 had unpushed commits, and 1 had no upstream and 3 commits not on main. Every one of those is work that exists nowhere else, or exists only on a branch somebody still wants.

## Build caches dropped from kept, non-live worktrees (11)

Regenerable by definition, so deleting one costs a rebuild and nothing else. Cut: untouched for at least 2 days, so a paused session's warm cache survives.

| worktree | cache | du | age |
|---|---|---|---|
| d81ec564 | apps/juancoded/target | 3.5G | 11d |
| dc424f42 | apps/juancoded/target | 2.9G | 10d |
| 0fc8d490 | apps/juancoded/target | 2.8G | 12d |
| 6c706483 | apps/juancoded/target | 2.6G | 9d |
| 0602eb22 | apps/juancoded/target | 2.3G | 11d |
| 7913c781 | apps/juancoded/target | 2.0G | 11d |
| 46c74c61 | apps/juancoded/target | 1.9G | 11d |
| 63936f40 | apps/juancoded/target | 0.8G | 11d |
| 458f90cd | apps/juancoded/target | 0.8G | 9d |
| b93f7407 | apps/juancoded/target | 0.8G | 9d |
| e4671be3 | apps/juancoded/target | 0.7G | 12d |

Skipped caches: `792b6bf2` (both touched 0.1d ago, inside the staleness cut), `242d917b` and `ec7ea006` (live sessions). The main checkout's own `.build` and `target` were never touched - they are out of scope, and the running GUI executes from `apps/native/.build/juancode.app`.

## Concurrency

The ticket was dispatched twice, to `1e6aa209` and `ee66b7b3`. `ee66b7b3` took an exclusive lock (`~/.juancode/worktree-reclaim.lock`, an atomic `mkdir` with an owner file) at 18:22:03Z and asked this session to stand down. This session verified that claim, stood down, and stopped its own scans so as not to compete for IO.

`ee66b7b3` then exited mid-execution - pid gone, socket gone, no longer in the daemon's running list - having removed 2 worktrees, leaving the lock held by a dead owner. Git metadata was checked and was clean: no prunable or locked entries, `git worktree prune -n` reported nothing, so its removals had completed properly rather than being torn in half.

The takeover was put to the user rather than taken unilaterally, and approved. The lock owner file now records the takeover, and the dead owner's record is preserved beside it as `owner.stale-ee66b7b3`.

RESOLVED 2026-09-20 (`juancode-cufa`). That lock was still on disk a day later, held by a session gone since 19:22Z, because nothing released it and `mkdir` alone cannot tell a dead holder from a live one. It is now `scripts/lib/run-lock.mjs`: the claim carries a pid, a reader that finds that pid gone takes the lock over and says so in the sweep log, and `--apply` takes it before it scans. The directory this pass left was removed, and its exact bytes are a test case - a claim with no pid at all reads as stale, because "we cannot check" must never mean "held forever".

Unrelated but noticed: `juancode-29ci` was also double-dispatched, to `027e0ce5` and `6b4c890e`, both titled "daily worktree sweeper" and both writing into `scripts/`.
