#!/bin/bash

# Emby ARM64 Roku Live TV Fix
# https://github.com/shiz504/emby-roku-as-fix
#
# Fixes two issues with Emby on ARM64 (Apple Silicon) that break Roku Live TV:
#
# 1. LD_LIBRARY_PATH poisoning: Emby's inherited loader environment breaks
#    its own bundled ffmpeg/ffprobe at launch time.
#
# 2. Fragile copy-codec live streams: Emby's Roku HLS path selects
#    "-c:v:0 copy / -c:a:0 copy" for live directstream jobs, which often
#    stall or buffer indefinitely on ARM64.
#
# Solution: Install clean-environment wrapper scripts that:
#   - Launch Emby's bundled ffmpeg/ffprobe through the correct ARM64 loader
#     with a sanitized LD_LIBRARY_PATH
#   - Selectively rewrite live copy-codec jobs to libx264/aac with
#     low-latency tuning for fast Roku startup

set -eu

ARCH="$(uname -m)"
REAL_FFMPEG="/usr/local/bin/emby-ffmpeg-real"
REAL_FFPROBE="/usr/local/bin/emby-ffprobe-real"
EMBY_BIN="/app/emby/bin"

# Only run on ARM64 — x86_64 does not have this issue
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
    echo "[fix-ffmpeg] Skipping on ${ARCH} — this fix is ARM64 only"
    exit 0
fi

# Check if a file is an ELF binary by reading the magic bytes.
# We avoid using the 'file' command since it may not be installed in the container.
is_elf() {
    [ -f "$1" ] && head -c 4 "$1" 2>/dev/null | od -A n -t x1 | grep -q "7f 45 4c 46"
}

# Back up the original bundled binaries before replacing them with wrappers.
# These are Emby's own binaries — we copy them aside so the wrappers can
# invoke them through a clean loader environment.
if [ ! -f "${REAL_FFMPEG}" ]; then
    if is_elf "${EMBY_BIN}/ffmpeg"; then
        echo "[fix-ffmpeg] Backing up bundled ffmpeg binary"
        cp -f "${EMBY_BIN}/ffmpeg" "${REAL_FFMPEG}"
    else
        echo "[fix-ffmpeg] ERROR: No ELF ffmpeg binary found at ${EMBY_BIN}/ffmpeg"
        echo "[fix-ffmpeg] The container may have already been patched or the image has changed."
        exit 1
    fi
fi

if [ ! -f "${REAL_FFPROBE}" ]; then
    if is_elf "${EMBY_BIN}/ffprobe"; then
        echo "[fix-ffmpeg] Backing up bundled ffprobe binary"
        cp -f "${EMBY_BIN}/ffprobe" "${REAL_FFPROBE}"
    else
        echo "[fix-ffmpeg] ERROR: No ELF ffprobe binary found at ${EMBY_BIN}/ffprobe"
        exit 1
    fi
fi

chmod 755 "${REAL_FFMPEG}" "${REAL_FFPROBE}"

# Install the ffmpeg wrapper.
# This wrapper does two things:
#   1. Launches ffmpeg through the ARM64 dynamic loader with a clean
#      LD_LIBRARY_PATH so Emby's bundled libs are found correctly.
#   2. Intercepts live directstream jobs that use "-c:v:0 copy / -c:a:0 copy"
#      and rewrites them to libx264/aac with low-latency settings.
#      This is the key fix for Roku Live TV — without it, copy-codec HLS
#      jobs stall or produce empty segments on ARM64.
cat > "${EMBY_BIN}/ffmpeg" <<'WRAPPER'
#!/usr/bin/env -S -i /bin/bash
APP_DIR=/app/emby
APP_LD="/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"
export AMDGPU_IDS=$APP_DIR/share/libdrm/amdgpu.ids
export FONTCONFIG_PATH=$APP_DIR/etc/fonts
export LD_LIBRARY_PATH=$APP_DIR/lib:$APP_DIR/extra/lib
export LIBVA_DRIVERS_PATH=$APP_DIR/extra/lib/dri
export OCL_ICD_VENDORS=$APP_DIR/extra/etc/OpenCL/vendors
export PCI_IDS_PATH=$APP_DIR/share/hwdata/pci.ids
export SSL_CERT_FILE=$APP_DIR/etc/ssl/certs/ca-certificates.crt
export NEOReadDebugKeys=1
export OverrideGpuAddressSpace=48

new_args=()
rewrite_video_copy=0
while (($#)); do
  case "$1" in
    -c:v:0)
      if (($# >= 2)) && [[ "$2" == "copy" ]]; then
        rewrite_video_copy=1
        new_args+=(
          "-c:v:0" "libx264"
          "-preset:v:0" "superfast"
          "-tune:v:0" "zerolatency"
          "-profile:v:0" "main"
          "-pix_fmt:v:0" "yuv420p"
          "-g:v:0" "60"
          "-bf:v:0" "0"
          "-sc_threshold:v:0" "0"
          "-crf:v:0" "23"
        )
        shift 2
        continue
      fi
      new_args+=("$1")
      shift
      if (($#)); then
        new_args+=("$1")
        shift
      fi
      continue
      ;;
    -c:a:0)
      if (($# >= 2)) && [[ "$2" == "copy" && "$rewrite_video_copy" -eq 1 ]]; then
        new_args+=(
          "-c:a:0" "aac"
          "-ab:a:0" "128000"
          "-ac:a:0" "2"
        )
        shift 2
        continue
      fi
      new_args+=("$1")
      shift
      if (($#)); then
        new_args+=("$1")
        shift
      fi
      continue
      ;;
    -copypriorss:a:0)
      shift
      if (($#)); then
        shift
      fi
      continue
      ;;
    *)
      new_args+=("$1")
      shift
      ;;
  esac
done

exec "$APP_LD" --library-path "$LD_LIBRARY_PATH" /usr/local/bin/emby-ffmpeg-real "${new_args[@]}"
WRAPPER
chmod 755 "${EMBY_BIN}/ffmpeg"

# Install the ffprobe wrapper.
# This is a clean-environment launcher only — no argument rewriting needed.
cat > "${EMBY_BIN}/ffprobe" <<'WRAPPER'
#!/usr/bin/env -S -i /bin/sh
APP_DIR=/app/emby
APP_LD="/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"
export AMDGPU_IDS=$APP_DIR/share/libdrm/amdgpu.ids
export FONTCONFIG_PATH=$APP_DIR/etc/fonts
export LD_LIBRARY_PATH=$APP_DIR/lib:$APP_DIR/extra/lib
export LIBVA_DRIVERS_PATH=$APP_DIR/extra/lib/dri
export OCL_ICD_VENDORS=$APP_DIR/extra/etc/OpenCL/vendors
export PCI_IDS_PATH=$APP_DIR/share/hwdata/pci.ids
export SSL_CERT_FILE=$APP_DIR/etc/ssl/certs/ca-certificates.crt
export NEOReadDebugKeys=1
export OverrideGpuAddressSpace=48
exec "$APP_LD" --library-path "$LD_LIBRARY_PATH" /usr/local/bin/emby-ffprobe-real "$@"
WRAPPER
chmod 755 "${EMBY_BIN}/ffprobe"

echo "[fix-ffmpeg] Installed ARM64 stable ffmpeg/ffprobe wrappers"
