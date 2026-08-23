#!/usr/bin/env bash
# Install every SSH public key beside this script into the logged-in user's
# authorized_keys. Run: bash install-ssh-hardware-keys.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# The script intentionally discovers only regular *.pub files in its own
# directory. Keep private keys, seed material, and secrets out of this folder.
mapfile -t KEY_FILES < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name '*.pub' -print | sort)

usage() {
    cat <<'EOF'
Usage: install-ssh-hardware-keys.sh [--dry-run] [--help]

Installs every regular *.pub file beside this script into the current user's
~/.ssh/authorized_keys. Existing keys are preserved and duplicates are not
added. The files are processed in sorted filename order.
EOF
}

DRY_RUN=0
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

if [[ "${#KEY_FILES[@]}" -eq 0 ]]; then
    printf 'No .pub files found beside the script: %s\n' "$SCRIPT_DIR" >&2
    exit 2
fi

if [[ "$(id -u)" -eq 0 && -z "${SUDO_USER:-}" && -z "${HOME:-}" ]]; then
    printf 'Could not determine the target home directory.\n' >&2
    exit 1
fi

TARGET_USER="${USER:-$(id -un)}"
TARGET_HOME="${HOME:?HOME is not set}"
SSH_DIR="$TARGET_HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

if [[ "$TARGET_HOME" == "/" || -z "$TARGET_HOME" ]]; then
    printf 'Refusing unsafe home directory: %s\n' "$TARGET_HOME" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
CANDIDATES="$TMP_DIR/candidates"
: > "$CANDIDATES"

add_key_line() {
    local source="$1"
    local line="$2"
    local key_type key_blob

    [[ -n "$line" ]] || return 0
    [[ "$line" != \#* ]] || return 0

    read -r key_type key_blob _ <<< "$line"
    if [[ -z "${key_type:-}" || -z "${key_blob:-}" ]]; then
        printf 'Invalid public-key line from %s\n' "$source" >&2
        exit 1
    fi

    case "$key_type" in
        ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
        *) printf 'Unsupported or malformed key type from %s: %s\n' "$source" "$key_type" >&2; exit 1 ;;
    esac

    # ssh-keygen performs the authoritative format/base64 validation.
    printf '%s\n' "$line" > "$TMP_DIR/check.pub"
    ssh-keygen -lf "$TMP_DIR/check.pub" >/dev/null 2>&1 || {
        printf 'Invalid SSH public key from %s\n' "$source" >&2
        exit 1
    }

    # Keep the complete line, including its useful identifying comment.
    printf '%s\n' "$line" >> "$CANDIDATES"
}

for key_file in "${KEY_FILES[@]}"; do
    [[ -f "$key_file" && ! -L "$key_file" ]] || {
        printf 'Key file is missing or is a symlink: %s\n' "$key_file" >&2
        exit 1
    }
    line_count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        line_count=$((line_count + 1))
        add_key_line "$key_file" "$line"
    done < "$key_file"
    [[ "$line_count" -eq 1 ]] || {
        printf 'Expected exactly one public-key line in %s; found %s\n' "$key_file" "$line_count" >&2
        exit 1
    }
done

if [[ ! -s "$CANDIDATES" ]]; then
    printf 'No usable keys were configured.\n' >&2
    exit 2
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'Target user: %s\n' "$TARGET_USER"
    printf 'Target file: %s\n' "$AUTHORIZED_KEYS"
    printf 'Keys to install:\n'
    while IFS= read -r line; do ssh-keygen -lf <(printf '%s\n' "$line"); done < "$CANDIDATES"
    exit 0
fi

umask 077
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -e "$AUTHORIZED_KEYS" ]]; then
    [[ -f "$AUTHORIZED_KEYS" && ! -L "$AUTHORIZED_KEYS" ]] || {
        printf 'Refusing unsafe authorized_keys path: %s\n' "$AUTHORIZED_KEYS" >&2
        exit 1
    }
    chmod 600 "$AUTHORIZED_KEYS"
else
    : > "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
fi

BACKUP="$AUTHORIZED_KEYS.backup.$(date +%Y%m%d-%H%M%S)-$$"
cp -p "$AUTHORIZED_KEYS" "$BACKUP"

added=0
skipped=0
while IFS= read -r candidate; do
    candidate_blob="$(printf '%s\n' "$candidate" | cut -d' ' -f2)"
    found=0
    while IFS= read -r existing; do
        [[ -z "$existing" || "$existing" == \#* ]] && continue
        existing_blob="$(printf '%s\n' "$existing" | cut -d' ' -f2)"
        if [[ "$candidate_blob" == "$existing_blob" ]]; then
            found=1
            break
        fi
    done < "$AUTHORIZED_KEYS"

    if [[ "$found" -eq 1 ]]; then
        skipped=$((skipped + 1))
    else
        printf '%s\n' "$candidate" >> "$AUTHORIZED_KEYS"
        added=$((added + 1))
    fi
done < "$CANDIDATES"

chmod 600 "$AUTHORIZED_KEYS"
printf 'Target user: %s\n' "$TARGET_USER"
printf 'Installed: %s\n' "$AUTHORIZED_KEYS"
printf 'Added: %s; already present: %s\n' "$added" "$skipped"
printf 'Backup: %s\n' "$BACKUP"
printf 'Validate with: sshd -t  (if you manage the SSH server)\n'
