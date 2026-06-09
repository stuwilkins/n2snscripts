# n2snscripts

NSLS-II system scripts and shell libraries. Deployed to `/opt/nsls2/scripts`
on managed hosts via the Ansible base role.

## Layout

```text
bin/    Executable wrappers (sandboxed AI CLI tools, etc.)
lib/    Sourced shell libraries
etc/    Configuration assets (reserved)
docs/   Per-script and per-library documentation
```

## Contents

### `bin/`

| Script | Purpose | Docs |
| --- | --- | --- |
| `bwclaude` | Claude CLI in a bubblewrap sandbox | [docs/bw-wrappers.md](docs/bw-wrappers.md) |
| `bwcodex` | OpenAI Codex CLI in a bubblewrap sandbox | [docs/bw-wrappers.md](docs/bw-wrappers.md) |
| `bwcopilot` | GitHub Copilot CLI in a bubblewrap sandbox | [docs/bw-wrappers.md](docs/bw-wrappers.md) |
| `bwopencode` | OpenCode in a bubblewrap sandbox | [docs/bw-wrappers.md](docs/bw-wrappers.md) |
| `gh-protect-branch` | Apply NSLS-II standard branch protection to a GitHub repo (all branches); enables secret scanning and push protection | [docs/gh-protect-branch.md](docs/gh-protect-branch.md) |

All `bw*` wrappers share `lib/bwrap_sandbox_lib.sh` for sandbox construction.

### `lib/`

| Library | Purpose | Docs |
| --- | --- | --- |
| `bwrap_sandbox_lib.sh` | Shared sandbox-building primitives for `bw*` wrappers | [docs/bw-wrappers.md](docs/bw-wrappers.md) |
| `gpg-passwd.sh` | `decrypt_env_file` helper for GPG-encrypted env files | [docs/gpg-passwd.md](docs/gpg-passwd.md) |

These libraries are sourced, not executed. Each library's header comment
documents its public function surface.

## Deployment

`n2snscripts` is deployed by the NSLS-II Ansible base role:

- Cloned to `/opt/nsls2/scripts` on managed hosts.
- `/etc/profile.d/n2snscripts.sh` exports the following for login shells:

  | Variable | Value |
  | --- | --- |
  | `N2SNSCRIPTS_BIN` | `/opt/nsls2/scripts/bin` |
  | `N2SNSCRIPTS_LIB` | `/opt/nsls2/scripts/lib` |

  and prepends `$N2SNSCRIPTS_BIN` to `PATH`.

Manual install on an unmanaged host:

```bash
git clone git@github.com:NSLS2/n2snscripts.git ~/n2snscripts
export N2SNSCRIPTS_BIN="${HOME}/n2snscripts/bin"
export N2SNSCRIPTS_LIB="${HOME}/n2snscripts/lib"
export PATH="${N2SNSCRIPTS_BIN}:${PATH}"
```

Add those three exports to your `~/.bashrc` or `~/.zshrc` for persistence.

## Requirements

- `bash` >= 4.x (the `bw*` wrappers use `[[ ]]` and arrays)
- `bubblewrap` (`bwrap`) >= 0.4.0 for the `bw*` wrappers
  - 0.5.0+ enables `--clearenv`
  - 0.6.3+ enables bind-over-ro-bind binary masking
- `gpg(1)` for `gpg-passwd.sh`
- `gh(1)` authenticated with `admin:repo` scope for `gh-protect-branch`

See the per-script doc pages under [`docs/`](docs/) for full usage,
options, and caveats.
