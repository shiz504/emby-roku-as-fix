# Official Emby ARM64 Image Test Report

**Date:** April 1, 2026
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

All tests used the Roku HLS playback path with device profile requesting h264/aac in ts container.

| Channel | ID | HLS Segments | Copy-Codec | Segment Size | Result |
|---|---|---|---|---|---|
| BIG TEN NETWORK | 477 | Yes, valid `.ts` | `-c:v:0 copy -c:a:0 copy` | 1.3-1.5 MB | **WORKING** |
| ESPN | 408 | Yes, valid `.ts` | `-c:v:0 copy -c:a:0 copy` | Producing | **WORKING** |
| CBS (WWL) New Orleans | 70 | Yes, valid `.ts` | `-c:v:0 copy -c:a:0 copy` | Producing | **WORKING** |
| SEC NETWORK | 482 | Yes, valid `.ts` | `-c:v:0 copy -c:a:0 copy` | Producing | **WORKING** |

All 4 channels produced valid HLS playlists with real `.ts` segment entries. Zero encoder errors. All used the copy-codec directstream path.

## Conclusion

**The official Emby ARM64 image (`emby/embyserver_arm64v8`) does NOT have the Roku Live TV issue.**

The copy-codec HLS path (`-c:v:0 copy -c:a:0 copy`) works correctly on the official image because:

1. `LD_LIBRARY_PATH` is set correctly at the container level (`/lib:/system`), preventing the loader poisoning that crashes ffmpeg on the linuxserver image
2. ffmpeg launches cleanly with the correct shared libraries
3. The copy-codec segments are valid and playable

**The issue is isolated to the linuxserver/emby image packaging on ARM64.** The linuxserver image does not set `LD_LIBRARY_PATH` at the container level, which causes Emby's runtime library injection to break ffmpeg on Apple Silicon.

## Implications for the Fix

The `emby-roku-as-fix` wrapper scripts solve two problems:
1. **LD_LIBRARY_PATH poisoning** — linuxserver-specific, not present in official image
2. **Copy-codec HLS rewrite** — the official image proves copy-codec works fine when ffmpeg starts cleanly, so the rewrite in the wrapper may be addressing a symptom of Problem 1 rather than an independent failure

Users of the official Emby ARM64 image should not need this fix. The fix is specifically for `lscr.io/linuxserver/emby` on Apple Silicon.

## Recommendation

Update the GitHub README to note:
- The issue is confirmed to be linuxserver-specific
- The official `emby/embyserver_arm64v8` image works correctly for Roku Live TV on ARM64
- Users who can switch to the official image may not need the fix, but lose the linuxserver `custom-cont-init.d` hook system and other linuxserver features
