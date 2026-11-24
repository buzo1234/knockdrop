#!/bin/sh
# Builds dist/knockdrop-macos.zip (standalone universal build (Apple Silicon + Intel), no Python needed).
set -e
cd "$(dirname "$0")"
PY="${PY:-/usr/local/bin/python3.12}"
W="$(mktemp -d)"
"$PY" -m venv "$W/venv" && "$W/venv/bin/pip" install -q pyinstaller
"$W/venv/bin/pyinstaller" --onedir --name knockdrop --target-arch universal2 \
  --hidden-import macimu --hidden-import macimu._spu --hidden-import multiprocessing.shared_memory \
  --distpath "$W/dist" --workpath "$W/work" --specpath "$W" --noconfirm --log-level WARN knockdrop.py
P="$W/pkg/knockdrop-macos"
mkdir -p "$P" dist
cp -R "$W/dist/knockdrop" "$P/app"
cp packaging/install.sh packaging/README.txt "$P/"
rm -f dist/knockdrop-macos.zip
(cd "$W/pkg" && ditto -c -k --keepParent knockdrop-macos "$OLDPWD/dist/knockdrop-macos.zip")
rm -rf "$W"
echo "built dist/knockdrop-macos.zip"
