# `gh-protect-branch`

Admin helper (not a sandbox wrapper) that applies NSLS-II standard
branch protection rules to a GitHub repository via the GitHub API
through `gh(1)`. Enforces the full NSLS-II branch protection policy
across two layers.

Because the script is named `gh-*`, it is also auto-discovered by `gh`
as an extension, so
`gh protect-branch [--approvers <slug>] [--no-sign-commits] <owner/repo> [branch]`
works equivalently.

## Protections applied

### Repository ruleset (all branches)

A ruleset named `nsls2-branch-protection` targeting `~ALL` branches
enforces:

- PRs required (no direct push)
- >= 1 approving review, with stale-review dismissal on new commits
- The last pusher's commit must be approved by a different reviewer
- Code owner review (CODEOWNERS entries, when present)
- All PR conversations resolved before merge
- Branch deletion blocked
- Force pushes (non-fast-forward) blocked
- Required signed commits (default on; suppress with `--no-sign-commits`)

The script is idempotent: re-running it updates the existing ruleset
rather than creating a duplicate.

### Classic branch protection (named branch only, default `main`)

- All rules enforced on admins
- Optionally restricts stale-review dismissal to a named GitHub team
  (`--approvers <team-slug>`) — only members of that team can dismiss a
  stale review, so a team member must re-approve after new commits are
  pushed; the team slug must belong to the same GitHub organization as
  the repo
- Belt-and-suspenders signed commits on the named branch (in addition to
  the ruleset enforcement above)

### Repository settings

- Secret scanning and push protection enabled

## Usage

```text
gh-protect-branch [--approvers <team-slug>] [--no-sign-commits] <owner/repo> [branch]
```

| Option / Argument | Description |
| --- | --- |
| `--approvers <team-slug>` | GitHub team slug whose members are the only ones allowed to dismiss stale reviews (optional; org-owned repos only) |
| `--no-sign-commits` | Skip enforcing signed commits on the named branch (signing is required by default) |
| `<owner/repo>` | Repository in `owner/repo` format (required) |
| `[branch]` | Primary branch to protect (default: `main`); ruleset protection is always applied to all branches regardless |

## Examples

```bash
# Standard protection (no team restriction)
gh-protect-branch NSLS2/n2snscripts

# With approver team restriction
gh-protect-branch --approvers n2sn-admins NSLS2/n2snscripts
gh-protect-branch --approvers n2sn-admins NSLS2/n2sndocs main

# Skip the signed-commit requirement (e.g. for repos where signing is not yet rolled out)
gh-protect-branch --no-sign-commits NSLS2/n2snscripts
```

## Caveats

Requires `gh(1)` authenticated with `admin:repo` scope on the target
repository. Secret scanning requires the repository to belong to an
organization on GitHub Team or Enterprise Cloud (or to be a public
repository). The `require_code_owner_review` rule is a no-op if no
`CODEOWNERS` file exists or no entry matches the changed files. Re-runs
are idempotent: the `nsls2-branch-protection` ruleset is updated in place
rather than duplicated. Signed-commit enforcement is applied to all
branches via the ruleset and additionally as a belt-and-suspenders rule
on the named branch via the classic `required_signatures` endpoint.
