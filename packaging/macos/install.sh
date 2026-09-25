#!/bin/sh
# Install Guilty Spark's two launchd agents (work name: disk) on this Mac.
#
#   install.sh local  [ID=URL,LABEL,TOKEN_FILE]...   # UI on 127.0.0.1:7321
#   install.sh remote BIND_ADDR                      # UI beyond loopback, token required
#
# com.asif.disk-snap  hourly snapshot into ~/Library/Application Support/disk/disk.db.
#                         The only process that needs Full Disk Access; no network, no delete.
# com.asif.disk-web   the UI and API. Reads the DB; never scans; holds no grant.
#
# DISK_LABEL names this machine in the sidebar (default: hostname -s).
# Binaries are expected signed (packaging/macos/sign.sh): an FDA grant is keyed
# on the signature, and an ad-hoc one changes on every build.
set -eu

kind=${1:?usage: install.sh local|remote ...}
shift
bindir="$HOME/.local/bin"
state="$HOME/Library/Application Support/disk"
agents="$HOME/Library/LaunchAgents"
here=$(cd "$(dirname "$0")" && pwd)
uid=$(id -u)

mkdir -p "$bindir" "$state" "$HOME/Library/Logs"
for bin in disk-web disk-snap; do
  if [ -f "$here/$bin" ]; then src="$here/$bin"; else src="$here/../../target/release/$bin"; fi
  install -m 0755 "$src" "$bindir/$bin"
done

# $1 label, $2 program-arguments xml, $3 extra keys
agent() {
  cat > "$agents/$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array>$2</array>
  $3
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/$1.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/$1.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$uid/$1" 2>/dev/null || true
  # bootout returns before a running job has exited; bootstrap fails (error 5) until it has.
  for try in 1 2 3 4 5 6 7 8 9 10; do
    launchctl bootstrap "gui/$uid" "$agents/$1.plist" 2>/dev/null && return 0
    sleep 1
  done
  launchctl bootstrap "gui/$uid" "$agents/$1.plist"
}

web="<string>$bindir/disk-web</string>"
if [ -n "${DISK_LABEL:-}" ]; then
  web="$web<string>--label</string><string>$DISK_LABEL</string>"
fi
case "$kind" in
  local)
    web="$web<string>--bind</string><string>127.0.0.1:7321</string>"
    for peer in "$@"; do
      web="$web<string>--peer</string><string>$peer</string>"
    done
    ;;
  remote)
    bind=${1:?remote needs BIND_ADDR, e.g. 100.x.y.z:7321}
    token="$state/token"
    if [ ! -s "$token" ]; then
      (umask 077 && openssl rand -hex 24 > "$token")
    fi
    web="$web<string>--bind</string><string>$bind</string><string>--token-file</string><string>$token</string>"
    ;;
  *) echo "unknown kind $kind" >&2; exit 2 ;;
esac

# Hourly, and once at load so a fresh install has something to show.
agent com.asif.disk-snap "<string>$bindir/disk-snap</string>" \
  "<key>StartInterval</key><integer>3600</integer><key>RunAtLoad</key><true/>"
# A Tailscale bind fails until tailscaled is up; KeepAlive retries.
agent com.asif.disk-web "$web" \
  "<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>30</integer>"

"$bindir/disk-snap" --probe | sed 's/^/snapper (from this shell) /'
echo "installed com.asif.disk-snap + com.asif.disk-web ($kind)"
echo "grant Full Disk Access to: $bindir/disk-snap"
