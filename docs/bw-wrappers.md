# `bw*` sandboxed CLI wrappers

The `bw*` wrappers in `bin/` run AI CLI tools inside a [bubblewrap][bwrap]
(`bwrap`) sandbox to enforce NSLS-II sandboxing policy: managed config,
masked privileged binaries, ephemeral auth on shared accounts, and
filesystem isolation from the rest of the host. See the NSLS-II
coding-agents documentation for the policy these wrappers implement.

All four wrappers source the shared library `lib/bwrap_sandbox_lib.sh`
for sandbox construction. Each wrapper's `--help` is the authoritative
option list; the tables below summarise the common surface.

[bwrap]: https://github.com/containers/bubblewrap

## Requirements

- `bash` >= 4.x (the wrappers use `[[ ]]` and arrays)
- `bubblewrap` (`bwrap`) >= 0.4.0
  - 0.5.0+ enables `--clearenv`
  - 0.6.3+ enables bind-over-ro-bind binary masking

## Managed system paths

When present, the wrappers expose administrator-managed paths as optional,
read-only mounts. They do not expose the rest of the corresponding `/etc`
configuration directories.

- OpenCode: `/etc/opencode/skills`
- Codex: `/etc/codex/skills`
- Claude: `/etc/claude-code/.claude/skills` and
  `/etc/claude-code/managed-settings.json`
- Copilot: its deployment-defined shared-skill directory, when configured by
  the wrapper

## Shared agent skills

Shared agent skills are a deployment-managed skill collection. The deployment
defines the source repository or checkout and manages read-only aliases at the
paths above. When those aliases are present, `bwopencode`, `bwcodex`, and
`bwclaude` mount them read-only into their sandboxes. A wrapper configured for
Copilot likewise mounts its deployment-defined shared-skill directory
read-only.

Contribute or update skills through the deployment's documented contribution
workflow; do not edit its deployed checkout or managed aliases directly.

## Common options

Every `bw*` wrapper accepts these options:

| Option | Effect |
| --- | --- |
| `--help`, `-h` | Show wrapper help plus the underlying tool's help |
| `--dry-run` | Print the `bwrap` command without executing it |
| `--exec CMD` | Run `CMD` inside the sandbox instead of the tool |
| `--init-auth` | Persist auth credentials to the host (first-time setup) |
| `--new-session` | Force `bwrap --new-session` (stricter isolation; breaks SIGWINCH) |
| `--ro-path PATH` | Read-only mount an existing path; its canonical target is mounted at the same canonical destination. Use only narrow paths. |
| `--rw-path PATH` | Read-write mount an existing path; its canonical target is mounted at the same canonical destination. Use only narrow paths. |

Tool-specific options are listed in each wrapper's section below.

## `bwopencode`

Launches [opencode](https://opencode.ai) inside a bubblewrap sandbox.

```text
bwopencode [bwopencode-options] [opencode arguments...]
```

Persists database, logs, snapshots, storage, tool-output, and
project-dotfiles to the host data dir; `auth.json` is persisted only if
it already exists on the host (use `--init-auth` once to create it for
personal accounts).

No options beyond the common set.

## `bwclaude`

Launches the [Claude CLI](https://docs.claude.com/en/docs/claude-code/overview) inside a bubblewrap sandbox.

```text
bwclaude [bwclaude-options] [claude arguments...]
```

Routes through the NSLS-II Hermes (AIFAPIM) gateway in Azure AI Foundry
mode. The wrapper forces `CLAUDE_CODE_USE_FOUNDRY=1` and plumbs:

- **`ANTHROPIC_FOUNDRY_BASE_URL`** — if not set, constructed as
  `https://${AIFAPIM_HOST}/anthropic`; override by exporting
  `ANTHROPIC_FOUNDRY_BASE_URL` on the host. If neither
  `ANTHROPIC_FOUNDRY_BASE_URL` nor `AIFAPIM_HOST` is set, the wrapper
  refuses to start with a clear error message.
- **`ANTHROPIC_FOUNDRY_API_KEY`** — taken from the host's
  `ANTHROPIC_FOUNDRY_API_KEY` if set, otherwise from `AIFAPIM_API_KEY`
  (the existing NSLS-II convention). If neither is set, the wrapper
  refuses to start with a clear error message rather than letting Claude
  Code fall back to the Azure SDK credential chain.

The legacy `ANTHROPIC_API_KEY` / `ANTHROPIC_BASE_URL` env vars are *not*
honored in foundry mode and the wrapper no longer sets them.

Additional options:

| Option | Effect |
| --- | --- |
| `--debug` | Enable verbose debug logging: sets `ANTHROPIC_LOG=debug`, `NODE_DEBUG=http,https,tls`, and passes `--debug --verbose` to `claude` |

On shared accounts, auth is ephemeral. On a personal machine, run
`bwclaude --init-auth` once to persist credentials.

## `bwcopilot`

Launches the [GitHub Copilot CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli/about-github-copilot-in-the-cli)
inside a bubblewrap sandbox.

```text
bwcopilot [bwcopilot-options] [copilot arguments...]
```

No options beyond the common set.

On shared accounts, auth tokens are ephemeral. On a personal machine,
run `bwcopilot --init-auth` once to persist tokens.

### Shared skills

When configured by the wrapper, `bwcopilot` automatically exposes the
deployment-managed shared-skill directory read-only. Configure Copilot CLI's
documented `skillDirectories` in `$COPILOT_HOME/settings.json` (default:
`~/.copilot/settings.json`) to name that same directory.

The automatic mount supplies the skills directory, but `bwcopilot` does not
automatically mount `settings.json`; making settings visible remains the
user's responsibility. To make a host settings file available read-only, use
`--ro-path`. This is appropriate when the default settings file is a regular
(non-symlink) file:

```console
bwcopilot --ro-path "$HOME/.copilot/settings.json"
```

The read-only settings mount prevents Copilot from writing `/settings`; edit
the host settings file between sessions to change its configuration.

`--ro-path` canonicalizes symlinks and binds the canonical source at that
same canonical destination. Therefore, a symlinked dotfiles settings alias is
not available as `$COPILOT_HOME/settings.json` in the sandbox. The example
requires a regular (non-symlink) settings file at that location.

## `bwcodex`

Launches the [OpenAI Codex CLI](https://github.com/openai/codex) inside
a bubblewrap sandbox.

```text
bwcodex [bwcodex-options] [codex arguments...]
```

Two approved auth paths (configured in `~/.codex/config.toml`):

- **Hermes (AIFAPIM) routing** — provider block points at
  `https://${AIFAPIM_HOST}/openai/v1` with `x-api-key` header; the
  wrapper plumbs `AIFAPIM_HOST` and `AIFAPIM_API_KEY` through.
- **BNL ITD ChatGPT subscription** — `codex login` OAuth flow persists
  tokens to `~/.codex/auth.json`. Run once with `--init-auth` to make
  that file persist across sandbox invocations.

Additional options:

| Option | Effect |
| --- | --- |
| `--debug` | Enable verbose Codex logging (sets `RUST_LOG=debug`) |
| `--persist-config` | Bind-mount `~/.codex/config.toml` read-write into the sandbox so changes (e.g. project-trust grants) persist across sessions. Without this flag, `config.toml` is staged read-write into a per-session copy that is discarded on exit. Concurrent `--persist-config` sessions may race on writes |

Note: Codex CLI also enforces its own inner Landlock-based sandbox for
agent tool calls. The outer `bwrap` here is complementary — it scopes
the entire Codex process tree, not just agent-issued commands.

## `lib/bwrap_sandbox_lib.sh`

Shared sandbox-building primitives sourced by all `bw*` wrappers. Not
intended to be executed directly. The library header documents the
public function surface (sandbox construction, dynamic mount discovery,
binary masking, environment scrubbing).
