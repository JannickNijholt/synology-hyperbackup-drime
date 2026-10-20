# Setup

There are two ways to run the bridge. Both use the same installer and the same folder layout.

- **Option A, boot-up task (recommended):** rclone runs directly, started by DSM's Task Scheduler. It has the lowest overhead and works on every model, including those without Container Manager.
- **Option B, Container Manager:** the same rclone flags inside the official `rclone/rclone` image. Pick this if you already run Container Manager and prefer managing services there.

Run only one of them; they use the same port.

## Before you start

1. **Drime token:** in Drime, open Settings → Developer → create a token. Copy it; you paste it once during the install.
2. **SSH, temporarily:** Control Panel → Terminal & SNMP → Enable SSH service. You can switch it off again when you're done.
3. **Log in:** connect as an administrator, then become root:
   ```bash
   ssh your-admin-user@your-nas
   sudo -i
   ```

## Option A: boot-up task

### 1. Download and install

```bash
cd /volume1
curl -fsSLO https://github.com/JannickNijholt/synology-hyperbackup-drime/archive/refs/tags/v0.1.0.tar.gz
tar xzf v0.1.0.tar.gz
sh synology-hyperbackup-drime-0.1.0/bridge/install.sh
```

Installer options:

| Option | Default | Meaning |
|---|---|---|
| `--home DIR` | `/volume1/drime-bridge` | Where the bridge lives. The default is not a shared folder, so it isn't exposed over SMB or File Station. |
| `--folder NAME` | `HyperBackup` | Top-level Drime folder for backups |
| `--bucket NAME` | `hyperbackup` | Sub-folder Hyper Backup sees as its bucket (3–63 chars: `a-z 0-9 . -`) |
| `--new-token` | | Replace the stored Drime token |
| `--container` | | Prepare for Container Manager instead of starting the bridge (Option B) |
| `--rclone-binary PATH` | | Use an rclone binary you downloaded and verified yourself |

What ends up in the bridge folder:

```
drime-bridge/
├── drime-bridge.sh      start | stop | restart | status | health | logs | cleanup | version
├── selftest.sh          end-to-end test with real uploads
├── bridge.conf          settings and S3 keys            (mode 600)
├── rclone.conf          Drime token                     (mode 600)
├── tls/                 self-signed certificate, 10 years
├── bin/rclone           pinned rclone release, SHA-256 verified
├── compose.yaml         used by Option B only
└── logs/                bridge.log (rotated), supervisor.log
```

Once installed, you can delete the downloaded `v0.1.0.tar.gz` and the unpacked release folder.

### 2. Start the bridge at boot

Control Panel → Task Scheduler → Create → Triggered Task → User-defined script

- General: Task name `Drime bridge`, User `root`, Event `Boot-up`
- Task Settings → Run command:
  ```
  /volume1/drime-bridge/drime-bridge.sh start
  ```

`start` returns once the bridge is listening and leaves a small supervisor running that restarts rclone if it ever exits.

### 3. Recommended: daily health check and weekly cleanup

Create two **Scheduled Tasks** (user `root`). Under Task Settings, tick "Send run details by email" and "only when the script terminates abnormally", so DSM emails you when something is wrong.

| Task | Schedule | Command |
|---|---|---|
| Drime bridge health | daily, 30 min before your backup | `/volume1/drime-bridge/drime-bridge.sh health --notify` |
| Drime bridge cleanup | weekly | `/volume1/drime-bridge/drime-bridge.sh cleanup` |

`health` makes a real round trip: S3 request → bridge → Drime API. `cleanup` removes leftovers of uploads interrupted by a crash or power cut (`.rclone_temp_*` objects older than two days).

### 4. Test it end to end

```bash
/volume1/drime-bridge/selftest.sh
```

This uploads 4 KiB, 48 MiB and 160 MiB test files through the bridge (single-part and parallel multipart), reads them back byte for byte, checks that they really are in Drime, then overwrites, deletes and removes everything. Use a smaller number on slow uplinks, for example `selftest.sh 32`.

### 5. Create the Hyper Backup task

See [Hyper Backup settings](hyper-backup.md).

## Option B: Container Manager

Container Manager can only use folders inside a shared folder, so install there:

```bash
sh synology-hyperbackup-drime-0.1.0/bridge/install.sh --container --home /volume1/docker/drime-bridge
```

The installer does everything Option A does except start the bridge. The rclone binary is still installed, because `health`, `cleanup` and `selftest.sh` use it.

Then in Container Manager: Project → Create

- Project name: `drime-bridge`
- Path: `/volume1/docker/drime-bridge`
- Source: use the existing `compose.yaml`

The container:

- publishes the bridge on `127.0.0.1:18443` only
- has a read-only root filesystem and a 512 MB memory cap
- restarts automatically
- logs to Container Manager

Check it with `/volume1/docker/drime-bridge/drime-bridge.sh health`.

Container notes:

- `LISTEN_ADDR` in `bridge.conf` is ignored. To change the port, edit the left side of `127.0.0.1:18443:18443` in `compose.yaml` and use the new port in Hyper Backup.
- To upgrade rclone, change the image tag in `compose.yaml` and rebuild the project. Also re-run the installer with the matching `RCLONE_VERSION`, so the host-side tools stay in step.

## Uninstalling

1. Delete the Hyper Backup task (or keep its data in Drime for restores).
2. Delete the Task Scheduler entries, or the Container Manager project.
3. `/volume1/drime-bridge/drime-bridge.sh stop`
4. `rm -rf /volume1/drime-bridge`
5. Revoke the token in Drime → Settings → Developer.
