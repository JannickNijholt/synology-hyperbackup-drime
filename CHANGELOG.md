# Changelog

## Unreleased

- Verified against the live Drime API: installer, all 25 protocol checks, and `selftest.sh` pass. Results are in `docs/research.md`.
- `selftest.sh`: the bridge's certificate is now trusted only for calls to the bridge. Before, it replaced the system CAs for the direct Drime checks too, which made them fail against real Drime. Listing failures now fail their check instead of looking like an empty folder.
- Protocol test: the interrupted-upload checks wait for the abort to finish, as slower real backends need.
- Docs: memory figures for live Drime (~75–80 MiB during backups), and a new known gap: an upload in progress is visible at its key.
- `drime-bridge.sh start` refuses to start when another process already holds the port (e.g. the Container Manager variant), instead of reporting success.
- Guard checks rewritten as `if` statements for older ShellCheck (no behaviour change).

## v0.1.0 (2026-10-20)

First release.

- `drime-bridge.sh`: runs rclone `serve s3` on the Drime backend, write-through (no VFS cache), TLS on `127.0.0.1:18443`. A supervisor restarts rclone if it exits. Commands: `start`, `stop`, `restart`, `status`, end-to-end `health` (optionally with a DSM notification), `logs`, `cleanup`, `version`.
- `install.sh`: downloads rclone 1.75.2 and verifies its SHA-256. Stores the Drime token from a hidden prompt, creates the Drime folder and bucket, generates a self-signed certificate and S3 keys, and starts the bridge. Idempotent. Supports a Container Manager variant (`--container`).
- `selftest.sh`: end-to-end test with real uploads through the bridge into Drime.
- `compose.yaml`: Container Manager variant (read-only filesystem, memory cap, localhost-only port).
- Tests: S3 protocol checks for every Hyper Backup requirement found in the research, interrupted-upload safety, crash restart. CI on x86-64 and arm64 against pinned and latest rclone.
- Docs: research and rationale, setup, Hyper Backup settings and restore, operations.
