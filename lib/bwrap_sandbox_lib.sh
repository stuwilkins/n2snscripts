#!/usr/bin/env bash
# bwrap_sandbox_lib.sh — Shared library for bubblewrap sandbox wrappers.
#
# Provides the common infrastructure for sandboxing CLI tools with bwrap:
#   - bwrap version detection and capability flags
#   - Dynamic mount helpers (deduplication, symlink resolution, npm detection)
#   - Git config include-path parsing
#   - Sandbox PATH construction
#   - Shell detection
#   - All shared bwrap mounts: base system, binary masking, /etc, home tmpfs,
#     working directory, git config, pixi, ccache, npm, user bin, NSLS-II,
#     dynamic tool mounts
#   - Environment variable framework (clean env + passthrough)
#   - Launch logic (dry-run printing and bwrap exec)
#
# Tool-specific wrapper scripts source this file and provide:
#   - Argument parsing (parse_wrapper_args)
#   - Binary resolution (resolve_tool_binary) setting _TOOL_BIN and _TOOL_CMD
#   - Help text (show_help)
#   - Tool-specific path resolution, host directory creation, mounts, and env vars
#   - main() orchestrating the build sequence
#
# Usage (in tool wrapper scripts):
#   SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
#   source "${SCRIPT_DIR}/bwrap_sandbox_lib.sh"
#
# Requires: bwrap >= 0.4.0 (RHEL 8)
#   - 0.4.0: base functionality
#   - 0.5.0+: --clearenv (fallback: manual --unsetenv for each host var)
#   - 0.6.3+: bind over ro-bind (fallback: skip binary masking)

# Guard against double-sourcing.
[[ -n "${_BWRAP_SANDBOX_LIB_SOURCED:-}" ]] && return 0
_BWRAP_SANDBOX_LIB_SOURCED=1

# ═══════════════════════════════════════════════════════════════════
# Global state
# ═══════════════════════════════════════════════════════════════════

# Wrapper control flags (set by tool-specific parse_wrapper_args)
# shellcheck disable=SC2034  # used by tool wrappers that source this library
DRY_RUN=0
# shellcheck disable=SC2034  # used by tool wrappers that source this library
TEST_CMD=""
# shellcheck disable=SC2034  # used by tool wrappers that source this library
SHOW_HELP=0
# shellcheck disable=SC2034  # used by print_dry_run and launch_sandbox
TOOL_ARGS=()
# shellcheck disable=SC2034  # set by tool wrappers when --new-session is requested
FORCE_NEW_SESSION=0

# Tool binary (set by tool-specific resolve_tool_binary)
_TOOL_BIN=""
_TOOL_CMD=()

# bwrap construction
BWRAP_ARGS=()
declare -A _MOUNTED_PREFIXES=()
_EXTRA_PATH_DIRS=()

# Sandbox environment
SANDBOX_PATH=""
SANDBOX_SHELL=""

# bwrap capability flags (set by detect_bwrap_capabilities)
HAS_CLEARENV=0
HAS_BIND_OVER_RO=0

# Kernel capability flags (set by detect_kernel_capabilities)
KERNEL_HAS_TIOCSTI_CAP_GUARD=0

# Git include tracking (used by parse_git_includes)
declare -A _GIT_INCLUDE_SEEN=()
GIT_INCLUDE_PATHS=()

# Working directory state (set by build_workdir_mount)
_BIND_DIR=""
_GIT_ROOT=""

# ═══════════════════════════════════════════════════════════════════
# Shared helper functions
# ═══════════════════════════════════════════════════════════════════

# Feature detection by parsing the version string — much cheaper than
# grepping --help.
#
# Version history:
#   0.5.0 - added --clearenv
#   0.6.3 - bind over ro-bind works (can mask binaries inside /usr)
detect_bwrap_capabilities() {
    local _bwrap_ver
    _bwrap_ver="$(bwrap --version)"
    _bwrap_ver="${_bwrap_ver##* }"            # "bubblewrap 0.11.0" -> "0.11.0"
    local _bw_major _bw_minor _bw_patch
    IFS='.' read -r _bw_major _bw_minor _bw_patch <<< "${_bwrap_ver}"
    _bw_patch="${_bw_patch:-0}"  # default to 0 if no patch version

    # --clearenv: Start with an empty environment (added in 0.5.0)
    # Fallback: manually unset all host env vars with --unsetenv
    HAS_CLEARENV=0
    if [[ "${_bw_major}" -gt 0 ]] || { [[ "${_bw_major}" -eq 0 ]] && [[ "${_bw_minor}" -ge 5 ]]; }; then
        HAS_CLEARENV=1
    fi

    # Bind over ro-bind: ability to bind-mount on top of a read-only bind
    # mount (e.g., masking /usr/bin/ssh after --ro-bind /usr /usr).
    # This works in 0.6.3+; earlier versions fail with "Permission denied".
    # Fallback: skip binary masking (security reduction — tools remain accessible)
    HAS_BIND_OVER_RO=0
    if [[ "${_bw_major}" -gt 0 ]] ||
        { [[ "${_bw_major}" -eq 0 ]] && [[ "${_bw_minor}" -gt 6 ]]; } ||
        { [[ "${_bw_major}" -eq 0 ]] && [[ "${_bw_minor}" -eq 6 ]] && [[ "${_bw_patch}" -ge 3 ]]; }; then
        HAS_BIND_OVER_RO=1
    fi
}

# Detect kernel-level security features that affect bwrap argument choice.
#
# TIOCSTI capability guard (Linux 5.14+):
#   On kernels >= 5.14, the TIOCSTI ioctl requires CAP_SYS_ADMIN on any
#   tty that is not the process's own controlling terminal.  bwrap drops
#   all capabilities unconditionally, so TIOCSTI is already blocked at
#   the kernel level — making --new-session redundant for that threat.
#
#   On older kernels (e.g. RHEL 8 / 4.18), --new-session is the only
#   guard against TIOCSTI injection and must be kept.
#
#   We omit --new-session when this guard is present so that SIGWINCH
#   (terminal resize) is delivered correctly from tmux and other
#   multiplexers to the sandboxed process.
detect_kernel_capabilities() {
    local _kver _kmajor _kminor
    _kver="$(uname -r)"
    _kver="${_kver%%-*}"            # strip suffix e.g. "5.14.0-427.el9" -> "5.14.0"
    IFS='.' read -r _kmajor _kminor _ <<< "${_kver}"
    _kmajor="${_kmajor:-0}"
    _kminor="${_kminor:-0}"

    KERNEL_HAS_TIOCSTI_CAP_GUARD=0
    if [[ "${_kmajor}" -gt 5 ]] ||
        { [[ "${_kmajor}" -eq 5 ]] && [[ "${_kminor}" -ge 14 ]]; }; then
        KERNEL_HAS_TIOCSTI_CAP_GUARD=1
    fi
}

detect_shell() {
    SANDBOX_SHELL="$(command -v bash 2> /dev/null || echo /bin/sh)"
}

# ── Dynamic mount helpers ────────────────────────────────────────
# _MOUNTED_PREFIXES: tracks directory trees already covered by a bwrap
# bind so we never emit duplicate (or redundant sub-path) mounts.
# Keys are canonical paths; value is always 1.
# Pre-populated with unconditional mounts in build_dynamic_tool_mounts.

# _mount_ro_dir_if_needed DIR
#   Bind-mount DIR read-only into the sandbox, unless it (or a parent
#   tree) is already registered in _MOUNTED_PREFIXES.  If the bind is
#   actually emitted, DIR is added to _MOUNTED_PREFIXES so future calls
#   with the same path or a sub-path are no-ops.
#   Handles intermediate --dir entries for paths under $HOME.
_mount_ro_dir_if_needed() {
    local dir="$1"
    [[ -d "${dir}" ]] || return 0

    # Check whether dir is already covered by a registered prefix.
    local check="${dir}"
    while [[ "${check}" != "/" ]]; do
        if [[ -n "${_MOUNTED_PREFIXES["${check}"]:-}" ]]; then
            return 0  # already covered
        fi
        check="${check%/*}"
        [[ -z "${check}" ]] && check="/"
    done

    # Create intermediate --dir entries for paths under $HOME (the
    # tmpfs $HOME has no subdirectories yet).
    if [[ "${dir}" == "${_HOME}"/* ]]; then
        local _rel="${dir#"${_HOME}"/}"
        local _accum="${_HOME}"
        local _parts _i
        IFS='/' read -ra _parts <<< "${_rel}"
        for ((_i = 0; _i < ${#_parts[@]} - 1; _i++)); do
            _accum="${_accum}/${_parts[$_i]}"
            BWRAP_ARGS+=(--dir "${_accum}")
        done
    fi

    BWRAP_ARGS+=(--ro-bind "${dir}" "${dir}")
    _MOUNTED_PREFIXES["${dir}"]=1
}

# resolve_and_mount_tool BINARY_PATH
#   Given an absolute path to a binary (as returned by command -v),
#   mount its on-PATH directory AND — if it is a symlink — the real
#   binary's directory.  Both are passed through _mount_ro_dir_if_needed
#   so deduplication is automatic.
#   The on-PATH bin directory is added to _EXTRA_PATH_DIRS.
#   Special case: if the real binary resolves into the npm global prefix,
#   the entire prefix tree is mounted via _mount_npm_global_prefix (which
#   subsumes the narrow bin/ dir) rather than a narrow bind.
resolve_and_mount_tool() {
    local bin_path="$1"
    [[ -n "${bin_path}" ]] || return 0

    local cmd_dir real_path npm_prefix
    cmd_dir="$(dirname "${bin_path}")"

    # Record for SANDBOX_PATH even if the mount is skipped (dir already
    # covered): the path still needs to be on PATH inside the sandbox.
    _EXTRA_PATH_DIRS+=("${cmd_dir}")

    if [[ -L "${bin_path}" ]]; then
        real_path="$(readlink -f "${bin_path}")"
        npm_prefix="$(npm prefix -g 2> /dev/null || true)"
        if [[ -n "${npm_prefix}" ]] && [[ "${real_path}" == "${npm_prefix}"/* ]]; then
            # npm-installed: mount the whole prefix so lib/node_modules is reachable.
            _mount_npm_global_prefix "${npm_prefix}"
            return 0
        fi
        _mount_ro_dir_if_needed "${cmd_dir}"
        _mount_ro_dir_if_needed "$(dirname "${real_path}")"
    else
        _mount_ro_dir_if_needed "${cmd_dir}"
    fi
}

# _mount_npm_global_prefix [PREFIX]
#   Mount the entire npm global prefix tree read-only and add its bin/
#   subdirectory to _EXTRA_PATH_DIRS.  PREFIX defaults to `npm prefix -g`.
_mount_npm_global_prefix() {
    local npm_prefix="${1:-}"
    if [[ -z "${npm_prefix}" ]]; then
        npm_prefix="$(npm prefix -g 2> /dev/null || true)"
    fi
    [[ -n "${npm_prefix}" ]] && [[ -d "${npm_prefix}" ]] || return 0

    _mount_ro_dir_if_needed "${npm_prefix}"
    _EXTRA_PATH_DIRS+=("${npm_prefix}/bin")
}

# ── Git include parser ───────────────────────────────────────────

parse_git_includes() {
    local config_file="$1"
    [[ -f "${config_file}" ]] || return 0

    # Git resolves relative include paths relative to the location of
    # the config file (the symlink path, NOT the resolved target).
    local config_dir="${config_file%/*}"

    # Extract path values from [include] and [includeIf "..."] sections.
    # Matches lines like:  path = /some/path  or  path = ~/relative
    # Pure bash — no grep/sed/xargs subprocesses.
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ^[[:space:]]*path[[:space:]]*=[[:space:]]*(.*) ]] || continue
        local path_val="${BASH_REMATCH[1]}"

        # Trim trailing whitespace
        path_val="${path_val%"${path_val##*[![:space:]]}"}"
        [[ -z "${path_val}" ]] && continue

        # Resolve ~/ prefix
        path_val="${path_val/#\~/${_HOME}}"

        # Resolve relative paths (relative to the config file's directory)
        if [[ "${path_val}" != /* ]]; then
            path_val="${config_dir}/${path_val}"
        fi

        # Resolve symlinks and canonicalize
        local resolved
        if [[ -L "${path_val}" ]]; then
            resolved="$(readlink -f "${path_val}" 2> /dev/null || echo "${path_val}")"
        else
            resolved="${path_val}"
        fi

        # Deduplicate
        if [[ -e "${resolved}" ]] && [[ -z "${_GIT_INCLUDE_SEEN["${resolved}"]:-}" ]]; then
            _GIT_INCLUDE_SEEN["${resolved}"]=1
            GIT_INCLUDE_PATHS+=("${resolved}")
        fi
    done < "${config_file}"
}

# Parse the standard git config files for include directives.
parse_all_git_includes() {
    if [[ -f "${_HOME}/.gitconfig" ]]; then
        parse_git_includes "${_HOME}/.gitconfig"
    fi
    if [[ -f "${XDG_CONFIG_HOME}/git/config" ]]; then
        parse_git_includes "${XDG_CONFIG_HOME}/git/config"
    fi
}

# ── Env var passthrough helper ───────────────────────────────────

pass_through_if_set() {
    local var_name="$1"
    local var_val="${!var_name:-}"
    if [[ -n "${var_val}" ]]; then
        BWRAP_ARGS+=(--setenv "${var_name}" "${var_val}")
    fi
}

# ── Path resolution ──────────────────────────────────────────────

resolve_common_paths() {
    _HOME="${HOME}"
    _PWD="${PWD}"

    # XDG defaults
    XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${_HOME}/.config}"
    XDG_DATA_HOME="${XDG_DATA_HOME:-${_HOME}/.local/share}"
    XDG_CACHE_HOME="${XDG_CACHE_HOME:-${_HOME}/.cache}"

    # Pixi paths
    PIXI_HOME_DIR="${PIXI_HOME:-${_HOME}/.pixi}"

    # ccache paths
    # ccache cache: $CCACHE_DIR, else ~/.ccache if it exists (legacy), else $XDG_CACHE_HOME/ccache
    if [[ -n "${CCACHE_DIR:-}" ]]; then
        CCACHE_CACHE_DIR="${CCACHE_DIR}"
    elif [[ -d "${_HOME}/.ccache" ]]; then
        CCACHE_CACHE_DIR="${_HOME}/.ccache"
    else
        CCACHE_CACHE_DIR="${XDG_CACHE_HOME}/ccache"
    fi
    # ccache config: if legacy ~/.ccache dir exists, config is inside it;
    # otherwise $XDG_CONFIG_HOME/ccache
    if [[ -d "${_HOME}/.ccache" ]]; then
        CCACHE_CONFIG_DIR="${_HOME}/.ccache"
    else
        CCACHE_CONFIG_DIR="${XDG_CONFIG_HOME}/ccache"
    fi

    # npm paths
    NPM_CACHE_DIR="${NPM_CONFIG_CACHE:-${_HOME}/.npm}"
}

# ── Sandbox PATH construction ────────────────────────────────────

init_sandbox_path() {
    SANDBOX_PATH="/usr/lib64/ccache:/usr/local/sbin:/usr/local/bin:/usr/bin"
    SANDBOX_PATH="${SANDBOX_PATH}:${PIXI_HOME_DIR}/bin"
    SANDBOX_PATH="${SANDBOX_PATH}:${_HOME}/bin"
    if [[ -d /nsls2/software/bin ]]; then
        SANDBOX_PATH="${SANDBOX_PATH}:/nsls2/software/bin"
    fi
    # Additional bin directories discovered during dynamic tool mounts are
    # appended to SANDBOX_PATH by finalize_sandbox_path.
}

# Append dynamically-discovered bin directories to SANDBOX_PATH.
finalize_sandbox_path() {
    local _extra_dir
    for _extra_dir in "${_EXTRA_PATH_DIRS[@]+"${_EXTRA_PATH_DIRS[@]}"}"; do
        SANDBOX_PATH="${SANDBOX_PATH}:${_extra_dir}"
    done
}

# ═══════════════════════════════════════════════════════════════════
# Shared sandbox construction functions
# ═══════════════════════════════════════════════════════════════════
# Each build_* function appends to the global BWRAP_ARGS array.
# They must be called in the correct order to produce valid bwrap
# arguments — see the tool wrapper's main() for the canonical sequence.

# ── Namespace isolation + base system (read-only) ────────────────
build_base_sandbox() {
    # --unshare-pid: Isolate the PID namespace so the sandbox cannot see
    #   or inspect host processes via /proc (prevents reading environ,
    #   cmdlines, and discovering services like ssh-agent).
    # --new-session: Calls setsid(2) — detaches the controlling terminal
    #   and creates a new session.  Originally added to block TIOCSTI
    #   ioctl keystroke injection into the parent terminal.  On kernels
    #   >= 5.14 TIOCSTI requires CAP_SYS_ADMIN (which bwrap drops), so
    #   the kernel guard subsumes the TIOCSTI side of this protection
    #   AND we want to omit --new-session so SIGWINCH (terminal resize)
    #   propagates correctly from tmux/screen to the sandboxed TUI.
    #
    #   Residual exposure when --new-session is omitted:
    #     - The sandbox keeps the controlling tty.  A direct
    #       open("/dev/tty") is mitigated in build_proc_dev_tmp by
    #       binding /dev/null over /dev/tty, but a malicious child can
    #       STILL reach the controlling tty via the inherited pty fds
    #       (fd 0/1/2), reachable as /proc/self/fd/0.  Closing the
    #       /proc/self/fd reopen path would require --unshare-user or
    #       hidepid=2 on /proc, neither of which we currently use.
    #     - Via that reopened fd, an attacker CAN:
    #         * write arbitrary bytes (display spoofing, escape
    #           sequences, fake TUI content)
    #         * call tcsetattr() to manipulate termios (disable echo)
    #     - Via that reopened fd, an attacker CANNOT
    #         * inject keystrokes via TIOCSTI — blocked by the 5.14
    #           kernel cap guard (returns EIO)
    #         * steal the foreground process group via tcsetpgrp —
    #           fails with ENOTTY (we have no controlling tty of our
    #           own, only an open fd to someone else's)
    #         * reliably read keystrokes — the TUI parent consumes
    #           them first, and the kernel gates this for non-CTTY fds
    #     - Escape-sequence-based attacks via stdout (OSC 52 clipboard
    #       hijack, terminal-response injection on legacy emulators)
    #       are NOT mitigated by --new-session either — stdout is
    #       already a direct path to the user's terminal.  These are
    #       the TUI's responsibility (filter tool output) and out of
    #       scope here.
    #
    #   Users can force --new-session via the wrapper's --new-session
    #   flag (which sets FORCE_NEW_SESSION=1), e.g. for non-interactive
    #   runs where SIGWINCH propagation is unimportant.  Note that
    #   --new-session does NOT close the /proc/self/fd reopen path — it
    #   only detaches the controlling terminal, not already-open fds
    #   held by other processes in the sandbox.
    # --die-with-parent: Kill the sandbox if the parent process exits, to
    #   prevent orphaned sandbox processes.
    # Network is shared so the tool can reach LLM APIs and GitHub OAuth.
    BWRAP_ARGS+=(
        --unshare-pid
        --die-with-parent
    )
    if [[ "${FORCE_NEW_SESSION}" -eq 1 ]] || [[ "${KERNEL_HAS_TIOCSTI_CAP_GUARD}" -eq 0 ]]; then
        BWRAP_ARGS+=(--new-session)
    fi

    # Base system (read-only)
    BWRAP_ARGS+=(
        --ro-bind /usr /usr
    )
    # /bin, /sbin, /lib, and /lib64 may be real directories (Debian-family)
    # or symlinks into /usr (Fedora/Arch).  Bind the real dir, or recreate
    # the symlink so tools expecting e.g. /bin/bash still work.
    local _dir
    for _dir in /bin /sbin /lib /lib64; do
        if [[ -L "${_dir}" ]]; then
            BWRAP_ARGS+=(--symlink "$(readlink "${_dir}")" "${_dir}")
        elif [[ -d "${_dir}" ]]; then
            BWRAP_ARGS+=(--ro-bind "${_dir}" "${_dir}")
        fi
    done
}

# ── Mask dangerous binaries ───────────────────────────────────────
# Bind /dev/null over security-sensitive binaries so attempts to
# execute them fail rather than silently working.
#
# This requires bwrap >= 0.6.3 which supports binding over paths inside
# an existing read-only bind mount.  On older versions, we skip masking
# entirely (the binaries remain accessible inside the sandbox).
#
# Categories:
#   SSH           – lateral movement via remote shell / file transfer
#   Network       – arbitrary TCP/UDP connections, reverse shells
#   Kerberos      – ticket-based authentication to network services
#   Keyring       – kernel keyring manipulation
#   Priv-escalation – sudo/su/pkexec
#   Namespace     – sandbox escape via nsenter/unshare/chroot
build_binary_masks() {
    [[ "${HAS_BIND_OVER_RO}" -eq 1 ]] || return 0

    local _MASKED_BINS=(
        # SSH
        ssh scp sftp ssh-agent ssh-add ssh-keygen ssh-keyscan
        # Network
        telnet nc ncat netcat socat rsync rsh rlogin rexec
        # Kerberos
        kinit klist kdestroy kswitch
        # Keyring
        keyctl
        # Privilege escalation
        sudo su pkexec
        # Namespace / sandbox escape
        nsenter unshare chroot
    )
    # On merged-/usr systems /bin, /sbin, /usr/bin, /usr/sbin all point to the
    # same directory.  Multiple prefixes therefore resolve to the same realpath,
    # which would emit duplicate --ro-bind /dev/null <path> flags.  Track which
    # real paths have already been masked and skip repeats.
    declare -A _MASKED_REAL_SEEN=()
    local _bin _prefix _candidate _real
    for _bin in "${_MASKED_BINS[@]}"; do
        # Search well-known prefixes covering RHEL, Debian, and Arch layouts.
        for _prefix in /usr/bin /usr/sbin /usr/lib/openssh /usr/libexec/openssh \
                       /bin /sbin; do
            _candidate="${_prefix}/${_bin}"
            # -e follows symlinks: true only if the full chain resolves to a
            # real file.  Broken alternatives entries (dangling symlinks) are
            # skipped, which is correct — there is no binary to mask.
            [[ -e "${_candidate}" ]] || continue

            # On RHEL/Debian the binary is often a symlink:
            #   /usr/bin/nc -> /etc/alternatives/nc -> /usr/bin/ncat
            # bwrap processes --ro-bind arguments in order.  At the point this
            # bind is applied, /etc/alternatives has not yet been mounted in the
            # sandbox, so bwrap cannot resolve the intermediate symlink and
            # reports "Can't create file at /usr/bin/nc".
            #
            # Fix: resolve to the canonical (symlink-free) path on the host and
            # use *that* as the bwrap destination.  The real file is always
            # directly accessible under /usr once --ro-bind /usr /usr is applied.
            _real="$(realpath "${_candidate}")"
            [[ -n "${_MASKED_REAL_SEEN[${_real}]:-}" ]] && continue
            _MASKED_REAL_SEEN["${_real}"]=1
            BWRAP_ARGS+=(--ro-bind /dev/null "${_real}")
        done
    done
}

build_proc_dev_tmp() {
    BWRAP_ARGS+=(
        --proc /proc
        --dev /dev
        --tmpfs /tmp
    )

    # Mask /dev/tty unless --new-session is active.
    #
    # With --new-session bwrap detaches the controlling terminal, so
    # open("/dev/tty") returns ENXIO inside the sandbox — there is no
    # tty to find.  Without --new-session (the default on kernels with
    # the TIOCSTI cap-guard, where we drop --new-session to let SIGWINCH
    # through), the sandboxed process inherits the controlling terminal
    # and can open /dev/tty as a direct, un-redirectable, un-loggable
    # channel to the user's terminal.  Binding /dev/null over /dev/tty
    # blocks the naïve open("/dev/tty") path.
    #
    # Scope of this mitigation: closes the obvious API path used by
    # legitimate tools (sudo, ssh-askpass, gpg-agent) and by naïve
    # malicious dependencies.  Does NOT close the procfs-fd-reopen
    # bypass — see the long comment in build_base_sandbox for the
    # threat-model details.  Closing that bypass needs a separate user
    # namespace or hidepid=2 on /proc.
    #
    # Programs typically use isatty(0/1/2) — which still works on the
    # inherited stdio fds — to detect interactivity, so masking
    # /dev/tty rarely breaks tools that aren't actively trying to
    # bypass stdio.
    if [[ "${FORCE_NEW_SESSION}" -ne 1 ]] && [[ "${KERNEL_HAS_TIOCSTI_CAP_GUARD}" -eq 1 ]]; then
        BWRAP_ARGS+=(--bind /dev/null /dev/tty)
    fi
}

# ── Selective /etc (read-only) ───────────────────────────────────
# Only expose what is needed for DNS, TLS, user identity, and NSS.
build_etc_mounts() {
    BWRAP_ARGS+=(
        --ro-bind-try /etc/resolv.conf /etc/resolv.conf
        --ro-bind-try /etc/hosts /etc/hosts
        --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf
        --ro-bind /etc/passwd /etc/passwd
        --ro-bind /etc/group /etc/group
        --ro-bind-try /etc/ssl /etc/ssl
        --ro-bind-try /etc/pki /etc/pki
        --ro-bind-try /etc/crypto-policies /etc/crypto-policies
        --ro-bind-try /etc/ca-certificates /etc/ca-certificates
        --ro-bind-try /etc/alternatives /etc/alternatives
        --ro-bind-try /etc/ld.so.cache /etc/ld.so.cache
        --ro-bind-try /etc/ld.so.conf /etc/ld.so.conf
        --ro-bind-try /etc/ld.so.conf.d /etc/ld.so.conf.d
        --ro-bind-try /etc/localtime /etc/localtime
        --ro-bind-try /etc/gitconfig /etc/gitconfig
    )
}

# ── Home directory (empty tmpfs, then selective mounts) ──────────
build_home_tmpfs() {
    BWRAP_ARGS+=(
        --tmpfs "${_HOME}"
    )

    # Create intermediate directories that are needed as mount points
    # inside the tmpfs $HOME.
    BWRAP_ARGS+=(
        --dir "${_HOME}/.config"
        --dir "${_HOME}/.local"
        --dir "${_HOME}/.local/share"
        --dir "${_HOME}/.cache"
        --dir "${_HOME}/bin"
    )
}

# ── Working directory (read-write) ────────────────────────────────
# If we are inside a git repo, bind the repo root so the tool can
# find .git and identify the project (sessions are keyed to the repo).
# Otherwise fall back to binding just $PWD.
# Sets globals: _BIND_DIR, _GIT_ROOT
build_workdir_mount() {
    _BIND_DIR="${_PWD}"
    _GIT_ROOT="$(git -C "${_PWD}" rev-parse --show-toplevel 2> /dev/null || true)"
    if [[ -n "${_GIT_ROOT}" ]]; then
        _BIND_DIR="${_GIT_ROOT}"
    fi

    # Guard: if the resolved bind directory IS the home directory, the
    # --bind would mount the real host $HOME over the protective tmpfs,
    # exposing the entire home tree read-write inside the sandbox.
    if [[ "${_BIND_DIR}" == "${_HOME}" ]]; then
        echo "Error: refusing to run from your home directory (${_HOME})." >&2
        echo "The sandbox bind-mounts the working directory read-write and" >&2
        echo "cannot safely do so for the entire home directory." >&2
        echo "Please cd into a project directory (ideally a git repo) first." >&2
        exit 1
    fi

    # If the bind dir is under HOME, create intermediate directories
    # in the tmpfs so the bind mount point is reachable.
    if [[ "${_BIND_DIR}" == "${_HOME}"/* ]]; then
        local _rel="${_BIND_DIR#"${_HOME}"/}"
        local _accum="${_HOME}"
        local _parts
        IFS='/' read -ra _parts <<< "${_rel}"
        # Create all intermediate dirs except the final component (which
        # will be the bind mount point itself).
        local _i
        for ((_i = 0; _i < ${#_parts[@]} - 1; _i++)); do
            _accum="${_accum}/${_parts[$_i]}"
            BWRAP_ARGS+=(--dir "${_accum}")
        done
    fi
    BWRAP_ARGS+=(
        --bind "${_BIND_DIR}" "${_BIND_DIR}"
    )
}

# ── Git config (read-only) ──────────────────────────────────────
build_git_mounts() {
    # Resolve symlinks so we bind the real file (readlink -f is a no-op on regular files).
    if [[ -f "${_HOME}/.gitconfig" ]]; then
        BWRAP_ARGS+=(--ro-bind "$(readlink -f "${_HOME}/.gitconfig")" "${_HOME}/.gitconfig")
    fi
    if [[ -d "${XDG_CONFIG_HOME}/git" ]]; then
        BWRAP_ARGS+=(--ro-bind "${XDG_CONFIG_HOME}/git" "${XDG_CONFIG_HOME}/git")
    fi

    # Git include files (read-only)
    declare -A _GIT_INC_DIRS_SEEN=()
    local inc_path local_parent
    for inc_path in "${GIT_INCLUDE_PATHS[@]+"${GIT_INCLUDE_PATHS[@]}"}"; do
        # Ensure parent directory exists as a mount point (deduplicated)
        local_parent="${inc_path%/*}"
        if [[ -z "${_GIT_INC_DIRS_SEEN["${local_parent}"]:-}" ]]; then
            _GIT_INC_DIRS_SEEN["${local_parent}"]=1
            BWRAP_ARGS+=(--dir "${local_parent}")
        fi
        BWRAP_ARGS+=(--ro-bind-try "${inc_path}" "${inc_path}")
    done
}

# ── Pixi cache (read-write) + config (read-only) ────────────────
build_pixi_mounts() {
    if [[ -d "${PIXI_HOME_DIR}" ]]; then
        BWRAP_ARGS+=(--bind "${PIXI_HOME_DIR}" "${PIXI_HOME_DIR}")
    fi

    # Pixi checks multiple config locations; bind any that exist.
    if [[ -f "${XDG_CONFIG_HOME}/pixi/config.toml" ]]; then
        BWRAP_ARGS+=(
            --dir "${XDG_CONFIG_HOME}/pixi"
            --ro-bind "${XDG_CONFIG_HOME}/pixi/config.toml" "${XDG_CONFIG_HOME}/pixi/config.toml"
        )
    fi
    if [[ -f "${_HOME}/.pixi/config.toml" ]]; then
        # Already available via the pixi overlay, but if the overlay is not
        # present (dir doesn't exist), bind it explicitly.
        if [[ ! -d "${PIXI_HOME_DIR}" ]]; then
            BWRAP_ARGS+=(--ro-bind "${_HOME}/.pixi/config.toml" "${_HOME}/.pixi/config.toml")
        fi
    fi
}

# ── ccache config (read-only) + cache (read-write) ──────────────
build_ccache_mounts() {
    if [[ -d "${CCACHE_CONFIG_DIR}" ]]; then
        BWRAP_ARGS+=(
            --dir "${CCACHE_CONFIG_DIR%/*}"
            --ro-bind "${CCACHE_CONFIG_DIR}" "${CCACHE_CONFIG_DIR}"
        )
    fi

    if [[ -d "${CCACHE_CACHE_DIR}" ]]; then
        BWRAP_ARGS+=(--bind "${CCACHE_CACHE_DIR}" "${CCACHE_CACHE_DIR}")
    fi
}

# ── npm config (read-only) + cache (read-write) ─────────────────
build_npm_mounts() {
    if [[ -f "${_HOME}/.npmrc" ]]; then
        BWRAP_ARGS+=(--ro-bind "${_HOME}/.npmrc" "${_HOME}/.npmrc")
    fi

    if [[ -d "${NPM_CACHE_DIR}" ]]; then
        BWRAP_ARGS+=(--bind "${NPM_CACHE_DIR}" "${NPM_CACHE_DIR}")
    fi
}

# ── User binaries (read-only) ───────────────────────────────────
build_user_bin_mount() {
    if [[ -d "${_HOME}/bin" ]]; then
        BWRAP_ARGS+=(--ro-bind "${_HOME}/bin" "${_HOME}/bin")
    fi
}

# ── NSLS-II software (read-only) ────────────────────────────────
# Only bind if the directory exists on the host system.
build_nsls2_mount() {
    if [[ -d /nsls2/software/bin ]]; then
        BWRAP_ARGS+=(
            --dir /nsls2/software
            --ro-bind /nsls2/software/bin /nsls2/software/bin
        )
    fi
}

# ── Dynamic tool mounts (tool binary, pixi, npm global) ──────────
# Pre-populate _MOUNTED_PREFIXES with every directory tree that is
# already unconditionally mounted above so _mount_ro_dir_if_needed
# skips them without re-mounting.
build_dynamic_tool_mounts() {
    local _preloaded
    for _preloaded in \
            /usr /bin /sbin /lib /lib64 \
            /proc /dev /tmp \
            "${PIXI_HOME_DIR}" \
            /nsls2/software/bin; do
        [[ -e "${_preloaded}" ]] && _MOUNTED_PREFIXES["${_preloaded}"]=1
    done

    # Resolve each tool binary dynamically.  resolve_and_mount_tool handles
    # the symlink chain and detects npm-installed binaries automatically,
    # delegating to _mount_npm_global_prefix for those.
    local _tool_bin
    for _tool_bin in \
            "${_TOOL_BIN}" \
            "$(command -v pixi 2> /dev/null || true)"; do
        [[ -n "${_tool_bin}" ]] && resolve_and_mount_tool "${_tool_bin}"
    done

    # npm global prefix: mount even when the tool is not npm-installed so
    # that any globally-installed Node.js tools are available in the sandbox.
    _mount_npm_global_prefix

    finalize_sandbox_path
}

# ── Environment variables ────────────────────────────────────────
# Start from a clean environment and only pass through what we need.
build_env_vars() {
    if [[ "${HAS_CLEARENV}" -eq 1 ]]; then
        BWRAP_ARGS+=(--clearenv)
    else
        # Fallback for bwrap < 0.5.0: manually unset all host env vars.
        # We use compgen -e to list all exported vars and unset each one.
        # Note: we already exec with env -i, but --unsetenv ensures any
        # vars inherited through other means are also cleared.
        local _envvar
        for _envvar in $(compgen -e); do
            BWRAP_ARGS+=(--unsetenv "${_envvar}")
        done
    fi

    # Always set
    BWRAP_ARGS+=(
        --setenv HOME "${_HOME}"
        --setenv USER "${USER}"
        --setenv LOGNAME "${USER}"
        --setenv SHELL "${SANDBOX_SHELL}"
        --setenv PATH "${SANDBOX_PATH}"
        --setenv PWD "${_PWD}"
        --setenv TERM "${TERM:-xterm-256color}"
    )

    # Terminal
    pass_through_if_set COLORTERM
    pass_through_if_set TERM_PROGRAM

    # Locale
    pass_through_if_set LANG
    pass_through_if_set LC_ALL
    pass_through_if_set LC_CTYPE
    pass_through_if_set LC_MESSAGES
    pass_through_if_set LC_COLLATE
    pass_through_if_set LC_NUMERIC
    pass_through_if_set LC_TIME
    pass_through_if_set LC_MONETARY

    # XDG (only if explicitly set by user)
    pass_through_if_set XDG_CONFIG_HOME
    pass_through_if_set XDG_DATA_HOME
    pass_through_if_set XDG_CACHE_HOME

    # Tool-specific
    pass_through_if_set CCACHE_DIR
    pass_through_if_set PIXI_HOME
    pass_through_if_set NPM_CONFIG_CACHE

    # Editor
    pass_through_if_set EDITOR
    pass_through_if_set VISUAL

    # Proxy
    pass_through_if_set HTTP_PROXY
    pass_through_if_set HTTPS_PROXY
    pass_through_if_set NO_PROXY
    pass_through_if_set http_proxy
    pass_through_if_set https_proxy
    pass_through_if_set no_proxy

    # Git identity
    pass_through_if_set GIT_AUTHOR_NAME
    pass_through_if_set GIT_AUTHOR_EMAIL
    pass_through_if_set GIT_COMMITTER_NAME
    pass_through_if_set GIT_COMMITTER_EMAIL
}

# ═══════════════════════════════════════════════════════════════════
# Shared launch functions
# ═══════════════════════════════════════════════════════════════════

# Resolve the `env` binary to an absolute path, immune to PATH shadowing.
#
# env is the very first program in the exec chain used by launch_sandbox;
# if it is shadowed (e.g., by a user script earlier on PATH named "env"),
# nothing downstream — bwrap, the tool itself — gets a chance to run
# correctly.  Users almost never have a legitimate reason to provide a
# local override of `env`, so we prefer the canonical /usr/bin/env.
#
# Resolution order:
#   1. /usr/bin/env if it exists and is executable (FHS-mandated location,
#      present on every Linux distro this script targets).
#   2. Fallback to `command -v env` for exotic systems (NixOS, etc.).
#      Note: this fallback IS susceptible to PATH shadowing — but if the
#      canonical location is absent, we have no better option.
#
# Echoes the resolved path to stdout.  Exits with an error if neither
# strategy finds an executable env.
resolve_env_bin() {
    if [[ -x /usr/bin/env ]]; then
        echo /usr/bin/env
        return 0
    fi
    local _env_bin
    _env_bin="$(command -v env 2> /dev/null || true)"
    if [[ -n "${_env_bin}" ]] && [[ -x "${_env_bin}" ]]; then
        echo "${_env_bin}"
        return 0
    fi
    echo "Error: cannot locate the 'env' binary (/usr/bin/env missing and no env on PATH)." >&2
    exit 1
}

print_dry_run() {
    local _BWRAP_BIN _ENV_BIN
    _BWRAP_BIN="$(command -v bwrap)"
    _ENV_BIN="$(resolve_env_bin)"

    # Mirror the exact invocation used by launch_sandbox:
    #   exec <env_bin> -i <vars> <bwrap_bin> <BWRAP_ARGS> -- <_TOOL_CMD> <TOOL_ARGS>
    printf "exec %s -i \\\\\n" "${_ENV_BIN}"
    printf "  HOME=%q \\\\\n"    "${_HOME}"
    printf "  USER=%q \\\\\n"    "${USER}"
    printf "  LOGNAME=%q \\\\\n" "${USER}"
    printf "  PATH=%q \\\\\n"    "/usr/bin:/bin"
    printf "  LANG=%q \\\\\n"    "${LANG:-C.UTF-8}"
    printf "  LC_CTYPE=%q \\\\\n" "${LC_CTYPE:-C.UTF-8}"
    printf "  %s \\\\\n" "${_BWRAP_BIN}"

    # Print bwrap arguments one per line, quoting values with spaces
    local i=0 arg
    while [[ $i -lt ${#BWRAP_ARGS[@]} ]]; do
        arg="${BWRAP_ARGS[$i]}"
        if [[ "${arg}" == --* ]]; then
            # It's a flag; figure out how many values follow
            printf "    %s" "${arg}"
            i=$((i + 1))
            # Print subsequent non-flag arguments on the same line
            while [[ $i -lt ${#BWRAP_ARGS[@]} ]] && [[ "${BWRAP_ARGS[$i]}" != --* ]]; do
                printf " '%s'" "${BWRAP_ARGS[$i]}"
                i=$((i + 1))
            done
            printf " \\\\\n"
        else
            printf "    '%s' \\\\\n" "${arg}"
            i=$((i + 1))
        fi
    done
    printf "    --"
    local _cmd_part
    for _cmd_part in "${_TOOL_CMD[@]}"; do printf " %q" "${_cmd_part}"; done
    local _arg
    for _arg in ${TOOL_ARGS[@]+"${TOOL_ARGS[@]}"}; do printf " %q" "${_arg}"; done
    printf "\n"
    exit 0
}

# Launch bwrap itself with a scrubbed environment so /proc/1/environ
# does not leak host variables (SSH_AUTH_SOCK, DBUS_SESSION_BUS_ADDRESS, etc.).
#
# `env` is resolved via resolve_env_bin (prefers /usr/bin/env) rather than
# via PATH lookup at exec time — this prevents a user shell script named
# "env" earlier on PATH from hijacking the launch.  See resolve_env_bin.
launch_sandbox() {
    local _BWRAP_BIN _ENV_BIN
    _BWRAP_BIN="$(command -v bwrap)"
    _ENV_BIN="$(resolve_env_bin)"

    exec "${_ENV_BIN}" -i \
        HOME="${_HOME}" \
        USER="${USER}" \
        LOGNAME="${USER}" \
        PATH="/usr/bin:/bin" \
        LANG="${LANG:-C.UTF-8}" \
        LC_CTYPE="${LC_CTYPE:-C.UTF-8}" \
        "${_BWRAP_BIN}" "${BWRAP_ARGS[@]}" -- "${_TOOL_CMD[@]}" ${TOOL_ARGS[@]+"${TOOL_ARGS[@]}"}
}
