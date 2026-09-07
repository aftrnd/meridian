# Branching & Release Strategy

Meridian uses **trunk-based development with short-lived branches** — the right weight for a small team shipping a pre-1.0 app.

## Branches

| Branch | Purpose | Rules |
|--------|---------|-------|
| `main` | The trunk. Always buildable; every commit could become a release. | Never force-push. All work merges here. |
| `<type>/<topic>` | Short-lived work branches, e.g. `perf/ui-main-thread`, `fix/steam-auth-retry`, `feat/cloud-saves`. | Branch from `main`, merge back with `--no-ff` (or a PR), delete after merge. Days not weeks. |
| `backup/*` | Ad-hoc safety snapshots before risky operations. | Fine to keep locally; prune when stale. |

Branch types mirror commit prefixes: `feat/`, `fix/`, `perf/`, `docs/`, `chore/`, `refactor/`.

**Do NOT create version-named branches** (`v0.9.13`). Versions are tags, not branches — a branch named like a tag shadows it and confuses `git checkout`. (Legacy `v0.9.13` / `v0.9.14.0` branches predate this doc and can be deleted; the tags preserve those points.)

## Commits

Conventional-commit style, matching existing history:

```
perf(ui): move image decode off the main actor
fix(online): stop wiping localconfig.vdf
feat(friends): Discord-style friends panel
```

Types: `feat`, `fix`, `perf`, `docs`, `chore`, `refactor`, `test`. Scope is the module or feature area.

## Versioning (SemVer, pre-1.0)

App releases are **3-part tags**: `v0.MINOR.PATCH`.

- `v0.x.0` — feature releases (new capability, UI additions)
- `v0.x.y` — patch releases (fixes, perf work, no new features)
- **Drop the 4th component** — `v0.9.14.0` should have been `v0.9.14`. Next release after `v0.9.16.0` is `v0.9.17` (or `v0.10.0` if it ships features).
- `v1.0.0` when the app is ready for general users: stable bootstrap, reliable online + offline launch paths, no known data-loss bugs.

While pre-1.0, breaking/behavioral changes are allowed in minor bumps — that's what 0.x means.

### Engine tags (separate artifact line)

The Wine engine tarball has its own lifecycle and its own tag suffix: `vX.Y.Z-engine` (created by `Scripts/release-engine.sh`). This is intentional — engine versions move independently of app versions. Keep the `-engine` suffix; never tag an app release with it.

## Release flow

1. Land work on `main` via merged branches.
2. Bump the marketing version (Xcode project / Info.plist) in a `chore(release): v0.x.y` commit.
3. Tag: `git tag v0.x.y && git push origin v0.x.y`.
4. `Scripts/release-app.sh` builds/uploads the app artifact; engine releases go through `Scripts/release-engine.sh` independently.

## One-time cleanup (recommended)

```bash
# Version-named branches duplicate their tags — safe to delete (tags remain):
git push origin --delete v0.9.13 v0.9.14.0
git branch -d v0.9.13 v0.9.14.0
```
