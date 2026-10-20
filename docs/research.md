# Research: Hyper Backup to Drime without a middleman

This is the reasoning behind the design. It covers what Drime and Hyper Backup each support, every option that was evaluated, what was tested and what is still open. Research and tests were done in October 2026 against rclone 1.75.2.

## 1. The problem with a relay

The common workaround is Hyper Backup → VPS (or `rclone mount` with a write cache) → Drime. It has one structural flaw: **the place that acknowledges the upload is not the place that stores it.**

Hyper Backup marks a chunk as backed up as soon as its destination says "OK". When that OK comes from a relay disk or a VFS cache, the data still has to make a second trip. If that trip fails (disk full, crash, sync error, token expiry), Hyper Backup's index already claims the data is safe. Integrity checks then fail, or worse, a restore turns up missing chunks.

The fix is a destination that only answers "OK" after Drime has the data, and that keeps no state of its own.

## 2. What Drime offers

| Interface | Status |
|---|---|
| S3-compatible API | None, and not on the [roadmap](https://drime.cloud/roadmap) |
| WebDAV | Planned for 2027 per the [roadmap](https://drime.cloud/roadmap) |
| REST API | Yes ([developer docs](https://docs.drime.cloud)), token from Settings → Developer |
| rclone | **Official backend**, added in rclone 1.73 (Jan 2026) and listed as Tier 1. Drime's roadmap calls it its "Native Rclone Integration" ([rclone docs](https://rclone.org/drime/)). |

Drime properties that matter here, from the rclone backend source and docs:

- **No hashes and no modification times.** rclone can't ask Drime for an MD5, which affects S3 ETags (see §6).
- **Rate limit: 2,000 API requests per minute.** rclone's pacer backs off on HTTP 429.
- **Large uploads use Drime's multipart API** (5 MiB chunks to presigned storage URLs). Only when the upload completes does `/s3/entries` create the file entry, so an aborted upload leaves nothing visible.
- **Overwrite = upload the new file, then delete the old one.** The old file is removed only after the new upload succeeds.
- **Names are limited to 255 bytes.** Hyper Backup's object names are short.
- **Deleted files go to the Drime trash by default.** The installer sets `hard_delete = true`; otherwise every pruned backup version would stay in the trash.

The rclone changelog shows active Drime fixes through 1.74.x and 1.75.2, including uploads landing in the wrong folder and duplicate copies left after overwrites. **Use rclone 1.75.2 or newer.**

## 3. What Hyper Backup accepts

Destinations ([Synology KB](https://kb.synology.com/en-global/DSM/help/HyperBackup/data_backup_destination?version=7)): local folder or USB, remote Synology NAS, rsync server, Synology C2, WebDAV, S3 (Amazon and any S3-compatible server via *Custom Server URL*), OpenStack Swift, Azure, Google Drive, Dropbox, HiDrive and a few regional clouds.

The S3 client's requirements and behaviour:

- **HTTPS only.** "Hyper Backup will only talk to S3 APIs over an encrypted connection", and "Hyper Backup will work with a self signed certificate" ([IT Randomness, 2020](https://web.archive.org/web/2023/https://itrandomness.com/2020/05/local-backups-with-synology-hyper-backup-and-minio/)). This was confirmed again in 2026 in a [RustFS issue](https://github.com/rustfs/rustfs/issues/1398).
- **Path-style requests require Custom Server URL with signature v4** (Synology KB). Older versions only did virtual-host style, so many MinIO guides needed wildcard DNS.
- **Multipart part size**: 8–512 MB, default 512 MB, set in the task settings ([Synology KB](https://kb.synology.com/en-global/DSM/help/HyperBackup/data_backup_destination?version=7), [Storj forum](https://forum.storj.io/t/synology-hyperbackup-settings-for-optimal-storj/26435)).
- **ETag after multipart upload must not be empty.** Hyper Backup's uploader (`img_worker`, `transfer_s3.cpp`) fails with "ETag is empty" when `CompleteMultipartUpload` returns none. This happened with a Ceph RGW bug ([Proxmox forum](https://forum.proxmox.com/threads/ceph-object-gateway-radosgw-multi-part-uploads-and-etag.144687/)).
- **Server-side encryption isn't supported** (Synology KB). The likely reason is that Hyper Backup checks the upload ETag against the MD5 of what it sent, and SSE breaks that relation.
- **S3 actions it needs**, from a [working IAM policy](https://community.synology.com/enu/forum/1/post/136398): ListAllMyBuckets, ListBucket, GetBucketLocation, ListBucketMultipartUploads, GetObject, PutObject, DeleteObject, AbortMultipartUpload and ListMultipartUploadParts. The policy also lists bucket-policy and object-version actions.
- **Data layout**: chunked, deduplicated `.bucket` files (users report sizes around 50 MB) plus index files, inside a `<task>.hbk` folder. The NAS keeps a local index of 1–4 % of the backup size.

## 4. Options evaluated

| Option | Verdict | Why |
|---|---|---|
| Native Drime S3 or WebDAV | Not available | No S3. WebDAV is planned for 2027; revisit when it ships (§8). |
| VPS relay (the common workaround) | Rejected | Acknowledges before Drime has the data (§1). Extra cost and another machine to keep healthy. |
| `rclone mount` as a Hyper Backup local destination | Rejected | Hyper Backup refuses remote-mounted folders as destinations (Synology KB). Even if forced, the VFS write cache acknowledges early, so it fails the same way as the relay. |
| Local Hyper Backup target + scheduled `rclone sync` | Rejected | Needs a full second copy on the NAS. Drime lags behind by up to a sync interval, and Hyper Backup never learns whether the sync worked. |
| Community Drime S3 gateways ([essare/drime-s3](https://github.com/essare/drime-s3), [diegojuan/drime-s3](https://github.com/diegojuan/drime-s3), [pydrime](https://github.com/holgern/pydrime)) | Rejected | Single-maintainer projects with a handful of stars. They need a Bun or Python runtime on the NAS, aren't endorsed by Drime, and none mentions Hyper Backup. pydrime's servers run without authentication by default. |
| `rclone serve webdav` (Hyper Backup's WebDAV destination) | Fallback only | Works with Hyper Backup, and there is published precedent for OneDrive. But **an interrupted upload stores a truncated file** (tested, §5). WebDAV also has no per-upload checksum. |
| **`rclone serve s3` (chosen)** | **Chosen** | Write-through with `--vfs-cache-mode off`. MD5-checked uploads. Interrupted or aborted uploads leave nothing behind. Since rclone 1.75, multipart uploads stream instead of buffering in RAM. One static binary. |

## 5. Test results

All tests are reproducible with [`tests/run-local.sh`](../tests/run-local.sh). The stand-in for Drime is an rclone `crypt` remote, which supports no hashes, just like Drime, so ETag behaviour matches what Hyper Backup sees. Each test was also repeated with a direct-write backend (`memory`), which matches how the Drime backend writes.

**S3 behaviour Hyper Backup relies on** (all pass on rclone 1.75.2, natively and in the container):

| Check | Result |
|---|---|
| ListBuckets, HeadBucket, GetBucketLocation, ListObjects v1 with delimiter, Range GET | pass |
| SigV4 signed for any region (`us-east-1`, `eu-central-1`, `auto`) | pass |
| PutObject returns the MD5 ETag | pass |
| Wrong `Content-MD5` → `BadDigest`, nothing stored | pass |
| Multipart, in order **and** 4 parts in parallel out of order: ListMultipartUploads, ListParts, correct non-empty `CompleteMultipartUpload` ETag, content intact | pass |
| Aborted multipart upload leaves no object | pass |
| **Interrupted PUT stores nothing** | pass |
| **Interrupted overwrite keeps the previous object intact** | pass |
| Overwrite, DeleteObjects, NoSuchKey after delete, wrong secret → 403 | pass |
| TLS with the installer's self-signed certificate | pass |
| rclone's own S3 client (single and multipart, `check --download`) through the bridge | pass |
| Supervisor restarts rclone after `kill -9` | pass (about 5 s) |

**The WebDAV comparison:** a PUT promising 10 MiB that drops after 3 MiB. `serve webdav --vfs-cache-mode off` stored a **3 MiB file** under the final name. `serve s3` stored nothing and left an existing object untouched. That is why WebDAV is the fallback, not the default.

**Memory** (Linux, arm64, anonymous memory of the bridge, `MULTIPART_BUFFER_TOTAL=256M`, measured in the container):

| Workload | Peak |
|---|---|
| Idle | 35 MiB |
| 20 × 50 MB PutObject | 53 MiB |
| 1 GB multipart, 64 MB parts, in order | 52 MiB |
| 1 GB multipart, 64 MB parts, 4 parallel | 178 MiB |
| 1 GB multipart, 16 MB parts, 4 parallel | 180 MiB |
| 1 GB multipart, 512 MB parts, 2 parallel | 52 MiB (the second part waits instead of buffering) |

Throughput was never the bottleneck. Locally the bridge moved 50–100 MiB/s on a laptop, so your upload speed to Drime decides the speed.

**Against the live Drime API** (2026-10-20, macOS arm64, rclone 1.75.2, installed with `install.sh`):

| Test | Result |
|---|---|
| Installer: token check, folder and bucket creation, start, health check | pass |
| All 25 S3 protocol checks (the table above) | pass |
| `selftest.sh`: 4 KiB and 48 MiB single-part, 160 MiB multipart (16 MiB parts, 4 in parallel); byte-for-byte read-back; files present in Drime at the exact sizes; overwrite leaves no duplicate; delete; no temp objects | pass |
| Interrupted overwrite: bridge and Drime both still show the original object (same MD5) | pass |
| Re-running the installer keeps token, keys and certificate | pass |
| Throughput (limited by that test machine's uplink) | 7–15 MiB/s up, 17 MiB/s read-back |
| Memory, sequential 50 MB uploads (macOS RSS) | 58 MiB idle, 106 MiB peak. Against the stand-in on the same machine it was 82 MiB, so the Drime backend adds about 24 MiB. |

On Linux, with its lower baseline, that means about 75–80 MiB during a typical backup.

## 6. Known gaps and open questions

1. **HEAD, LIST and CopyObject return an empty ETag for Drime objects.** rclone can only report an MD5 the backend gives it, and Drime gives none. Upload responses (PutObject, UploadPart, CompleteMultipartUpload) do carry correct ETags, because the bridge computes them from the data as it streams through. Hyper Backup is only *known* to check ETags on upload responses. Whether it also checks them on HEAD or LIST, or uses CopyObject at all, has to be confirmed on real DSM (§7).
   - rclone's `hasher` overlay was tried and doesn't solve this: it doesn't hash streamed uploads, which is every upload over 100 KiB here.
   - A clean fix would be in rclone itself, for example a stable synthetic ETag when the backend has no MD5. That is worth proposing upstream if Hyper Backup turns out to need it.
2. **`serve s3` is labelled "Experimental" upstream**, even though it's actively maintained (1.75.x rewrote multipart streaming and fixed several security issues). Pin the version, and let CI test new releases before upgrading.
3. **AWS "aws-chunked" uploads without `Content-Length`** (newer AWS SDK defaults) are rejected with `MissingContentLength`. Hyper Backup's client predates that scheme.
4. **Failed uploads can leave empty folders in Drime.** They're harmless and invisible to S3 clients, but they stop `DeleteBucket`.
5. **Out-of-order multipart parts are buffered in RAM**, up to the configured caps. A part that doesn't fit waits up to 1 minute for its turn, then gets `SlowDown` and is retried by the client. Keep Hyper Backup's part size moderate (64 MB).
6. **Drime-side eventual consistency:** the rclone backend notes that a renamed folder can list as empty for a short time. The bridge never renames folders, and multipart completion renames a single file.
7. **An upload in progress is visible at its key.** For single-part uploads, rclone writes to Drime under the final name: Drime commits the file only on success, so rclone uses no temp file and rename. While the upload runs, a reader of that same key through the bridge sees the partial new data instead of the old object. Once the upload succeeds or is aborted, everything is consistent again (measured: about a second after the abort on live Drime). Nothing partial is ever stored in Drime. Hyper Backup doesn't read an object while it is writing that same object, so this shouldn't affect it. It is still a deviation from strict S3 semantics, and the protocol test checks the state after the abort rather than during it.

## 7. What is verified and what isn't

| Claim | Status |
|---|---|
| Bridge implements every S3 call and behaviour listed in §3 | Verified by automated tests (§5) |
| Uploads are acknowledged only after the backend has them; no partial objects | Verified by automated tests |
| Runs on Linux arm64 within the memory figures above | Verified (container) |
| Bridge against the live Drime API: all protocol checks, `selftest.sh`, interrupted uploads | Verified (2026-10-20, §5). Run `selftest.sh` to confirm on your own account. |
| Hyper Backup on real DSM: create task, back up, integrity check, restore | **Pending first reports**; please file a [validation report](../../../issues/new?template=validation-report.yml) |

## 8. Future directions

- **Drime native WebDAV (roadmap: 2027).** When it ships, test Hyper Backup's WebDAV destination directly against Drime. If it works and Drime handles interrupted uploads safely, the bridge becomes unnecessary.
- **Upstream improvements** that would remove the gaps in §6: a synthetic ETag in `serve s3` for hashless backends, and hashing of streamed uploads in rclone's `hasher` overlay.

## Sources

- Drime roadmap: <https://drime.cloud/roadmap>
- Drime upload guide: <https://docs.drime.cloud/uploads-guide>
- rclone Drime backend: <https://rclone.org/drime/>
- rclone `serve s3`: <https://rclone.org/commands/rclone_serve_s3/>
- rclone changelog: <https://rclone.org/changelog/>
- Synology KB, Hyper Backup destinations: <https://kb.synology.com/en-global/DSM/help/HyperBackup/data_backup_destination?version=7>
- Hyper Backup and Ceph RGW, "ETag is empty": <https://forum.proxmox.com/threads/ceph-object-gateway-radosgw-multi-part-uploads-and-etag.144687/>
- Hyper Backup and MinIO (TLS, self-signed): <https://web.archive.org/web/2023/https://itrandomness.com/2020/05/local-backups-with-synology-hyper-backup-and-minio/>
- Hyper Backup and RustFS (path style, HTTPS): <https://github.com/rustfs/rustfs/issues/1398>
- Hyper Backup IAM policy for MinIO: <https://community.synology.com/enu/forum/1/post/136398>
- Hyper Backup part size options: <https://forum.storj.io/t/synology-hyperbackup-settings-for-optimal-storj/26435>
- rclone WebDAV bridge for Hyper Backup on a low-RAM DiskStation: <https://forum.rclone.org/t/looking-for-a-resource-saving-and-stable-config-to-run-rclone-on-a-diskstation-for-hyper-backup-to-onedrive/24001>
- Restoring a downloaded `.hbk` with Hyper Backup Explorer: <https://www.synology-forum.de/threads/hbk-folder-download-from-cloud.117538>
