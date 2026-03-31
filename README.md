# emby-roku-as-fix

**Fix Roku Live TV playback on Emby running ARM64 Docker (Apple Silicon)**

If you run [Emby](https://emby.media/) in Docker on an Apple Silicon Mac (M1/M2/M3/M4) using the [linuxserver/emby](https://docs.linuxserver.io/images/docker-emby/) image, Roku Live TV is broken out of the box. Streams stall, buffer forever, or never start. This repo is a drop-in fix.

---

## The Problem

Two things break when Emby runs on ARM64 via Docker Desktop on Apple Silicon:

### 1. LD_LIBRARY_PATH Poisoning

Emby injects its own `LD_LIBRARY_PATH` into child processes. On ARM64, this causes its bundled `ffmpeg` and `ffprobe` binaries to fail at launch — they pick up the wrong shared libraries and crash or hang silently.

**Symptoms:**
- `No video encoder found for 'h264'` in Emby logs
- Empty `VideoEncoders` in `hardware_detection-*.txt`
- Live TV shows a spinning buffer on Roku and never starts

### 2. Copy-Codec HLS Stalls

Even when ffmpeg starts, Emby's Roku Live TV path selects `-c:v:0 copy -c:a:0 copy` (direct stream) for HLS output. On ARM64, these copy-codec jobs produce empty or malformed `.ts` segments that Roku cannot play.

**Symptoms:**
- Emby logs show `ffmpeg-directstream` jobs starting but producing 0ms of output
- Roku shows "Unable to play media" or buffers indefinitely
- The Emby web client may work fine (it uses a different playback path)

## The Fix

This repo provides a single init script that runs automatically when the container starts. It:

1. **Backs up** Emby's bundled `ffmpeg` and `ffprobe` binaries to a safe location
2. **Installs wrapper scripts** in their place that:
   - Launch the real binaries through the ARM64 dynamic loader (`ld-linux-aarch64.so.1`) with a **clean, correct** `LD_LIBRARY_PATH`
   - **Intercept** live directstream jobs that use `-c:v:0 copy / -c:a:0 copy` and rewrite them to use `libx264` / `aac` with low-latency tuning
3. **Preserves Emby's detection path** — `ffdetect` still sees `IsEmbyCustom: true` and all `VideoEncoders` remain populated

### Why This Works

The wrapper only intercepts the *execution* path — it does not modify Emby binaries, patch DLLs, or change the detection/probe path. Emby still detects its own custom ffmpeg build correctly. The wrapper just ensures:

- ffmpeg launches in a clean environment (fixing crash/hang)
- Live copy-codec jobs are transparently rewritten to real transcodes (fixing Roku stalls)

### Low-Latency Tuning

The rewritten live transcode uses these settings for fast Roku startup:

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `-preset:v:0` | `superfast` | Minimize encoding latency |
| `-tune:v:0` | `zerolatency` | No lookahead buffering |
| `-profile:v:0` | `main` | Roku-compatible H.264 profile |
| `-g:v:0` | `60` | Short GOP for fast seeking |
| `-bf:v:0` | `0` | No B-frames (reduces latency) |
| `-crf:v:0` | `23` | Balanced quality/speed |
| `-c:a:0` | `aac` | 128kbps stereo audio |

---

## Requirements

- **Docker Desktop** on Apple Silicon (M1, M2, M3, M4)
- **linuxserver/emby** Docker image (`lscr.io/linuxserver/emby:latest`)
- **Roku** client (Streambar, Ultra, Express, TV, etc.)
- Live TV configured with an M3U tuner (e.g., IPTV provider)

> **Note:** This fix is ARM64 only. x86_64 systems do not have this issue — the script detects the architecture and skips itself on non-ARM64 hosts.

---

## Installation

### 1. Clone this repo

```bash
git clone https://github.com/shiz504/emby-roku-as-fix.git
cd emby-roku-as-fix
```

### 2. Copy the fix script into your Emby directory

```bash
# Create the init directory if it doesn't exist
mkdir -p /path/to/your/emby/custom-cont-init.d

# Copy the fix script
cp custom-cont-init.d/fix-ffmpeg.sh /path/to/your/emby/custom-cont-init.d/
chmod +x /path/to/your/emby/custom-cont-init.d/fix-ffmpeg.sh
```

### 3. Add the mount to your docker-compose.yml

Add this line to your `volumes:` section:

```yaml
volumes:
  - ./config:/config
  - ./transcode:/transcode
  # Add this line — the ARM64 Roku fix
  - ./custom-cont-init.d:/custom-cont-init.d:ro
```

See [`docker-compose.example.yml`](docker-compose.example.yml) for a complete example.

### 4. Restart Emby

```bash
docker compose restart emby
# or
docker restart emby
```

The fix runs automatically on every container start. Check the logs to confirm:

```bash
docker logs emby 2>&1 | grep "fix-ffmpeg"
```

You should see:

```
[fix-ffmpeg] Backing up bundled ffmpeg binary
[fix-ffmpeg] Backing up bundled ffprobe binary
[fix-ffmpeg] Installed ARM64 stable ffmpeg/ffprobe wrappers
```

On subsequent restarts, the backup step is skipped (binaries already saved) and you'll see:

```
[fix-ffmpeg] Installed ARM64 stable ffmpeg/ffprobe wrappers
```

---

## Validation

After installation, verify the fix is working:

### 1. Check that wrappers are installed

```bash
docker exec emby head -3 /app/emby/bin/ffmpeg
```

Should show a bash script, not an ELF binary:

```
#!/usr/bin/env -S -i /bin/bash
APP_DIR=/app/emby
APP_LD="/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"
```

### 2. Verify hardware detection

```bash
docker exec emby find /config/data -name "hardware_detection-*" \
  -exec grep -E "IsEmbyCustom|VideoEncoders" {} \;
```

You should see:

```
IsEmbyCustom: true
VideoEncoders: [...list of encoders...]
```

If `IsEmbyCustom` is `false` or `VideoEncoders` is empty, the fix did not install correctly.

### 3. Check for encoder errors

```bash
docker exec emby grep -c "No video encoder found" /config/logs/embyserver.txt 2>/dev/null
```

Should return `0`. Any non-zero count after applying the fix means the wrappers aren't being used.

### 4. Test Roku playback

1. Open the Emby app on your Roku
2. Go to Live TV
3. Select any channel
4. It should start playing within 3-5 seconds

See [`docs/VALIDATION.md`](docs/VALIDATION.md) for detailed API-level validation steps.

---

## What This Does NOT Do

- **Does not modify Emby binaries** — the original ffmpeg/ffprobe are preserved intact
- **Does not patch DLLs** — no binary patching of Emby server components
- **Does not require a custom Docker image** — works with the stock linuxserver/emby image
- **Does not affect non-Roku clients** — web, mobile, and other clients are unaffected
- **Does not affect library playback** — only live TV directstream jobs are rewritten; movies, shows, and music play normally
- **Does not run on x86_64** — the script detects architecture and skips itself

---

## How It Works (Technical Detail)

The linuxserver/emby image supports [custom init scripts](https://www.linuxserver.io/blog/2019-09-14-customizing-our-containers) via the `/custom-cont-init.d` mount. Scripts placed there run as root during container startup.

`fix-ffmpeg.sh` executes during this init phase and:

1. Checks architecture — exits immediately on non-ARM64
2. Copies Emby's real ELF `ffmpeg` and `ffprobe` to `/usr/local/bin/emby-ffmpeg-real` and `/usr/local/bin/emby-ffprobe-real`
3. Replaces `/app/emby/bin/ffmpeg` with a bash wrapper that:
   - Starts with `#!/usr/bin/env -S -i /bin/bash` — the `-i` flag clears the inherited environment
   - Sets up the correct `LD_LIBRARY_PATH` pointing to Emby's own lib directories
   - Scans the argument list for `-c:v:0 copy` paired with `-c:a:0 copy` (the live directstream pattern)
   - If found, rewrites to `-c:v:0 libx264` with low-latency presets and `-c:a:0 aac`
   - Launches the real binary via the ARM64 dynamic loader: `ld-linux-aarch64.so.1 --library-path ... emby-ffmpeg-real`
4. Replaces `/app/emby/bin/ffprobe` with a simpler clean-environment wrapper (no argument rewriting needed)

The wrappers are recreated on every container start, so the fix survives image updates.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `[fix-ffmpeg] Skipping on x86_64` | Running on Intel/AMD — fix not needed | This is expected on x86_64 |
| `[fix-ffmpeg] ERROR: No ELF ffmpeg binary found` | Wrappers already installed from a previous run, or image changed | Delete the container and recreate: `docker compose up -d --force-recreate` |
| `IsEmbyCustom: false` after restart | ffdetect ran before the wrapper was installed | Restart again — the init script runs before Emby starts |
| Roku still buffering | Channel source may be down, or ISP issue | Test a known-working channel; check if web client works |
| `No video encoder found for 'h264'` | Wrapper not installed or not executable | Check `docker logs emby` for `[fix-ffmpeg]` output; verify the mount is `:ro` |

---

## Tested On

| Component | Confirmed Version |
|-----------|-------------------|
| **Mac** | Mac mini (M4, Model Mac16,10) |
| **macOS** | 26.3.1 (Build 25D771280a) |
| **Docker Desktop** | 29.2.1 (Engine 29.2.1) |
| **Emby Image** | `lscr.io/linuxserver/emby:latest` (ARM64) |
| **Emby Server** | 4.9.3.0 |
| **Architecture** | aarch64 (ARM64) |
| **Client** | Roku Streambar SE |
| **Live TV Source** | IPTV via M3U tuner with XMLTV guide |

> This is the only confirmed configuration. The fix should work on any Apple Silicon Mac (M1, M2, M3, M4, Pro, Max, Ultra variants) with Docker Desktop and the linuxserver/emby ARM64 image, but only the configuration above has been fully validated end-to-end.

---

## Reporting Issues

If you run into problems, [open a GitHub issue](https://github.com/shiz504/emby-roku-as-fix/issues) and include the following:

1. **Mac model and chip** — e.g., Mac mini M4, MacBook Pro M2 Pro
2. **macOS version** — run `sw_vers`
3. **Docker version** — run `docker version`
4. **Emby server version** — visible in Emby Dashboard > Server info
5. **Docker image tag** — run `docker inspect emby --format '{{.Config.Image}}'`
6. **Hardware detection output** — the contents of the most recent `hardware_detection-*.txt` file:
   ```bash
   cat $(ls -t /path/to/emby/config/logs/hardware_detection-*.txt | head -1)
   ```
7. **Emby container logs** (last 50 lines):
   ```bash
   docker logs emby 2>&1 | tail -50
   ```

The hardware detection file is the single most useful piece of diagnostic info — it shows whether `IsEmbyCustom` is true, what `VideoEncoders` are detected, and the full ffmpeg version string.

---

## Community Feedback

This repo was just published. If you try it on your setup, please [open an issue](https://github.com/shiz504/emby-roku-as-fix/issues) or [start a discussion](https://github.com/shiz504/emby-roku-as-fix/issues) to report whether it worked or not — include your Mac model, chip, and Emby version so the tested configurations list can grow.

Success and failure reports are both valuable. The more hardware combinations confirmed, the better this fix can serve the Emby community.

---

## Credits

Developed by [Shawn McCalla](https://github.com/shiz504) using [Claude Code CLI](https://claude.ai/claude-code).

## License

[MIT](LICENSE)
