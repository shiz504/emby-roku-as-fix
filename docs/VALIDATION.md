# Validation Guide

Use this checklist after applying the ARM64 Roku patch to a LinuxServer Emby
container.

## 1. Confirm Init Hook Ran

```bash
docker logs emby 2>&1 | grep fix-ffmpeg
```

Expected:

```text
[fix-ffmpeg] Installed ARM64 static ffmpeg/ffprobe/ffdetect launcher
```

If you see `Static launcher asset missing`, the `patch-assets` directory is not
mounted at `/patch-assets`.

## 2. Confirm Static Launchers Are Installed

```bash
docker exec emby sh -lc '
ls -l /app/emby/bin/ffmpeg \
      /app/emby/bin/ffprobe \
      /app/emby/bin/ffdetect \
      /app/emby/bin/emby-ffmpeg \
      /app/emby/bin/emby-ffprobe \
      /app/emby/bin/emby-ffdetect
'
```

All six files should be executable and the same approximate size as
`/usr/local/bin/emby-cleanexec`.

```bash
docker exec emby sh -lc 'ldd /app/emby/bin/ffmpeg 2>&1 || true'
```

Expected:

```text
not a dynamic executable
```

## 3. Confirm Real Emby Binaries Were Preserved

```bash
docker exec emby sh -lc '
ls -l /usr/local/bin/emby-ffmpeg-real \
      /usr/local/bin/emby-ffprobe-real \
      /usr/local/bin/emby-ffdetect-real
'
```

Expected: three executable files.

## 4. Confirm Probes Survive A Polluted Loader Environment

This reproduces the failure mode that affects newer LinuxServer ARM64 images.

```bash
docker exec emby sh -lc '
LD_LIBRARY_PATH=/app/emby/lib:/app/emby/extra/lib \
  /app/emby/bin/ffmpeg -hide_banner -version | head -5
'
```

Expected: Emby's ffmpeg version output, not a glibc or loader error.

```bash
docker exec emby sh -lc '
LD_LIBRARY_PATH=/app/emby/lib:/app/emby/extra/lib \
  /app/emby/bin/ffdetect -hide_banner -show_program_version | head -10
'
```

Expected: Emby's ffdetect program-version output.

## 5. Confirm Hardware Detection

```bash
docker exec emby sh -lc '
latest=$(ls -t /config/logs/hardware_detection-*.txt | head -1)
echo "$latest"
grep -E "ApplicationVersion|IsEmbyCustom|FullVersionInfo" "$latest"
'
```

Expected:

- `IsEmbyCustom` is `true`
- `FullVersionInfo` contains Emby's bundled ffmpeg version

Check recent server logs:

```bash
docker exec emby sh -lc '
latest=$(ls -t /config/logs/embyserver*.txt | head -1)
grep -E "ffmpeg -hide_banner -(version|decoders|encoders|hwaccels|protocols|filters)" "$latest" | tail -20
'
```

Expected: probe commands exit with code `0`.

## 6. Check For Encoder Errors

```bash
docker exec emby sh -lc '
latest=$(ls -t /config/logs/embyserver*.txt | head -1)
grep -Ei "No video encoder|GLIBC|relocation|Process exited with code (1|127)" "$latest" | tail -20 || true
'
```

Expected: no fresh errors after the patch is installed.

## 7. Optional Live TV HLS Test

Use your own Emby admin credentials and a channel from your own Live TV setup.
Do not include private provider URLs or credentials in issue reports.

Authenticate:

```bash
TOKEN=$(curl -s -X POST "http://localhost:8096/Users/AuthenticateByName" \
  -H "Content-Type: application/json" \
  -H 'X-Emby-Authorization: MediaBrowser Client="CLI", Device="validation", DeviceId="validation", Version="1.0"' \
  -d '{"Username":"YOUR_USERNAME","Pw":"YOUR_PASSWORD"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['AccessToken'])")
```

List a few channels:

```bash
curl -s "http://localhost:8096/LiveTv/Channels?Limit=5" \
  -H "X-Emby-Token: ${TOKEN}" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
for ch in d.get("Items", []):
    print(ch["Id"], ch["Name"])
'
```

Request HLS playback info for one channel:

```bash
CHANNEL_ID="REPLACE_WITH_CHANNEL_ID"

curl -s -X POST "http://localhost:8096/Items/${CHANNEL_ID}/PlaybackInfo" \
  -H "Content-Type: application/json" \
  -H "X-Emby-Token: ${TOKEN}" \
  -d '{"DeviceProfile":{"MaxStreamingBitrate":8000000,"TranscodingProfiles":[{"Container":"ts","Type":"Video","VideoCodec":"h264","AudioCodec":"aac","Protocol":"hls"}]}}'
```

Expected: a transcoding URL for HLS playback. A real Roku client remains the
best end-to-end validation for the startup-time improvement.
