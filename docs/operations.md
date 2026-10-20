# Operations

## Commands

```bash
B=/volume1/drime-bridge
$B/drime-bridge.sh status        # running? listening? memory use
$B/drime-bridge.sh health        # end to end: S3 request -> bridge -> Drime API
$B/drime-bridge.sh logs [N]      # last N lines of the rclone log (default 50)
$B/drime-bridge.sh restart       # after changing bridge.conf
$B/drime-bridge.sh stop
$B/drime-bridge.sh cleanup       # remove leftovers of interrupted uploads
$B/drime-bridge.sh version
$B/selftest.sh [MiB]             # end-to-end test with real uploads
```

Exit codes: `health` returns non-zero when the round trip fails, and `status` returns 3 when the bridge isn't running. That makes both usable in Task Scheduler with "email on abnormal termination".

## Logs

- `logs/bridge.log`: rclone's log at `LOG_LEVEL`. It rotates at 10 MB and keeps 5 compressed copies.
- `logs/supervisor.log`: start, stop and automatic restarts.

To see exactly which S3 calls Hyper Backup makes (useful for bug reports):

1. Set `LOG_LEVEL="DEBUG"` in `bridge.conf`, then `drime-bridge.sh restart`.
2. Run the backup, then `grep "serve s3:" logs/bridge.log` shows one line per S3 operation.
3. Set it back to `NOTICE` and restart. DEBUG logs grow quickly.

The logs contain object names and paths, but never the Drime token or the S3 secret. Still, check them before posting.

## Upgrading

- **Bridge scripts:** download the new release and run its `install.sh` again. Configuration, keys, certificate and token are kept, and the bridge restarts.
- **rclone:** each release of this project pins an rclone version that CI has tested. To try a newer one before a release does:
  ```bash
  RCLONE_VERSION=1.75.3 sh install.sh
  ```
  Then run `selftest.sh`. To go back, re-run with the previous version.

Don't use `rclone selfupdate` on the bridge binary. Keep the version the installer pinned and verified.

## Tuning

All settings live in `bridge.conf`; restart after changing them.

| Setting | Default | Notes |
|---|---|---|
| `MEMORY_LIMIT` | `256MiB` | Soft target for rclone's garbage collector (`GOMEMLIMIT`), not a hard cap |
| `MULTIPART_BUFFER_PER_UPLOAD` | `128M` | RAM for multipart parts that arrive out of order, per upload |
| `MULTIPART_BUFFER_TOTAL` | `256M` | The same, across all uploads |
| `LOG_LEVEL` | `NOTICE` | `DEBUG` to trace S3 calls |
| `BWLIMIT` | empty | Upload limit, optionally a timetable: `"08:00,20M 23:00,off"` caps uploads at 20 MiB/s during the day |
| `EXTRA_FLAGS` | empty | Extra rclone flags separated by spaces, e.g. `--tpslimit 20` |

**Low-RAM models (1 GB or less):** set `MEMORY_LIMIT="128MiB"`, `MULTIPART_BUFFER_PER_UPLOAD="32M"` and `MULTIPART_BUFFER_TOTAL="64M"`, and use a 16 MB multipart part size in Hyper Backup.

**Fast uplinks:** add `--drime-chunk-size 16M` to `EXTRA_FLAGS` for fewer, larger chunks to Drime. Each file in flight then holds 4 × 16 MiB in RAM instead of 4 × 5 MiB.

Never add `--vfs-cache-mode` (`minimal`, `writes` or `full`). The cache would answer Hyper Backup before Drime has the data. That is exactly the relay problem this project exists to avoid.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Hyper Backup can't connect or lists no buckets | Bridge not running, or wrong address or keys | `drime-bridge.sh health`; check `127.0.0.1:18443`, v4 and Path style |
| `health` fails with 401/403 from Drime | Token revoked or expired | `install.sh --new-token` |
| `health` fails with a TLS error | Certificate files missing or changed | Delete `tls/` and re-run `install.sh` (new certificate; re-accept it in Hyper Backup) |
| Hyper Backup reports "ETag" errors | A Hyper Backup call that needs an ETag Drime can't provide ([known gap](research.md#6-known-gaps-and-open-questions)) | Capture a DEBUG log and open an issue |
| Backups slow, `SlowDown` in the log | Multipart parts arriving out of order faster than they can be sent on | Lower the part size in Hyper Backup, or raise the buffer caps |
| Many HTTP 429 lines in the log | Drime's 2,000 requests/min limit | rclone backs off and retries automatically. If it persists, add `--tpslimit 20` to `EXTRA_FLAGS`. |
| Bridge not running after a reboot | Boot-up task missing or disabled | Task Scheduler → check the task, or run it once by hand |
| `bridge did not start listening` | Port in use, or a bad flag in `EXTRA_FLAGS` | `drime-bridge.sh logs`; change `LISTEN_ADDR` if 18443 is taken |

Interrupted uploads, from a reboot during a backup or a lost connection, are safe. The bridge never stores a partial object, and Hyper Backup picks up again on its next run. Run a Hyper Backup integrity check after any unplanned interruption.
