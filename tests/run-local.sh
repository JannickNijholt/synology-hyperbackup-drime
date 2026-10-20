#!/bin/sh
# Runs the whole bridge locally against a stand-in for Drime, so changes and
# new rclone releases can be tested without a NAS or a Drime account.
#
# The stand-in is an rclone crypt remote over a local folder: like Drime it
# supports no hashes, so the S3 ETag behaviour matches what Hyper Backup sees.
#
#   tests/run-local.sh [path to rclone binary]
#
# Without a binary, install.sh downloads and verifies its pinned rclone, which
# tests that path too. Needs python3 with boto3 for the protocol checks.

set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
RCLONE_BIN=${1:-}
PYTHON=${PYTHON:-python3}

work=$(mktemp -d)
home="$work/drime-bridge"
cleanup() {
	"$home/drime-bridge.sh" stop >/dev/null 2>&1 || true
	rm -rf "$work"
}
trap cleanup EXIT

echo "== Stand-in Drime remote (no hashes, like Drime)"
mkdir -p "$home" "$work/fake-drime"
# The password is `rclone obscure local-test-only`; it only protects test data.
cat >"$home/rclone.conf" <<EOF
[drime]
type = crypt
remote = $work/fake-drime
password = bNJd9Uz3_EG-OVallNR8pOX7YtmcOnpVC0-Dxo-NqA
filename_encryption = off
directory_name_encryption = false
EOF
chmod 600 "$home/rclone.conf"

echo "== install.sh"
if [ -n "$RCLONE_BIN" ]; then
	sh "$REPO/bridge/install.sh" --home "$home" --rclone-binary "$RCLONE_BIN"
else
	sh "$REPO/bridge/install.sh" --home "$home"
fi

# shellcheck source=../bridge/bridge.conf.example
. "$home/bridge.conf"
PORT=${LISTEN_ADDR##*:}

echo
echo "== S3 protocol checks"
"$PYTHON" -I "$REPO/tests/s3_protocol_test.py" "https://127.0.0.1:$PORT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" "$home/tls/cert.pem"

echo
echo "== selftest.sh"
"$home/selftest.sh" 64

echo
echo "== Supervisor restarts rclone after a crash"
child=$(cat "$home/run/rclone.pid")
kill -9 "$child"
i=0
until [ -f "$home/run/rclone.pid" ] && [ "$(cat "$home/run/rclone.pid")" != "$child" ] &&
	"$home/drime-bridge.sh" health >/dev/null 2>&1; do
	i=$((i + 1))
	[ $i -lt 30 ] || {
		echo "  FAIL  bridge did not come back"
		exit 1
	}
	sleep 1
done
echo "  PASS  back up after ${i}s"

echo
echo "== Re-running install.sh keeps keys and certificate"
before=$(cat "$home/bridge.conf" "$home/tls/cert.pem" | cksum)
if [ -n "$RCLONE_BIN" ]; then
	sh "$REPO/bridge/install.sh" --home "$home" --rclone-binary "$RCLONE_BIN" >/dev/null
else
	sh "$REPO/bridge/install.sh" --home "$home" >/dev/null
fi
after=$(cat "$home/bridge.conf" "$home/tls/cert.pem" | cksum)
if [ "$before" != "$after" ]; then
	echo "  FAIL  install.sh changed existing keys or certificate"
	exit 1
fi
echo "  PASS  unchanged"

echo
echo "== stop / status"
"$home/drime-bridge.sh" stop
if "$home/drime-bridge.sh" status >/dev/null; then
	echo "  FAIL  still running after stop"
	exit 1
fi
echo "  PASS  stopped cleanly"

echo
echo "All local tests passed."
