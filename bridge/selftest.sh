#!/bin/sh
# pass/fail always succeed, so "test && pass || fail" is safe here.
# shellcheck disable=SC2015
#
# End-to-end test of a running bridge, using rclone as the S3 client:
# single and multipart uploads through the bridge, byte-for-byte read-back,
# a check that the files really are in Drime, overwrite, delete, cleanup.
# Everything happens in a throwaway bucket that is removed at the end.
#
#   drime-bridge.sh start && selftest.sh [size of the large file in MiB, default 160]

set -u

BRIDGE_HOME=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bridge.conf.example
. "$BRIDGE_HOME/bridge.conf"
RCLONE="$BRIDGE_HOME/bin/rclone"
LARGE_MB=${1:-160}
BUCKET="drime-bridge-selftest"
PORT=${LISTEN_ADDR##*:}

export RCLONE_CONFIG="$BRIDGE_HOME/rclone.conf"
export RCLONE_CONFIG_BRIDGE_TYPE=s3
export RCLONE_CONFIG_BRIDGE_PROVIDER=Rclone
export RCLONE_CONFIG_BRIDGE_ENDPOINT="https://127.0.0.1:$PORT"
export RCLONE_CONFIG_BRIDGE_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export RCLONE_CONFIG_BRIDGE_SECRET_ACCESS_KEY="$S3_SECRET_KEY"

work=$(mktemp -d)
failures=0
trap 'rm -rf "$work"' EXIT

pass() { printf '  PASS  %s\n' "$*"; }
fail() {
	printf '  FAIL  %s\n' "$*"
	failures=$((failures + 1))
}
rc() { "$RCLONE" --retries 1 --low-level-retries 3 --log-level ERROR "$@"; }
# Through the bridge. The bridge's certificate is only trusted here: given to
# a direct Drime call it would replace the system CAs and break that call.
s3() { rc --ca-cert "$BRIDGE_HOME/tls/cert.pem" "$@"; }
# Straight to Drime, bypassing the bridge, to see what is really stored.
drime() { rc "$@"; }
mbps() { awk -v b="$1" -v s="$2" 'BEGIN { if (s < 1) s = 1; printf "%.1f MiB/s", b / 1048576 / s }'; }

echo "Preparing test files in $work"
mkdir -p "$work/up"
head -c 4096 /dev/urandom >"$work/up/small.bin"
head -c $((48 * 1048576)) /dev/urandom >"$work/up/medium.bin"
head -c $((LARGE_MB * 1048576)) /dev/urandom >"$work/up/large.bin"

echo "Testing $RCLONE_CONFIG_BRIDGE_ENDPOINT -> $DRIME_ROOT/$BUCKET"

s3 mkdir "bridge:$BUCKET" && pass "create bucket" || fail "create bucket"

t0=$(date +%s)
if s3 copy "$work/up" "bridge:$BUCKET/t" --include "{small,medium}.bin" --s3-upload-cutoff 64M; then
	pass "single-part uploads (4 KiB, 48 MiB) in $(mbps $((48 * 1048576)) $(($(date +%s) - t0)))"
else
	fail "single-part uploads"
fi

t0=$(date +%s)
if s3 copy "$work/up/large.bin" "bridge:$BUCKET/t" --s3-upload-cutoff 8M --s3-chunk-size 16M --s3-upload-concurrency 4; then
	pass "multipart upload (${LARGE_MB} MiB, 16 MiB parts, 4 in parallel) in $(mbps $((LARGE_MB * 1048576)) $(($(date +%s) - t0)))"
else
	fail "multipart upload"
fi

t0=$(date +%s)
if s3 check "$work/up" "bridge:$BUCKET/t" --download; then
	pass "byte-for-byte read-back through the bridge in $(mbps $(((LARGE_MB + 48) * 1048576)) $(($(date +%s) - t0)))"
else
	fail "read-back differs"
fi

# The bridge must not have staged anything: the files must be in Drime itself.
for f in small.bin medium.bin large.bin; do
	want=$(wc -c <"$work/up/$f" | tr -d ' ')
	got=$(drime lsf --format s "$DRIME_ROOT/$BUCKET/t/$f" 2>&1)
	[ "$got" = "$want" ] && pass "in Drime: $f ($got bytes)" || fail "in Drime: $f (want $want bytes, got '${got:-missing}')"
done

head -c $((48 * 1048576)) /dev/urandom >"$work/up/medium.bin"
if s3 copyto "$work/up/medium.bin" "bridge:$BUCKET/t/medium.bin" --s3-upload-cutoff 64M &&
	s3 check "$work/up" "bridge:$BUCKET/t" --download --include medium.bin; then
	pass "overwrite"
else
	fail "overwrite"
fi

# Listings straight from Drime; a failed listing must fail the check, not
# look like an empty folder.
if listing=$(drime lsf "$DRIME_ROOT/$BUCKET/t"); then
	dupes=$(printf '%s\n' "$listing" | grep -c '^medium')
	[ "$dupes" = 1 ] && pass "no duplicate left behind by the overwrite" || fail "found $dupes 'medium*' entries in Drime"
else
	fail "could not list $DRIME_ROOT/$BUCKET/t"
fi

if s3 deletefile "bridge:$BUCKET/t/small.bin" && listing=$(drime lsf "$DRIME_ROOT/$BUCKET/t"); then
	printf '%s\n' "$listing" | grep -q '^small.bin$' && fail "delete (small.bin still in Drime)" || pass "delete"
else
	fail "delete"
fi

if listing=$(drime lsf -R --files-only "$DRIME_ROOT/$BUCKET" --include ".rclone_temp_*"); then
	leftovers=$(printf '%s' "$listing" | grep -c .)
	[ "$leftovers" = 0 ] && pass "no temporary objects left" || fail "$leftovers temporary objects left"
else
	fail "could not list $DRIME_ROOT/$BUCKET"
fi

drime purge "$DRIME_ROOT/$BUCKET" && pass "cleanup" || fail "cleanup (remove $DRIME_ROOT/$BUCKET by hand)"

echo
if [ "$failures" -eq 0 ]; then
	echo "All checks passed."
else
	echo "$failures check(s) failed. Logs: $BRIDGE_HOME/logs/bridge.log"
	exit 1
fi
