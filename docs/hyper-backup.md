# Hyper Backup settings

## Creating the task

Hyper Backup → **+** → Data backup task → **S3 Storage** → Create backup task.

| Field | Value | Why |
|---|---|---|
| S3 Server | Custom Server URL | |
| Server address | `127.0.0.1:18443` | The bridge, on this NAS only |
| Signature version | v4 | Path-style requests need v4 |
| Request style | Path style | The bridge serves buckets as paths. Virtual-host style would need wildcard DNS. |
| Access key / Secret key | from `bridge.conf` | Keys for the bridge, **not** your Drime token |
| Bucket name | `hyperbackup` | Select it from the list. Each bucket is a folder under `HyperBackup/` in Drime. |
| Directory | e.g. `nas01` | One directory per task |

If Hyper Backup offers a **transfer encryption** option, leave it on. The bridge only speaks HTTPS.

If it warns about the certificate, accept it. The certificate is the bridge's own self-signed one, created by the installer, and the connection never leaves the NAS.

## Recommended task options

| Setting | Recommendation | Why |
|---|---|---|
| Client-side encryption | **On** | Drime then only ever stores ciphertext. Keep the password **and** the `.pem` key file Hyper Backup offers somewhere other than this NAS. Without them the backup can't be restored. |
| Compression | On | Fewer bytes to upload |
| Multipart upload part size | **64 MB** (if your version shows the option) | Most of Hyper Backup's files are smaller than this, so they go up as single PUTs: the simplest, MD5-checked path. Larger files go in parts small enough that the bridge never has to hold much in RAM. |
| Backup schedule | Daily, outside office hours | |
| Integrity check schedule | Monthly | Catches problems early. The "check backup data integrity" variant downloads data from Drime, so run it less often on slow lines. |
| Rotation | Smart Recycle, or a version count that fits your Drime quota | |
| Configuration backup | On | |

Don't back up `/volume1/drime-bridge` itself: it holds the Drime token. It isn't a shared folder, so Hyper Backup won't offer it by default.

## The first run

The first backup uploads everything, so it takes as long as your upload speed demands. While it runs:

```bash
/volume1/drime-bridge/drime-bridge.sh status   # memory use of the bridge
/volume1/drime-bridge/drime-bridge.sh logs     # errors, if any
```

After the first run completes, start an integrity check by hand (Hyper Backup → task → ⋯ → Check backup integrity). If it passes, you have a working setup. Please share the result in a [validation report](../../../issues/new?template=validation-report.yml).

## Restoring

### On this NAS, or a new one

The backup data lives in Drime, so a new NAS only needs the bridge:

1. Install the bridge (see [setup](setup.md)) and give it a token for the **same Drime account**. Keep the default `--folder` and `--bucket`, or whatever you used before.
2. Hyper Backup → Restore → Data → S3 Storage, with the same settings as above. Choose the existing task directory, and enter the encryption password or key if you used client-side encryption.

The S3 keys may differ from the old NAS; they only protect the bridge.

### Without a NAS

1. Install rclone on any computer and add a Drime remote: run `rclone config`, then choose `drime` and paste a token.
2. Download the task's backup folder:
   ```bash
   rclone copy drime:HyperBackup/hyperbackup/nas01 ./restore --progress
   ```
3. Open `SynologyHyperBackup.bkpi` inside the downloaded `.hbk` folder with the desktop **Hyper Backup Explorer** (Synology Download Center, Windows, macOS or Linux), then browse versions and copy files out.

Synology documents the Explorer for local, NAS and C2 backups. Opening a `.hbk` folder downloaded from S3 storage is community-tested, not officially documented. Try it once before you need it.

### Test restores

Restore a few files to a scratch folder after the first backup, and again every few months. Integrity checks prove the data is consistent. Only a restore proves you can get it back.
