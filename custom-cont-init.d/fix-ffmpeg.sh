#!/bin/bash

# Emby ARM64 Roku Live TV Fix
# Installs the static ARM64 launcher used by this repository.
#
# Manual 4.9.5+ adaptation:
# linuxserver/emby 4.9.5 launches ffmpeg probes with LD_LIBRARY_PATH pointing at
# /app/emby/lib. That makes shell shebang wrappers fail before they can sanitize
# the environment because /usr/bin/env or /bin/sh loads Emby's stale libc.so.6.
# Install a static ARM64 launcher instead. The launcher sanitizes env, execs the
# real Emby binaries, and preserves the Roku live copy-codec rewrite.

set -eu

ARCH="$(uname -m)"
EMBY_BIN="/app/emby/bin"
ASSET="/patch-assets/emby-cleanexec"
LAUNCHER="/usr/local/bin/emby-cleanexec"
REAL_FFMPEG="/usr/local/bin/emby-ffmpeg-real"
REAL_FFPROBE="/usr/local/bin/emby-ffprobe-real"
REAL_FFDETECT="/usr/local/bin/emby-ffdetect-real"

if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
    echo "[fix-ffmpeg] Skipping on ${ARCH} -- this fix is ARM64 only"
    exit 0
fi

is_elf() {
    [ -f "$1" ] && head -c 4 "$1" 2>/dev/null | od -A n -t x1 | grep -q "7f 45 4c 46"
}

backup_binary() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [ ! -f "$dst" ]; then
        if is_elf "$src"; then
            echo "[fix-ffmpeg] Backing up bundled ${label} binary"
            cp -f "$src" "$dst"
            chmod 755 "$dst"
        else
            echo "[fix-ffmpeg] ERROR: No ELF ${label} binary found at ${src}"
            exit 1
        fi
    fi
}

if [ ! -f "$ASSET" ]; then
    echo "[fix-ffmpeg] ERROR: Static launcher asset missing: $ASSET"
    exit 1
fi

backup_binary "${EMBY_BIN}/ffmpeg" "$REAL_FFMPEG" "ffmpeg"
backup_binary "${EMBY_BIN}/ffprobe" "$REAL_FFPROBE" "ffprobe"
backup_binary "${EMBY_BIN}/ffdetect" "$REAL_FFDETECT" "ffdetect"

cp -f "$ASSET" "$LAUNCHER"
chmod 755 "$LAUNCHER" "$REAL_FFMPEG" "$REAL_FFPROBE" "$REAL_FFDETECT"

for name in ffmpeg ffprobe ffdetect emby-ffmpeg emby-ffprobe emby-ffdetect; do
    cp -f "$LAUNCHER" "${EMBY_BIN}/${name}"
    chmod 755 "${EMBY_BIN}/${name}"
done

echo "[fix-ffmpeg] Installed ARM64 static ffmpeg/ffprobe/ffdetect launcher"
