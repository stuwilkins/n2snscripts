#!/usr/bin/env bash
# gpg-passwd.sh — Decrypt GPG-encrypted env files into the current shell.
#
# Provides:
#   decrypt_env_file <gpg_file> [required_var ...]
#       Decrypt a gpg-encrypted env file and eval its contents in the
#       current shell. When required vars are listed, verify they are
#       non-empty after the eval.
#
#       Returns:
#         0 - success, or file is unreadable (warning emitted; caller may
#             continue)
#         2 - decrypt succeeded but a required variable is still unset
#             or empty (also returned when gpg_file argument is missing)
#         3 - gpg decrypt failed
#
# Usage (in a caller script):
#   # Source the library by its installed path; substitute the correct
#   # path for the deployment layout.
#   # shellcheck source=/dev/null
#   source <path-to>/n2snscripts/lib/gpg-passwd.sh
#   decrypt_env_file "$HOME/.zshrc.private.gpg" AIFAPIM_HOST AIFAPIM_API_KEY
#
# Portability:
#   This file uses only portable bash syntax and works in both bash and
#   zsh; the original lives in dotfiles/config/bashrc-functions and is
#   also sourced from zshrc-functions.

# Guard against double-sourcing.
[[ -n "${_GPG_PASSWD_LIB_SOURCED:-}" ]] && return 0
_GPG_PASSWD_LIB_SOURCED=1

decrypt_env_file() {
    local gpg_file="$1"
    shift || true
    local required_vars=("$@")

    if [[ -z "$gpg_file" ]]; then
        printf 'decrypt_env_file: missing gpg_file argument\n' >&2
        return 2
    fi

    if [[ ! -r "$gpg_file" ]]; then
        printf 'decrypt_env_file: %s not found or unreadable; skipping decrypt.\n' "$gpg_file" >&2
        return 0
    fi

    local decrypted gpg_rc
    decrypted="$(gpg --quiet --batch --yes --decrypt "$gpg_file")"
    gpg_rc=$?
    if ((gpg_rc != 0)); then
        printf 'decrypt_env_file: gpg --decrypt %s failed (exit %d).\n' "$gpg_file" "$gpg_rc" >&2
        return 3
    fi
    eval "$decrypted"
    unset decrypted

    local var value
    for var in "${required_vars[@]}"; do
        eval "value=\${$var:-}"
        if [[ -z "$value" ]]; then
            printf 'decrypt_env_file: required variable %s is still empty after decrypt.\n' "$var" >&2
            return 2
        fi
    done

    return 0
}
