#!/bin/sh
# Installs or upgrades the Drime bridge on a Synology NAS. Safe to re-run:
# existing configuration, keys and certificates are kept.
#
#   sudo sh install.sh [--home DIR] [--folder NAME] [--bucket NAME] [--new-token]
#                      [--container] [--rclone-binary PATH]
#
# Run it from the folder you unpacked the release into. --container prepares
# the folder for Container Manager instead of starting the bridge directly.
# --rclone-binary uses an rclone you already downloaded and verified.

set -eu

RCLONE_VERSION="${RCLONE_VERSION:-1.75.2}"
BRIDGE_HOME="/volume1/drime-bridge"
DRIME_FOLDER="HyperBackup"
BUCKET="hyperbackup"
NEW_TOKEN=0
CONTAINER=0
RCLONE_BINARY=""

SRC_DIR=$(cd "$(dirname "$0")" && pwd)

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() {
	printf 'install: %s\n' "$*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--home)
		BRIDGE_HOME=$2
		shift 2
		;;
	--folder)
		DRIME_FOLDER=$2
		shift 2
		;;
	--bucket)
		BUCKET=$2
		shift 2
		;;
	--new-token)
		NEW_TOKEN=1
		shift
		;;
	--container)
		CONTAINER=1
		shift
		;;
	--rclone-binary)
		RCLONE_BINARY=$2
		shift 2
		;;
	-h | --help)
		sed -n '2,12p' "$0"
		exit 0
		;;
	*) die "unknown option: $1" ;;
	esac
done

printf '%s' "$BUCKET" | grep -Eq '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' ||
	die "bucket '$BUCKET' must be 3-63 chars of a-z, 0-9, '.' and '-' (Hyper Backup rule)"

RCLONE="$BRIDGE_HOME/bin/rclone"
RCLONE_CONF="$BRIDGE_HOME/rclone.conf"
DRIME_ROOT="drime:$DRIME_FOLDER"

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		openssl dgst -sha256 "$1" | awk '{print $NF}'
	fi
}

unzip_to() {
	if command -v unzip >/dev/null 2>&1; then
		unzip -q -o "$1" -d "$2"
	elif command -v 7z >/dev/null 2>&1; then
		7z x -y -o"$2" "$1" >/dev/null
	elif command -v python3 >/dev/null 2>&1; then
		python3 -I -m zipfile -e "$1" "$2"
	else
		die "need unzip, 7z or python3 to unpack rclone"
	fi
}

platform() {
	case "$(uname -s)" in
	Linux) os=linux ;;
	Darwin) os=osx ;;
	*) die "unsupported OS $(uname -s)" ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	armv7l | armv7) arch=arm-v7 ;;
	armv6l) arch=arm-v6 ;;
	i686 | i386) arch=386 ;;
	*) die "unsupported CPU $(uname -m)" ;;
	esac
	printf '%s-%s' "$os" "$arch"
}

install_rclone() {
	if [ -n "$RCLONE_BINARY" ]; then
		mkdir -p "$BRIDGE_HOME/bin"
		cp "$RCLONE_BINARY" "$RCLONE.new"
		chmod 755 "$RCLONE.new"
		mv -f "$RCLONE.new" "$RCLONE"
		"$RCLONE" version | head -n 1
		return
	fi
	if [ -x "$RCLONE" ] && "$RCLONE" version 2>/dev/null | head -n 1 | grep -q "v$RCLONE_VERSION\$"; then
		say "rclone v$RCLONE_VERSION already installed"
		return
	fi
	plat=$(platform)
	name="rclone-v$RCLONE_VERSION-$plat"
	base="https://downloads.rclone.org/v$RCLONE_VERSION"
	# Not /tmp: DSM's system partition is small.
	tmp=$(mktemp -d "$BRIDGE_HOME/.download.XXXXXX")
	trap 'rm -rf "$tmp"' EXIT
	say "downloading $name.zip"
	curl -fsSL -o "$tmp/$name.zip" "$base/$name.zip"
	curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
	want=$(awk -v f="$name.zip" '$2 == f {print $1}' "$tmp/SHA256SUMS")
	got=$(sha256_of "$tmp/$name.zip")
	[ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch for $name.zip (want $want, got $got)"
	say "checksum ok ($got)"
	unzip_to "$tmp/$name.zip" "$tmp"
	mkdir -p "$BRIDGE_HOME/bin"
	cp "$tmp/$name/rclone" "$RCLONE.new"
	chmod 755 "$RCLONE.new"
	mv -f "$RCLONE.new" "$RCLONE"
	rm -rf "$tmp"
	trap - EXIT
	"$RCLONE" version | head -n 1
}

configure_drime() {
	if [ -f "$RCLONE_CONF" ] && grep -q '^\[drime\]' "$RCLONE_CONF" && [ "$NEW_TOKEN" -eq 0 ]; then
		say "Drime remote already configured (use --new-token to replace the token)"
	else
		token=${DRIME_TOKEN:-}
		if [ -z "$token" ]; then
			say "Create a token in Drime: Settings > Developer > create token."
			printf 'Paste the Drime API token (input is hidden): '
			stty -echo 2>/dev/null || true
			read -r token
			stty echo 2>/dev/null || true
			printf '\n'
		fi
		[ -n "$token" ] || die "no token given"
		# Deletes skip the Drime trash; otherwise every pruned backup version
		# would keep using quota there.
		(
			umask 077
			cat >"$RCLONE_CONF" <<EOF
[drime]
type = drime
access_token = $token
hard_delete = true
EOF
		)
		unset token
	fi
	chmod 600 "$RCLONE_CONF"
	say "checking the token against the Drime API"
	RCLONE_CONFIG="$RCLONE_CONF" "$RCLONE" lsd drime: --retries 2 >/dev/null ||
		die "Drime rejected the token or is unreachable - re-run with --new-token"
	RCLONE_CONFIG="$RCLONE_CONF" "$RCLONE" mkdir "$DRIME_ROOT/$BUCKET"
	say "Drime folder ready: $DRIME_FOLDER/$BUCKET (bucket '$BUCKET')"
}

make_tls() {
	if [ -f "$BRIDGE_HOME/tls/cert.pem" ] && [ -f "$BRIDGE_HOME/tls/key.pem" ]; then
		say "keeping existing certificate"
		return
	fi
	mkdir -p "$BRIDGE_HOME/tls"
	san="DNS:localhost,IP:127.0.0.1"
	host=$(hostname 2>/dev/null || true)
	[ -n "$host" ] && san="$san,DNS:$host"
	(
		umask 077
		openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
			-subj "/CN=drime-bridge" -addext "subjectAltName=$san" \
			-keyout "$BRIDGE_HOME/tls/key.pem" -out "$BRIDGE_HOME/tls/cert.pem" 2>/dev/null
	)
	say "created a 10-year self-signed certificate ($san)"
}

write_conf() {
	if [ -f "$BRIDGE_HOME/bridge.conf" ]; then
		say "keeping existing bridge.conf"
		return
	fi
	ak="DB$(openssl rand -hex 9 | tr 'a-f' 'A-F')"
	sk=$(openssl rand -base64 60 | tr -dc 'A-Za-z0-9' | cut -c1-40)
	(
		umask 077
		awk -v root="$DRIME_ROOT" -v ak="$ak" -v sk="$sk" '
			/^DRIME_ROOT=/ { print "DRIME_ROOT=\"" root "\""; next }
			/^S3_ACCESS_KEY=/ { print "S3_ACCESS_KEY=\"" ak "\""; next }
			/^S3_SECRET_KEY=/ { print "S3_SECRET_KEY=\"" sk "\""; next }
			{ print }
		' "$SRC_DIR/bridge.conf.example" >"$BRIDGE_HOME/bridge.conf"
	)
	say "generated S3 keys for Hyper Backup in bridge.conf"
}

step "Installing into $BRIDGE_HOME"
mkdir -p "$BRIDGE_HOME"
chmod 700 "$BRIDGE_HOME"
for f in drime-bridge.sh selftest.sh bridge.conf.example compose.yaml; do
	cp "$SRC_DIR/$f" "$BRIDGE_HOME/$f"
done
chmod 700 "$BRIDGE_HOME/drime-bridge.sh" "$BRIDGE_HOME/selftest.sh"

step "rclone v$RCLONE_VERSION"
install_rclone

step "Drime"
configure_drime

step "TLS and S3 keys"
make_tls
write_conf

# shellcheck source=bridge.conf.example
. "$BRIDGE_HOME/bridge.conf"

if [ "$CONTAINER" -eq 1 ]; then
	"$BRIDGE_HOME/drime-bridge.sh" stop >/dev/null
	start_step="Container Manager > Project > Create
     Path: $BRIDGE_HOME    Source: use the existing compose.yaml
   Then check it with: $BRIDGE_HOME/drime-bridge.sh health"
else
	step "Starting the bridge"
	"$BRIDGE_HOME/drime-bridge.sh" stop >/dev/null
	"$BRIDGE_HOME/drime-bridge.sh" start
	"$BRIDGE_HOME/drime-bridge.sh" health
	start_step="Control Panel > Task Scheduler > Create > Triggered Task > User-defined script
     User: root    Event: Boot-up
     Command: $BRIDGE_HOME/drime-bridge.sh start"
fi

cat <<EOF

Done. Two things left to do in DSM:

1. $start_step

2. Hyper Backup > + > Data backup task > S3 Storage
     S3 Server:          Custom Server URL
     Server address:     ${LISTEN_ADDR}
     Signature version:  v4
     Request style:      Path style
     Access key:         $S3_ACCESS_KEY
     Secret key:         (S3_SECRET_KEY in $BRIDGE_HOME/bridge.conf)
     Bucket name:        $BUCKET

Optional end-to-end test with real uploads: $BRIDGE_HOME/selftest.sh
EOF
