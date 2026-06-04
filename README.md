# n2snscripts

NSLS-II system scripts and shell libraries. Deployed to `/opt/nsls2/scripts`
on managed hosts via the Ansible base role.

## Layout

```text
bin/    Executable wrappers (sandboxed AI CLI tools, etc.)
lib/    Sourced shell libraries
etc/    Configuration assets (reserved)
```

## Contents

### `bin/`

The `bw*` wrappers enforce NSLS-II sandboxing policy (managed config,
masked privileged binaries, ephemeral auth on shared accounts). See the
NSLS-II coding-agents documentation for the policy these wrappers
implement.

| Script | Purpose |
| --- | --- |
| `bwclaude` | Run the Claude CLI inside a bubblewrap sandbox |
| `bwcopilot` | Run the GitHub Copilot CLI inside a bubblewrap sandbox |
| `bwopencode` | Run OpenCode inside a bubblewrap sandbox |

All three wrappers share `lib/bwrap_sandbox_lib.sh` for sandbox construction.
See each script's `--help` for tool-specific options.

### `lib/`

| Library | Purpose |
| --- | --- |
| `bwrap_sandbox_lib.sh` | Shared sandbox-building primitives used by the `bw*` wrappers |
| `gpg-passwd.sh` | `decrypt_env_file` helper for sourcing GPG-encrypted env files |

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

## Usage

### `bw*` sandboxed CLI wrappers

```text
bwopencode [bwopencode-options] [opencode arguments...]
bwclaude   [bwclaude-options]   [claude arguments...]
bwcopilot  [bwcopilot-options]  [copilot arguments...]
```

Common wrapper options:

| Option | Effect |
| --- | --- |
| `--help`, `-h` | Show wrapper help plus the underlying tool's help |
| `--dry-run` | Print the `bwrap` command without executing it |
| `--exec CMD` | Run `CMD` inside the sandbox instead of the tool |
| `--init-auth` | Persist auth credentials to the host (first-time setup) |
| `--new-session` | Force `bwrap --new-session` (stricter isolation; breaks SIGWINCH) |

`bwclaude` also supports `--debug`. See each script's `--help` for the
authoritative option list.

### `gpg-passwd.sh`

Source the library and call `decrypt_env_file`:

```bash
source "${N2SNSCRIPTS_LIB}/gpg-passwd.sh"
decrypt_env_file "$HOME/.private_env.gpg" AIFAPIM_HOST AIFAPIM_API_KEY
```

Behaviour:

- Decrypts the file with `gpg --quiet --batch --yes --decrypt` and `eval`s
  the result into the current shell.
- Returns `0` on success, `0` (with warning) if the file is missing,
  `2` if a required variable is still empty after decrypt, `3` if `gpg`
  fails.

See the library header for the full contract.
