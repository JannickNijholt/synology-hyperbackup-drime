# Changelog

## v0.1.0 (2026-10-20)

First release.

- `drime-bridge.sh`: runs rclone `serve s3` on the Drime backend, write-through (no VFS cache), TLS on `127.0.0.1:18443`. A supervisor restarts rclone if it exits. Commands: `start`, `stop`, `restart`, `status`, end-to-end `health` (optionally with a DSM notification), `logs`, `cleanup`, `version`.
- `install.sh`: downloads rclone 1.75.2 and verifies its SHA-256. Stores the Drime token from a hidden prompt, creates the Drime folder and bucket, generates a self-signed certificate and S3 keys, and starts the bridge. Idempotent. Supports a Container Manager variant (`--container`).
- `selftest.sh`: end-to-end test with real uploads through the bridge into Drime.
- `compose.yaml`: Container Manager variant (read-only filesystem, memory cap, localhost-only port).
- Tests: S3 protocol checks for every Hyper Backup requirement found in the research, interrupted-upload safety, crash restart. CI on x86-64 and arm64 against pinned and latest rclone.
- Docs: research and rationale, setup, Hyper Backup settings and restore, operations.
