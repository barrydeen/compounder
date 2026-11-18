# Branching and repository protection

`main` is the only long-lived branch. The app is still in development, so the
gate is deliberately light: `main` has **no branch protection rule**, direct
pushes are allowed, and CI reports status without blocking anything. This
document is the record of what those settings **are**, verified against the
live repository on **2026-11-18**, so they can be re-applied if the repository
is ever recreated or migrated.

Re-verify with:

```bash
gh api repos/barrydeen/compounder/branches/main/protection   # expect 404: none
gh api repos/barrydeen/compounder/rulesets
gh api repos/barrydeen/compounder --jq '.security_and_analysis'
gh api repos/barrydeen/compounder/private-vulnerability-reporting
gh api repos/barrydeen/compounder/actions/permissions
gh api repos/barrydeen/compounder/actions/permissions/workflow
gh api repos/barrydeen/compounder/actions/permissions/fork-pr-contributor-approval
```

If the API output and this table disagree, the API is right — update this file in
the same change that alters the setting.

## Branch model

| Branch | Purpose | Lifetime |
| --- | --- | --- |
| `main` | Working branch while in development. Open to direct pushes. | permanent |
| `feat/<slug>` | New capability | short-lived, deleted on merge |
| `fix/<slug>` | Bug fix | short-lived, deleted on merge |
| `chore/<slug>` | Tooling, CI, dependencies, docs | short-lived, deleted on merge |
| `release/<version>` | Release preparation only | deleted after the tag |

No other long-lived branches. No `develop`. Release candidates are tags, not
branches.

## Protection rules for `main`

There are none. The branch protection rule was removed on **2026-11-18** while
the app is in development, so:

| Rule | Enforced state |
| --- | --- |
| Require a pull request before merging | **off** — direct pushes allowed |
| Required approvals / Code Owners review | **off** |
| Require status checks to pass | **off** — CI is a signal, not a gate |
| Require branches to be up to date before merging | **off** |
| Require conversation resolution before merging | **off** |
| Require signed commits | **off** |
| Require linear history | **off** |
| Do not allow bypassing the above settings | n/a (nothing to bypass) |
| Allow force pushes | **off** |
| Allow deletions | **off** |

Re-enable the strict rules before the app ships: PRs with one approval, the
`Format, analyze and test` check as required, signed commits and linear history.
The CI job name to require is the `name:` of the job in
`.github/workflows/ci.yml` — if that job is renamed, update the rule in the
same change, otherwise it silently stops matching and merges go through
unchecked.

## Tags

- Release tags are `v<semver>` and must be **signed** (`git tag -s`). Verify with
  `git tag -v v0.4.0`.
- Tags are immutable. If a release is wrong, delete the tag and create a new one
  with a higher build number — never move an existing tag.
- A tag ruleset, `Protect release tags (v*)`, is **active** for `refs/tags/v*`:
  deletion and non-fast-forward updates are blocked, with no bypass actors.

Current tag state (2026-11-10): **no tags are pushed to `origin`** and no GitHub
Release exists yet. Locally, `v0.1.0`–`v0.2.2` are lightweight tags and
`v0.3.0`–`v0.3.2` are annotated but unsigned. The signing requirement is therefore
forward-looking: **`v0.4.0` and every later tag must be signed**, and the earlier
tags are left as-is rather than re-created.

## Code security settings

Under **Settings → Code security**:

| Setting | Enforced state (verified 2026-11-10) |
| --- | --- |
| Secret scanning | **enabled** |
| Push protection | **enabled** for all branches |
| Secret scanning non-provider patterns | disabled |
| Secret scanning validity checks | disabled |
| Dependabot alerts | **enabled** |
| Dependabot security updates | **enabled** |
| Private vulnerability reporting | **enabled** |
| Code scanning (CodeQL) | optional — the app is Dart, so GitHub secret scanning is the primary scanner |

Push protection is the only control that stops a secret *before* it enters
history, and it is what to rely on now that CI no longer runs gitleaks. If a
secret slips through, rotate it and scrub history — the scan is no longer there
to catch it after the fact.

## Actions settings

Under **Settings → Actions → General**:

| Setting | Enforced state (verified 2026-11-10) |
| --- | --- |
| Actions permissions | Allow selected actions only — GitHub-owned, `subosito/flutter-action@*`, `softprops/action-gh-release@*` |
| Workflow permissions | **Read repository contents** (default); workflows opt into `contents: write` explicitly |
| Allow GitHub Actions to create and approve pull requests | **off** |
| Require SHA pinning | **off** — see below |
| Require approval for first-time contributors | **on** |

Third-party actions are pinned to commit SHAs with a version comment in the
workflow files. Dependabot updates those pins and opens a PR; a human reviews the
diff before merging.

GitHub's `sha_pinning_required` is deliberately **off**: `subosito/flutter-action`
internally uses `actions/cache@v5` by tag, so enforcement makes every job fail at
"Set up job". The SHA-pinning convention in the workflow files is the control
instead.

## CI

`.github/workflows/ci.yml` is one job — format check, `flutter analyze` and the
test suite — on pushes to `main` and on pull requests. It exists to catch
compile/analysis/test regressions early, not to gate merges. The release build
job was removed from CI (it added ~9 minutes per run); packaging and signing
live in `release.yml`, which runs on tags. The gitleaks scan was dropped too:
GitHub secret scanning with push protection is the primary control, and it
stops a secret before it enters history.

## Merge strategy

- **Squash merge** is the convention (`allow_squash_merge: true`,
  `allow_merge_commit: false`, `allow_rebase_merge: false`), and
  `delete_branch_on_merge: true`, so a PR becomes one commit on `main`. With
  protection removed this is a convention rather than an enforcement: direct
  pushes to `main` are fine for small in-development changes.
- Do not merge on failing checks unless you know why they failed.

## Signed commits

Signed commits are **not required** while the app is in development. If they are
re-enabled later, configure one of:

```bash
# SSH signing (recommended; no GPG agent needed)
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
git config --global tag.gpgsign true
```

Then add the same public key to GitHub under **Settings → SSH and GPG keys → New
SSH key → Signing key**. Commits signed with a key GitHub does not know are shown
as unverified and would be rejected by that rule.

## CODEOWNERS

`.github/CODEOWNERS` records who owns workflows, signing configuration and
release documentation. With protection removed, that ownership is advisory: it
auto-requests a review rather than blocking a merge. Keep the file in sync with
who actually holds the keys.
