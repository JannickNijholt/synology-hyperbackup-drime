# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: **Security → Report a vulnerability** on this repository. Don't open a public issue. This is a volunteer project, so reports are handled on a best-effort basis.

Vulnerabilities in rclone itself belong with [rclone](https://github.com/rclone/rclone/security). Problems with the Drime service belong with Drime.

## How secrets are handled

| Secret | Where it lives | Protection |
|---|---|---|
| Drime API token | `rclone.conf` in the bridge folder | Mode `600`, in a root-only (`700`) folder that isn't a shared folder. Entered at a hidden prompt, never as a command-line argument. |
| Bridge S3 keys | `bridge.conf` | Mode `600`. Random per install. Passed to rclone via the environment, not the command line, so they don't show up in `ps`. |
| TLS private key | `tls/key.pem` | Mode `600`. Only secures traffic that never leaves the NAS. |

The bridge listens on `127.0.0.1` by default, so other devices can't reach it. If you change `LISTEN_ADDR` to expose it on your network, anyone who has the S3 keys can read and delete your backups in Drime. Don't do that unless you have a specific reason, and never forward the port to the internet.

## Recommendations

- Turn on Hyper Backup's **client-side encryption**, so Drime only stores ciphertext.
- Give the bridge its **own Drime token**, so you can revoke it without affecting anything else.
- Keep the bridge folder out of your backups and out of shared folders.
- Before posting logs in an issue, check them. They contain object names and paths, though never tokens or keys.
