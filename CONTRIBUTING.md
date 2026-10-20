# Contributing

## Most useful right now: validation reports

Running the bridge with Hyper Backup on a real NAS? Please file a [validation report](../../issues/new?template=validation-report.yml), even (especially) if something failed. Each report tells everyone whether a DSM version, Hyper Backup version and NAS model combination works.

Remove anything personal before posting: tokens, keys, hostnames, IP addresses, share names.

## Running the tests

`tests/run-local.sh` installs the bridge into a temporary folder and runs it against a stand-in for Drime: an rclone `crypt` remote, which, like Drime, supports no hashes. It then runs the S3 protocol checks, `selftest.sh`, a crash-restart test and stop/status. You need neither a NAS nor a Drime account.

```bash
python3 -m pip install boto3
sh tests/run-local.sh /path/to/rclone
```

CI runs the same tests on x86-64 and arm64, against the pinned rclone version and the latest release, on every push and weekly.

## Code style

- Scripts are POSIX `sh`: no bashisms. DSM's `/bin/sh` is bash, but the container image uses BusyBox ash.
- They must pass `shellcheck -s sh -x bridge/*.sh tests/*.sh`.
- Keep the bridge small. A new rclone flag or option needs a reason in `docs/`, ideally with a test.
- Any change to data safety (acknowledgement, caching, retries) needs a test in `tests/` showing the behaviour.

## Releasing

1. Bump `RCLONE_VERSION` in `bridge/install.sh` and the image tag in `bridge/compose.yaml` together, but only to a version CI has passed.
2. Update `CHANGELOG.md` and the version in the README download commands.
3. Tag `vX.Y.Z`.
