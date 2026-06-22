# emby-roku-as-fix

Fix Roku Live TV playback on Emby running in the LinuxServer ARM64 Docker image.

This repository provides a startup patch for `lscr.io/linuxserver/emby` on ARM64
hosts where Emby's Live TV ffmpeg probes or Roku HLS playback fail because of
loader environment issues and fragile copy-codec live streams.

## What It Fixes

On recent LinuxServer ARM64 Emby images, Emby can launch ffmpeg-related child
processes with `LD_LIBRARY_PATH` pointing at Emby's bundled libraries. That can
make shell-based wrappers fail before they can sanitize the environment.

Common symptoms:

- `hardware_detection-*.txt` reports `IsEmbyCustom: false`
- ffmpeg probe commands exit with code `1` or `127`
- Emby logs include loader or glibc errors when probing ffmpeg
- Roku Live TV stalls, buffers, or fails to start
- Live TV transcode jobs report missing H.264 encoder support

The patch also rewrites Roku Live TV jobs that request fragile directstream HLS
copy mode:

- from `-c:v:0 copy` and `-c:a:0 copy`
- to low-latency `libx264` and `aac`

## How It Works

The LinuxServer image runs scripts mounted at `/custom-cont-init.d` during
container startup. This repo uses that hook to:

1. Back up Emby's bundled `ffmpeg`, `ffprobe`, and `ffdetect` binaries.
2. Install a static ARM64 launcher over all ffmpeg entrypoints:
   `ffmpeg`, `ffprobe`, `ffdetect`, `emby-ffmpeg`, `emby-ffprobe`, and
   `emby-ffdetect`.
3. Have the launcher sanitize the environment and execute the real Emby binaries
   through the ARM64 dynamic loader with a controlled library path.
4. Preserve the Roku HLS rewrite for live copy-codec jobs.

The static launcher avoids shell shebangs entirely, so it still starts when
Emby passes a polluted loader environment to child processes.

## Repository Layout

- `custom-cont-init.d/fix-ffmpeg.sh` - startup hook installed in the container
- `patch-assets/emby-cleanexec` - prebuilt static ARM64 launcher
- `src/emby-cleanexec.c` - launcher source
- `docker-compose.example.yml` - generic compose example
- `docs/VALIDATION.md` - validation commands

## Installation

Clone the repo:

```bash
git clone <repo-url>
cd emby-roku-as-fix
```

Create patch directories next to your Emby compose file and copy the files:

```bash
mkdir -p ./custom-cont-init.d ./patch-assets
cp custom-cont-init.d/fix-ffmpeg.sh ./custom-cont-init.d/
cp patch-assets/emby-cleanexec ./patch-assets/
chmod +x ./custom-cont-init.d/fix-ffmpeg.sh ./patch-assets/emby-cleanexec
```

Mount both directories into the Emby container:

```yaml
services:
  emby:
    image: lscr.io/linuxserver/emby:latest
    volumes:
      - ./config:/config
      - ./transcode:/transcode
      - ./custom-cont-init.d:/custom-cont-init.d:ro
      - ./patch-assets:/patch-assets:ro
```

Recreate the container so the init hook runs against the current image:

```bash
docker compose up -d --force-recreate emby
```

Check the container logs:

```bash
docker logs emby 2>&1 | grep fix-ffmpeg
```

Expected output includes:

```text
[fix-ffmpeg] Installed ARM64 static ffmpeg/ffprobe/ffdetect launcher
```

## Validation

After the container starts, confirm Emby sees its bundled ffmpeg as custom:

```bash
latest=$(docker exec emby sh -lc 'ls -t /config/logs/hardware_detection-*.txt | head -1')
docker exec emby sh -lc "grep -E 'ApplicationVersion|IsEmbyCustom|FullVersionInfo' '$latest'"
```

Expected:

- `IsEmbyCustom` is `true`
- `FullVersionInfo` starts with Emby's bundled ffmpeg version
- recent ffmpeg probe commands exit with code `0`

Confirm the launcher is static:

```bash
docker exec emby sh -lc 'ldd /app/emby/bin/ffmpeg 2>&1 || true'
```

Expected:

```text
not a dynamic executable
```

See [docs/VALIDATION.md](docs/VALIDATION.md) for a fuller checklist.

## Building The Launcher

The checked-in launcher is a statically linked ARM64 Linux binary. To rebuild it
inside an ARM64 Linux environment:

```bash
gcc -O2 -static -o patch-assets/emby-cleanexec src/emby-cleanexec.c
chmod +x patch-assets/emby-cleanexec
```

## Compatibility

This patch is intended for:

- `lscr.io/linuxserver/emby`
- ARM64 Linux containers
- Docker deployments where LinuxServer's custom init hook is available
- Roku Live TV playback paths that use Emby HLS transcoding

The script skips itself on non-ARM64 systems.

## What This Does Not Do

- It does not patch Emby DLLs.
- It does not modify user data, libraries, tuners, guide data, or metadata.
- It does not contact Live TV providers.
- It does not install packages inside the running Emby container.
- It does not require a custom Emby image.

## Troubleshooting

| Symptom | Likely Cause | Check |
| --- | --- | --- |
| `Static launcher asset missing` | `patch-assets` is not mounted | Confirm `./patch-assets:/patch-assets:ro` |
| `No ELF ffmpeg binary found` | The container was already patched before backup | Recreate the container from a fresh image |
| `IsEmbyCustom: false` | Launcher did not install or Emby used stale detection | Check `docker logs emby` and recreate |
| ffmpeg exits `127` | Launcher or loader path is wrong for the image | Run the validation checklist |
| Roku still buffers | Source stream/client/network issue may be separate | Validate ffmpeg detection first |

## Reporting Issues

Open an issue with:

- Emby version
- LinuxServer image tag or digest
- CPU architecture from `docker exec emby uname -m`
- relevant `docker logs emby` lines containing `fix-ffmpeg`
- the latest `hardware_detection-*.txt` ffmpeg capability summary

Do not include credentials, provider URLs, tokens, or private server details.
