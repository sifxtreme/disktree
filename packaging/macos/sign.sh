#!/bin/sh
# Sign both binaries with a real identity. TCC keys a Full Disk Access grant
# on the designated requirement; with a certificate that is "this identifier,
# this signer", which a rebuild keeps. Ad-hoc (the linker default) is a hash
# of the binary, so every build would silently lose the grant.
set -eu
identity=${DISK_SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}
[ -n "$identity" ] || { echo "no Apple Development identity; set DISK_SIGN_ID" >&2; exit 1; }
cd "$(dirname "$0")/../../target/release"
for bin in disk-snap disk-web; do
  codesign -f -s "$identity" -i "com.sevensevensix.$bin" -o runtime "$bin"
  codesign -v "$bin"
done
codesign -d -r- disk-snap 2>&1 | tail -1
