# `gpg-passwd.sh`

Shell library providing `decrypt_env_file`, a helper for sourcing
GPG-encrypted environment files into the current shell. Sourced, not
executed.

## Usage

Source the library and call `decrypt_env_file`:

```bash
source "${N2SNSCRIPTS_LIB}/gpg-passwd.sh"
decrypt_env_file "$HOME/.private_env.gpg" AIFAPIM_HOST AIFAPIM_API_KEY
```

## Behaviour

- Decrypts the file with `gpg --quiet --batch --yes --decrypt` and
  `eval`s the result into the current shell.
- Validates that each required variable named in the call is non-empty
  after decryption.

## Return codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `0` (with warning) | File is missing — no decrypt attempted |
| `2` | A required variable is still empty after decrypt |
| `3` | `gpg` failed (bad passphrase, malformed file, etc.) |

See the library header comment for the full contract.
