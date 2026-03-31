# Validation Guide

Step-by-step verification that the ARM64 Roku fix is working correctly.

## Prerequisites

- Emby container running with the fix applied
- A Live TV tuner configured with at least one active channel
- `curl` and `python3` available on the host

## Step 1: Confirm Wrapper Installation

```bash
docker exec emby head -3 /app/emby/bin/ffmpeg
```

**Expected:** A bash shebang, not an ELF binary header.

```
#!/usr/bin/env -S -i /bin/bash
APP_DIR=/app/emby
APP_LD="/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"
```

```bash
docker exec emby head -3 /app/emby/bin/ffprobe
```

**Expected:**

```
#!/usr/bin/env -S -i /bin/sh
APP_DIR=/app/emby
APP_LD="/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"
```

## Step 2: Confirm Real Binaries Exist

```bash
docker exec emby ls -la /usr/local/bin/emby-ffmpeg-real /usr/local/bin/emby-ffprobe-real
```

**Expected:** Two ELF binaries with executable permissions.

## Step 3: Check Hardware Detection

```bash
docker exec emby find /config/data -name "hardware_detection-*" -exec cat {} \; 2>/dev/null
```

**Look for:**

- `FfmpegCapabilities.IsEmbyCustom: true`
- `VideoEncoders` list is populated (not empty)

If `IsEmbyCustom` is `false` or `VideoEncoders` is empty, restart the container and check again.

## Step 4: Check for Encoder Errors

```bash
docker exec emby grep "No video encoder found" /config/logs/embyserver.txt 2>/dev/null | tail -5
```

**Expected:** No output, or only entries from before the fix was applied.

## Step 5: Authenticate via API

Replace the username and password with your Emby admin credentials.

```bash
TOKEN=$(curl -s -X POST "http://localhost:8096/Users/AuthenticateByName" \
  -H "Content-Type: application/json" \
  -H 'X-Emby-Authorization: MediaBrowser Client="CLI", Device="terminal", DeviceId="validate", Version="1.0"' \
  -d '{"Username":"YOUR_USERNAME","Pw":"YOUR_PASSWORD"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['AccessToken'])")

echo "Token: ${TOKEN}"
```

## Step 6: Get a Live TV Channel ID

```bash
curl -s "http://localhost:8096/LiveTv/Channels?Limit=5" \
  -H "X-Emby-Token: ${TOKEN}" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
for ch in d.get('Items', []):
    print(f'{ch[\"Id\"]}  {ch[\"Name\"]}')"
```

Pick a channel ID from the output.

## Step 7: Request PlaybackInfo

Replace `CHANNEL_ID` with a real channel ID from Step 6.

```bash
curl -s -X POST "http://localhost:8096/Items/CHANNEL_ID/PlaybackInfo" \
  -H "Content-Type: application/json" \
  -H "X-Emby-Token: ${TOKEN}" \
  -d '{"DeviceProfile":{"MaxStreamingBitrate":8000000,"TranscodingProfiles":[{"Container":"ts","Type":"Video","VideoCodec":"h264","AudioCodec":"aac","Protocol":"hls"}]}}' \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
for ms in d.get('MediaSources', []):
    print(f'MediaSourceId: {ms[\"Id\"]}')
    print(f'TranscodingUrl: {ms.get(\"TranscodingUrl\", \"none\")}')"
```

**Expected:** A `TranscodingUrl` containing `/Videos/` and `live.m3u8`.

## Step 8: Request HLS Playlist

Using the `TranscodingUrl` from Step 7:

```bash
curl -s "http://localhost:8096${TRANSCODING_URL}" \
  -H "X-Emby-Token: ${TOKEN}" | head -20
```

**Expected:** An HLS playlist with `#EXTINF` entries and `.ts` segment URLs:

```
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:3.370033,
hls/ABCDEF/ABCDEF_0.ts?PlaySessionId=...
```

If you see directory-style paths like `hls/ABCDEF/` without `.ts` extensions, the wrapper is not intercepting correctly.

## Step 9: Test Roku Playback

1. Open Emby on your Roku
2. Navigate to Live TV
3. Select a channel
4. Playback should start within 3-5 seconds

## Quick Health Check (All-in-One)

```bash
echo "=== Wrapper Check ==="
docker exec emby head -1 /app/emby/bin/ffmpeg

echo ""
echo "=== Real Binary Check ==="
docker exec emby ls /usr/local/bin/emby-ffmpeg-real /usr/local/bin/emby-ffprobe-real 2>/dev/null && echo "OK" || echo "MISSING"

echo ""
echo "=== Hardware Detection ==="
docker exec emby find /config/data -name "hardware_detection-*" \
  -exec grep -E "IsEmbyCustom|VideoEncoders" {} \; 2>/dev/null

echo ""
echo "=== Encoder Errors ==="
COUNT=$(docker exec emby grep -c "No video encoder found" /config/logs/embyserver.txt 2>/dev/null || echo "0")
echo "Count: ${COUNT}"
```
