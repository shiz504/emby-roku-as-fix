# Official Emby ARM64 Image Test Report

**Date:** April 1, 2026 (two test runs)
**Host:** Mac mini M4 (Apple Silicon ARM64)
**macOS:** 26.3.1
**Docker:** 29.2.1

---

## Images Tested

| | LinuxServer | Official |
|---|---|---|
| **Image** | `lscr.io/linuxserver/emby:latest` | `emby/embyserver_arm64v8:latest` |
| **Emby Version** | 4.9.3.0 | 4.9.3.0 |
| **ffmpeg Version** | 5.1-emby_2023_06_25_p4 | 5.1-emby_2023_06_25_p4 |
| **Architecture** | aarch64 | aarch64 |

## Environment Comparison

| | LinuxServer | Official |
|---|---|---|
| **LD_LIBRARY_PATH (container-level)** | NOT SET | `/lib:/system` |
| **ffmpeg path** | `/app/emby/bin/ffmpeg` | `/bin/ffmpeg` |
| **ffdetect path** | `/app/emby/bin/ffdetect` | `/bin/ffdetect` |
| **IsEmbyCustom** | true | true |
| **VideoEncoders** | 5 (libx264, libx265, mpeg4, msmpeg4, libvpx) | 5 (libx264, libx265, mpeg4, msmpeg4, libvpx) |
| **Encoder errors** | 0 | 0 |
| **custom-cont-init.d support** | Yes (linuxserver feature) | No |

## Key Finding: LD_LIBRARY_PATH

The official image sets `LD_LIBRARY_PATH=/lib:/system` at the container environment level. This means when Emby launches ffmpeg as a child process and injects its own library paths, the base environment is already correct. ffmpeg starts cleanly.

The linuxserver image does NOT set `LD_LIBRARY_PATH` at the container level. When Emby injects its own `LD_LIBRARY_PATH` into child processes on ARM64, the inherited loader environment poisons ffmpeg startup, causing crashes or silent hangs.

**This confirms that the LD_LIBRARY_PATH poisoning issue (Problem 1 in the fix) is specific to the linuxserver image packaging, not to Emby itself.**

## HLS Live TV Test Results (Unpatched Official Image)

All tests used a Roku-like device profile (h264 Main/High up to Level 4.1, 1920x1080, 8-bit, aac audio, HLS ts container with BreakOnNonKeyFrames). Client identified as "Roku Streambar".

### 10-Channel Test (Run 2, Deep Validation)

| Channel | ID | Segs | Seg0 Size | Codec | H.264 Profile | Level | Res | ffmpeg Mode | Result |
|---|---|---|---|---|---|---|---|---|---|
| BIG TEN NETWORK | 477 | 6 | 740K | h264/aac | Main | 4.0 | 1280x720 | copy/copy | OK |
| ESPN | 408 | 7 | 3626K | h264/aac | High | 4.0 | 1280x720 | copy/copy | OK |
| ESPN2 | 411 | 3 | 2229K | h264/aac | High | 4.0 | 1280x720 | copy/copy | OK |
| CBS (WWL) | 70 | 3 | 378K | h264/aac | Main | 3.1 | 960x540 | copy/copy | OK |
| FOX (WVUE) | 71 | 3 | 2717K | h264/aac | High | 4.0 | 1280x720 | copy/copy | OK |
| SEC NETWORK | 482 | 5 | 3268K | h264/aac | High | 4.0 | 1280x720 | copy/copy | OK |
| FOX SPORTS 1 | 414 | 4 | 1486K | h264/aac | Main | 4.0 | 1280x720 | copy/copy | OK |
| NFL NETWORK | 418 | 3 | 2054K | h264/aac | Main | **4.2** | **1920x1080** | copy/copy | **RISK** |
| CBSSN | 485 | 7 | 1283K | h264/aac | Main | 4.0 | 1280x720 | copy/copy | OK |
| ACC NETWORK | 475 | 3 | 3545K | h264/aac | High | 4.0 | 1280x720 | copy/copy | OK |

All segments validated with ffprobe. All are valid H.264/AAC MPEG-TS.

### Transcode Command Breakdown

| Mode | Count | Description |
|---|---|---|
| `copy/copy` (directstream) | 8 | Video and audio passthrough |
| `copy/aac` (remux) | 1 | Video passthrough, audio re-encoded to AAC |
| `libx264/copy` (transcode) | 1 | Full video transcode (CBSSN, triggered by Roku codec profile constraints) |

Zero encoder errors. Zero ffmpeg crashes. Zero segment write failures.

## Important Caveats

### What this test proves

- ffmpeg launches cleanly on the official image (no LD_LIBRARY_PATH crash)
- Emby produces HLS playlists with valid `.ts` segment entries
- Segments contain valid H.264/AAC content confirmed by ffprobe
- The copy-codec directstream path executes without errors

### What this test does NOT prove

- **Actual Roku playback was not tested.** These tests used API-level requests simulating a Roku device profile via curl. No physical Roku client was pointed at the test container.
- **The repo owner previously tested the official image with a real Roku and it did not work.** API-level segment generation and real Roku playback are different things.
- Copy-codec segments may have characteristics (timing, GOP structure, segment boundaries, metadata) that cause real Roku hardware to buffer or fail even when the segments contain valid codec data.

### NFL Network Level 4.2 Risk

NFL Network (CH 418) produces H.264 at Level 4.2 and 1920x1080. Roku's documented spec limit is Level 4.1. Because this is a copy-codec passthrough, Emby does not re-encode to bring it within spec. A real Roku may reject or struggle with this stream. On the linuxserver patched image, the wrapper rewrites this to libx264 which produces Level-compliant output.

## Revised Conclusion

**Server-side, the official Emby ARM64 image produces HLS segments without the LD_LIBRARY_PATH crash.** The LD_LIBRARY_PATH poisoning issue is confirmed as linuxserver-specific.

**However, the copy-codec HLS path may still cause Roku playback failures** that are not detectable via API testing alone. The repo owner's real-world Roku testing showed failures on the official image that these API tests cannot reproduce. Possible causes:

1. Copy-codec passthrough preserves source stream characteristics (high level, variable GOP, non-standard timing) that Roku cannot handle
2. Segment boundary alignment in copy mode may produce segments that confuse Roku's HLS parser
3. The absence of low-latency tuning (superfast, zerolatency, short GOP) means cold-start timing may be too slow for Roku

**The fix's copy-to-libx264 rewrite may address a real Roku compatibility issue independent of the LD_LIBRARY_PATH problem.** The wrapper's value may be:

1. On linuxserver: fixes BOTH the crash AND the Roku compatibility issue
2. On official: fixes only the Roku compatibility issue (no crash to fix)

## Recommendation

- The fix is confirmed necessary for `lscr.io/linuxserver/emby` on Apple Silicon
- The fix MAY also be needed for `emby/embyserver_arm64v8` if real Roku playback fails with copy-codec
- Final determination requires a real Roku pointed at the official image, which is beyond API-level testing
- The README should note this nuance rather than stating the official image definitively works
