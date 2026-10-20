#!/bin/sh
# drime-bridge: a local S3 endpoint on the NAS that writes straight through to Drime.
#
# Hyper Backup talks S3 to this bridge on 127.0.0.1; the bridge is rclone's
# `serve s3` on top of rclone's native Drime backend. Nothing is staged on the
# NAS: an upload is only acknowledged once Drime has accepted it.
#
# Usage: drime-bridge.sh {start|stop|restart|status|health|logs|cleanup|version}

set -u

BRIDGE_HOME=$(cd "$(dirname "$0")" && pwd)
RCLONE="$BRIDGE_HOME/bin/rclone"
RCLONE_CONF="$BRIDGE_HOME/rclone.conf"
TLS_DIR="$BRIDGE_HOME/tls"
LOG_DIR="$BRIDGE_HOME/logs"
RUN_DIR="$BRIDGE_HOME/run"
PIDFILE="$RUN_DIR/supervisor.pid"
CHILD_PIDFILE="$RUN_DIR/rclone.pid"

# Defaults; bridge.conf overrides them.
DRIME_ROOT="drime:HyperBackup"
LISTEN_ADDR="127.0.0.1:18443"
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
MEMORY_LIMIT="256MiB"
MULTIPART_BUFFER_PER_UPLOAD="128M"
MULTIPART_BUFFER_TOTAL="256M"
LOG_LEVEL="NOTICE"
BWLIMIT=""
EXTRA_FLAGS=""

if [ -f "$BRIDGE_HOME/bridge.conf" ]; then
	# shellcheck source=bridge.conf.example
	. "$BRIDGE_HOME/bridge.conf"
fi

LISTEN_PORT=${LISTEN_ADDR##*:}
LISTEN_HOST=${LISTEN_ADDR%:*}
case "$LISTEN_HOST" in "" | 0.0.0.0 | "[::]") LISTEN_HOST=127.0.0.1 ;; esac
ENDPOINT="https://$LISTEN_HOST:$LISTEN_PORT"

say() { printf '%s\n' "$*"; }
die() {
	printf 'drime-bridge: %s\n' "$*" >&2
	exit 1
}
stamp() { date '+%Y/%m/%d %H:%M:%S'; }

preflight() {
	[ -x "$RCLONE" ] || die "rclone not found at $RCLONE - run install.sh first"
	[ -f "$RCLONE_CONF" ] || die "missing $RCLONE_CONF - run install.sh first"
	[ -f "$TLS_DIR/cert.pem" ] && [ -f "$TLS_DIR/key.pem" ] || die "missing TLS files in $TLS_DIR - run install.sh first"
	[ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ] || die "S3_ACCESS_KEY/S3_SECRET_KEY not set in bridge.conf"
}

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

supervisor_pid() {
	[ -f "$PIDFILE" ] || return 1
	pid=$(cat "$PIDFILE" 2>/dev/null)
	pid_alive "$pid" && printf '%s' "$pid"
}

# The server answers anything, even an unsigned request, once it is listening.
port_open() {
	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 --cacert "$TLS_DIR/cert.pem" "$ENDPOINT/" 2>/dev/null)
	[ -n "$code" ] && [ "$code" != "000" ]
}

# Runs rclone in the foreground; secrets go through the environment, not argv.
serve() {
	export RCLONE_CONFIG="$RCLONE_CONF"
	export RCLONE_AUTH_KEY="\"$S3_ACCESS_KEY,$S3_SECRET_KEY\""
	export GOMEMLIMIT="$MEMORY_LIMIT"
	# --vfs-cache-mode off is what makes this safe: a PUT is only answered
	# after Drime has the data, so Hyper Backup never "succeeds" early.
	# shellcheck disable=SC2086 # EXTRA_FLAGS is split into flags on purpose
	exec "$RCLONE" serve s3 "$DRIME_ROOT" \
		--addr "$LISTEN_ADDR" \
		--cert "$TLS_DIR/cert.pem" --key "$TLS_DIR/key.pem" --min-tls-version tls1.2 \
		--vfs-cache-mode off \
		--multipart-streaming-buffer-limit "$MULTIPART_BUFFER_PER_UPLOAD" \
		--multipart-streaming-buffer-total "$MULTIPART_BUFFER_TOTAL" \
		--use-mmap \
		--cache-dir "$BRIDGE_HOME/cache" \
		--stats 0 \
		--log-level "$LOG_LEVEL" \
		--log-file "$LOG_DIR/bridge.log" \
		--log-file-max-size 10M --log-file-max-backups 5 --log-file-compress \
		${BWLIMIT:+--bwlimit "$BWLIMIT"} \
		$EXTRA_FLAGS
}

# Keeps rclone running: restarts it with backoff if it ever exits.
supervise() {
	echo $$ >"$PIDFILE"
	stopping=0
	child=""
	trap 'stopping=1; pid_alive "$child" && kill "$child"' TERM INT HUP
	delay=5
	while [ "$stopping" -eq 0 ]; do
		started=$(date +%s)
		serve &
		child=$!
		echo "$child" >"$CHILD_PIDFILE"
		say "$(stamp) started rclone (pid $child)"
		# wait returns early when a trapped signal arrives; keep waiting
		# until the child has really gone.
		wait "$child"
		rc=$?
		while pid_alive "$child"; do
			wait "$child"
			rc=$?
		done
		[ "$stopping" -eq 1 ] && break
		[ $(($(date +%s) - started)) -gt 300 ] && delay=5
		say "$(stamp) rclone exited with status $rc, restarting in ${delay}s"
		sleep "$delay" &
		wait $!
		delay=$((delay * 2))
		[ "$delay" -gt 300 ] && delay=300
	done
	rm -f "$CHILD_PIDFILE" "$PIDFILE"
	say "$(stamp) stopped"
}

start() {
	preflight
	if pid=$(supervisor_pid); then
		say "already running (pid $pid)"
		return 0
	fi
	mkdir -p "$LOG_DIR" "$RUN_DIR" "$BRIDGE_HOME/cache"
	# Detach from the caller (e.g. a Task Scheduler boot task) so the bridge
	# outlives it.
	detach=""
	command -v setsid >/dev/null 2>&1 && detach=setsid
	$detach nohup "$BRIDGE_HOME/drime-bridge.sh" _supervise >>"$LOG_DIR/supervisor.log" 2>&1 </dev/null &
	i=0
	while [ $i -lt 30 ]; do
		if port_open; then
			say "started: $ENDPOINT serving $DRIME_ROOT"
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	# rclone contacts Drime before it listens, so at boot this can just mean
	# the network isn't up yet; the supervisor keeps retrying either way.
	say "not listening after 30s (still retrying in the background); last log lines:" >&2
	tail -n 20 "$LOG_DIR/bridge.log" >&2 2>/dev/null
	return 1
}

stop() {
	if ! pid=$(supervisor_pid); then
		say "not running"
		rm -f "$PIDFILE" "$CHILD_PIDFILE"
		return 0
	fi
	kill "$pid"
	i=0
	while pid_alive "$pid" && [ $i -lt 30 ]; do
		sleep 1
		i=$((i + 1))
	done
	if pid_alive "$pid"; then
		child=$(cat "$CHILD_PIDFILE" 2>/dev/null)
		kill -9 "$pid" 2>/dev/null
		pid_alive "$child" && kill -9 "$child" 2>/dev/null
	fi
	rm -f "$PIDFILE" "$CHILD_PIDFILE"
	say "stopped"
}

status() {
	if pid=$(supervisor_pid); then
		child=$(cat "$CHILD_PIDFILE" 2>/dev/null)
		rss=""
		if [ -r "/proc/$child/status" ]; then
			rss=$(awk '/^VmRSS/ {printf ", %d MiB RSS", $2 / 1024}' "/proc/$child/status")
		fi
		say "running (supervisor pid $pid, rclone pid ${child:-?}$rss)"
		if port_open; then say "listening on $ENDPOINT"; else say "NOT listening on $ENDPOINT"; fi
		say "serving $DRIME_ROOT"
		return 0
	fi
	say "not running"
	return 3
}

# End-to-end check: S3 client -> bridge -> Drime API -> bucket list.
health() {
	notify=0
	[ "${1:-}" = "--notify" ] && notify=1
	preflight
	out=$(
		RCLONE_CONFIG="$RCLONE_CONF" \
			RCLONE_CONFIG_BRIDGE_TYPE=s3 \
			RCLONE_CONFIG_BRIDGE_PROVIDER=Rclone \
			RCLONE_CONFIG_BRIDGE_ENDPOINT="$ENDPOINT" \
			RCLONE_CONFIG_BRIDGE_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
			RCLONE_CONFIG_BRIDGE_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
			"$RCLONE" lsd bridge: --ca-cert "$TLS_DIR/cert.pem" \
			--contimeout 10s --timeout 60s --retries 2 --low-level-retries 2 2>&1
	)
	rc=$?
	if [ $rc -eq 0 ]; then
		say "healthy: $ENDPOINT -> $DRIME_ROOT"
		say "buckets:"
		printf '%s\n' "$out" | awk 'NF {print "  " $NF}'
		return 0
	fi
	say "UNHEALTHY: $ENDPOINT -> $DRIME_ROOT" >&2
	printf '%s\n' "$out" | tail -n 5 >&2
	if [ $notify -eq 1 ] && [ -x /usr/syno/bin/synodsmnotify ]; then
		/usr/syno/bin/synodsmnotify @administrators "Drime bridge" \
			"Health check failed - Hyper Backup to Drime will fail until this is fixed. See $LOG_DIR/bridge.log" || true
	fi
	return 1
}

# Removes leftovers of uploads interrupted by a crash or power loss.
cleanup() {
	preflight
	RCLONE_CONFIG="$RCLONE_CONF" "$RCLONE" delete "$DRIME_ROOT" \
		--include ".rclone_temp_*" --min-age 2d --log-level NOTICE
}

case "${1:-}" in
start) start ;;
stop) stop ;;
restart)
	stop
	start
	;;
status) status ;;
health)
	shift
	health "$@"
	;;
logs) tail -n "${2:-50}" "$LOG_DIR/bridge.log" ;;
cleanup) cleanup ;;
version) "$RCLONE" version ;;
_supervise) supervise ;;
*)
	say "usage: $0 {start|stop|restart|status|health [--notify]|logs [lines]|cleanup|version}"
	exit 2
	;;
esac
