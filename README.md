# SSH key installer

This repository contains a script that installs every SSH public-key file beside
it into the logged-in user's `~/.ssh/authorized_keys`.

## Usage

```bash
./install-ssh-hardware-keys.sh --dry-run
./install-ssh-hardware-keys.sh
```

Add public keys to this directory with a `.pub` extension, for example:

```text
id_ed25519_sk.pub
id_ed25519_sk_backup.pub
```

The script validates each key, avoids duplicates, preserves existing entries,
and creates a timestamped backup before modifying `authorized_keys`.

Only publish public keys here. Never add private key handles, seed phrases,
PINs, or other secrets.

## License

Copyright © 2026 Nastic. Use and modify as needed for your own systems.
