#!/bin/sh
# Installs knockdrop to /usr/local/lib/knockdrop with a `knockdrop` command in /usr/local/bin.
set -e
PREFIX="${PREFIX:-/usr/local}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUDO=""
mkdir -p "$PREFIX/lib" "$PREFIX/bin" 2>/dev/null || true
{ [ -w "$PREFIX/lib" ] && [ -w "$PREFIX/bin" ]; } || [ "$(id -u)" = 0 ] || SUDO="sudo"
echo "installing knockdrop to $PREFIX/lib/knockdrop ..."
[ -n "$SUDO" ] && echo "(needs your password once to write to $PREFIX)"
$SUDO mkdir -p "$PREFIX/lib" "$PREFIX/bin"
$SUDO rm -rf "$PREFIX/lib/knockdrop"
$SUDO cp -R "$HERE/app" "$PREFIX/lib/knockdrop"
# downloaded/AirDropped files are quarantined; this unsigned build would otherwise be blocked
$SUDO xattr -dr com.apple.quarantine "$PREFIX/lib/knockdrop" 2>/dev/null || true
printf '#!/bin/sh\nexec "%s/lib/knockdrop/knockdrop" "$@"\n' "$PREFIX" | $SUDO tee "$PREFIX/bin/knockdrop" >/dev/null
$SUDO chmod +x "$PREFIX/bin/knockdrop"
echo "done. try:  knockdrop check"
