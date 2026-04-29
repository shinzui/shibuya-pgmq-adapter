---
name: release
description: Release shibuya-pgmq-adapter to Hackage following PVP, coordinating with shibuya-core releases
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# Adapter Release Skill

Release the `shibuya-pgmq-adapter` package to Hackage. This repo
publishes a single library; the example app and benchmark suite are
not released.

## Versioning Strategy

The adapter follows a **shared version line with `shibuya-core`**: when
`shibuya-core` cuts a new release that affects the adapter (new
`Envelope` field, new `Shibuya.Core.*` API the adapter consumes,
breaking changes, etc.), bump the adapter to the same `A.B.C.D` so
users have a one-glance compatibility signal.

A single git tag `v<version>` marks each release.

## Packages

Released to Hackage:

1. **shibuya-pgmq-adapter** — the only library released from this repo.

NOT released:

- **shibuya-pgmq-example** — example consumer/simulator pair.
- **shibuya-pgmq-adapter-bench** — benchmark suite.

## Arguments

`$ARGUMENTS` is optional:
- `major`, `minor`, or `patch` — specifies the bump level.
- If omitted, determine the bump level from the changes (see step 2).

## Steps

### 1. Determine what changed since the last release

- Read the current version from
  `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`.
- Find the latest git tag matching `v*`. If none exists, this is the
  first release from this repo (the package was previously released
  from the monorepo at `shinzui/shibuya`); use the `Extracted from`
  commit recorded in `CHANGELOG.md` as the diff base, or just diff
  against the root commit if no anchor is recorded.
- Run `git log --oneline <last-tag>..HEAD` to list commits since the
  last release.
- If there are no commits since the last tag, inform the user there is
  nothing to release and stop.

Present a summary showing:
- Current cabal version
- Last release tag (or "none — first standalone release")
- Number of commits since last release
- The current `shibuya-core ^>=` bound declared in the cabal file
- The latest published `shibuya-core` version on Hackage (run
  `cabal update && cabal info shibuya-core | head` or check
  https://hackage.haskell.org/package/shibuya-core)

### 2. Determine the next version using PVP

The Haskell PVP version format is `A.B.C.D`:
- `A.B` — **major**: breaking API changes (removed/renamed exports,
  changed types, changed semantics).
- `C` — **minor**: backwards-compatible API additions (new exports,
  new modules, new instances).
- `D` — **patch**: bug fixes, docs, internal-only changes,
  performance.

Rules:
- If `$ARGUMENTS` is `major`, `minor`, or `patch`, use that bump
  level.
- If a new `shibuya-core` release is the trigger, the adapter typically
  matches `shibuya-core`'s bump level (a major in core that the
  adapter exposes through its own API surface ⇒ adapter major; a
  core-only addition the adapter merely depends on ⇒ adapter patch
  unless the adapter also gained API of its own).
- Otherwise analyse commits:
  - "breaking", "remove", "rename", "change type" → major
  - "add", "new", "feature", "export" → minor
  - "fix", "docs", "refactor", "internal" → patch
- Present the proposed bump to the user and ask for confirmation
  before proceeding.

Increment the version:
- **major**: increment `B`, reset `C` and `D` to 0.
- **minor**: increment `C`, reset `D` to 0.
- **patch**: increment `D`.

### 3. Verify upstream is on Hackage

The adapter cannot be released to Hackage if its `build-depends` are
satisfied only by a local sibling checkout — Hackage's build bot won't
have access to it.

- Read the declared `shibuya-core ^>=A.B.C.D` bound in
  `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`.
- Confirm `shibuya-core A.B.C.D` (or a compatible version) is
  published on Hackage:
  - `cabal update`
  - `cabal info shibuya-core` (or fetch
    https://hackage.haskell.org/package/shibuya-core)
- Inspect `cabal.project.local`. If it contains a `packages:` stanza
  pointing at `../shibuya/shibuya-core` (or any other local override
  that shadows a Hackage dep used by the adapter library), the
  override **must be removed or commented out** before the release —
  otherwise the local build is misleading and the sdist will fail to
  build on Hackage.
  - The `cabal.project.local` is gitignored, so removal is local-only;
    no commit needed for that file.
- Re-run `cabal build all` after removing the override to confirm the
  adapter still builds against the published `shibuya-core`.

If upstream isn't on Hackage yet, **stop**: cut the upstream
`shibuya-core` release first (using the sibling `shibuya/` repo's
`/release` skill), then re-run this skill.

### 4. Update version, dependency bound, and changelog

#### Version update
- Edit `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal` and set the
  new version.

#### Dependency bound update
- If this release is paired with a new `shibuya-core` major or minor,
  update the `shibuya-core ^>=A.B.C.D` bound to point at the new
  release, in **both** the `library` and `test-suite` sections.
- Use PVP-compatible bounds: `^>=A.B.C.D` matching the published
  release.

#### Changelog update
- `shibuya-pgmq-adapter/CHANGELOG.md`: add a new section above prior
  entries with today's date in `YYYY-MM-DD` format. Move content from
  any "Unreleased" section into the new version section.
- Root `CHANGELOG.md`: same treatment (this repo keeps two
  CHANGELOGs — root for repo-wide notes, package-level for the
  Hackage-shipped one).
- Group entries by:
  - **Breaking Changes** (if major)
  - **New Features** (if minor or major)
  - **Bug Fixes** (if any)
  - **Other Changes** (docs, build, internal)
  - Only include categories with entries.
- If the release is paired with a new `shibuya-core`, mention the new
  required lower bound under **Build** or **Other Changes**.

Show the user the full diff (version, dep bound, changelog entries)
for review before committing.

### 5. Verify builds

- Run `nix fmt` to ensure formatting is clean.
- Run `cabal build all` to confirm the cabal build still succeeds
  against the published `shibuya-core` (i.e. with no local override).
- Run `cabal test shibuya-pgmq-adapter-test` to confirm tests pass.
  Some tests require a running PostgreSQL instance — see this repo's
  `CLAUDE.md` / `Justfile` for `just db-up`. If the required services
  aren't running, ask the user before skipping tests.
- Run `nix flake check` to verify treefmt and pre-commit checks pass.
  - The flake exposes only `checks` / `devShells` / `formatter` (no
    `packages.default`), so `nix flake check` is the appropriate gate;
    `nix build` will fail with "does not provide attribute
    packages.<system>.default".
  - Note: newly created files must be `git add`-ed before nix
    evaluation will see them (nix uses the git tree).
  - If any check fails, fix the issue before proceeding.

### 6. Commit, tag, and push

- Stage the modified `.cabal` and both `CHANGELOG.md` files.
- Create a single commit using a Conventional Commits message:
  `chore(release): <new-version>` (project-wide convention — see
  global `CLAUDE.md`). The body should summarize what's in the release
  and, if applicable, which `shibuya-core` release this pairs with.
- Create a single annotated tag:
  `git tag -a v<version> -m "Release <version>"`.
- Push commit and tag: `git push && git push --tags`.

The commit and tag should only be created **after** user approval of
the diff in step 4.

### 7. Publish to Hackage

1. `cd shibuya-pgmq-adapter`
2. `cabal check` — verify no packaging issues.
3. `cabal test shibuya-pgmq-adapter-test` — final test run (skip only
   if previously confirmed; never skip silently).
4. `cabal sdist` from the repo root, then
   `cabal upload --publish dist-newstyle/sdist/shibuya-pgmq-adapter-<version>.tar.gz`.
5. `cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump shibuya-pgmq-adapter`,
   then
   `cabal upload --publish --documentation dist-newstyle/shibuya-pgmq-adapter-<version>-docs.tar.gz`.
6. Report the Hackage URL:
   `https://hackage.haskell.org/package/shibuya-pgmq-adapter-<version>`.

If the upload fails (e.g. "version already exists"), stop and report
to the user — do **not** retry blindly.

### 8. Create GitHub release

After the Hackage upload succeeds:

```bash
gh release create v<version> --title "v<version>" --notes "$(cat <<'EOF'
## Package

[shibuya-pgmq-adapter <version> on Hackage](https://hackage.haskell.org/package/shibuya-pgmq-adapter-<version>)

Paired with [shibuya-core <core-version>](https://hackage.haskell.org/package/shibuya-core-<core-version>) (if applicable).

## What's Changed

<changelog entries for this version from the root CHANGELOG.md>
EOF
)"
```

- Use the root `CHANGELOG.md` entries for the body.
- Mention the paired `shibuya-core` version when the release is driven
  by an upstream change.
- Report the GitHub release URL.

### 9. Restore local development override (optional)

If the user typically develops against an in-tree sibling
`shibuya-core`, restore the `cabal.project.local` override they
removed in step 3 (or remind them to do so). This file is gitignored
so it doesn't affect downstream consumers.

## Important

- Always ask the user to confirm the version bump and changelog before
  committing.
- Never skip `cabal check`, tests, or `nix flake check`.
- Never release while `cabal.project.local` shadows `shibuya-core`
  with a local checkout — Hackage cannot see local paths.
- If any step fails, stop and report — do not paper over failures.
- Run `nix fmt` before committing.
- The commit and tag should only be created AFTER user approval of all
  changes.
