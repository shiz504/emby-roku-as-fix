#define _GNU_SOURCE
#include <errno.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int is_name(const char *s, const char *needle) {
    return s && strstr(s, needle) != NULL;
}

static void add_arg(char ***args, int *count, int *cap, const char *value) {
    if (*count + 2 > *cap) {
        *cap *= 2;
        char **next = realloc(*args, sizeof(char *) * (*cap));
        if (!next) {
            perror("realloc");
            exit(126);
        }
        *args = next;
    }
    (*args)[(*count)++] = (char *)value;
    (*args)[*count] = NULL;
}

static char **rewrite_ffmpeg_args(int argc, char **argv, const char *target) {
    int cap = argc + 32;
    char **out = calloc((size_t)cap, sizeof(char *));
    if (!out) {
        perror("calloc");
        exit(126);
    }
    int count = 0;
    int rewrite_video_copy = 0;
    add_arg(&out, &count, &cap, target);

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c:v:0") == 0 && i + 1 < argc && strcmp(argv[i + 1], "copy") == 0) {
            rewrite_video_copy = 1;
            add_arg(&out, &count, &cap, "-c:v:0");
            add_arg(&out, &count, &cap, "libx264");
            add_arg(&out, &count, &cap, "-preset:v:0");
            add_arg(&out, &count, &cap, "superfast");
            add_arg(&out, &count, &cap, "-tune:v:0");
            add_arg(&out, &count, &cap, "zerolatency");
            add_arg(&out, &count, &cap, "-profile:v:0");
            add_arg(&out, &count, &cap, "main");
            add_arg(&out, &count, &cap, "-pix_fmt:v:0");
            add_arg(&out, &count, &cap, "yuv420p");
            add_arg(&out, &count, &cap, "-g:v:0");
            add_arg(&out, &count, &cap, "60");
            add_arg(&out, &count, &cap, "-bf:v:0");
            add_arg(&out, &count, &cap, "0");
            add_arg(&out, &count, &cap, "-sc_threshold:v:0");
            add_arg(&out, &count, &cap, "0");
            add_arg(&out, &count, &cap, "-crf:v:0");
            add_arg(&out, &count, &cap, "23");
            i++;
            continue;
        }
        if (strcmp(argv[i], "-c:a:0") == 0 && i + 1 < argc && strcmp(argv[i + 1], "copy") == 0 && rewrite_video_copy) {
            add_arg(&out, &count, &cap, "-c:a:0");
            add_arg(&out, &count, &cap, "aac");
            add_arg(&out, &count, &cap, "-ab:a:0");
            add_arg(&out, &count, &cap, "128000");
            add_arg(&out, &count, &cap, "-ac:a:0");
            add_arg(&out, &count, &cap, "2");
            i++;
            continue;
        }
        if (strcmp(argv[i], "-copypriorss:a:0") == 0) {
            if (i + 1 < argc) i++;
            continue;
        }
        add_arg(&out, &count, &cap, argv[i]);
    }
    return out;
}

int main(int argc, char **argv) {
    const char *argv0 = argv[0] ? argv[0] : "ffmpeg";
    const char *loader = "/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1";
    const char *library_path = "/usr/lib/aarch64-linux-gnu:/app/emby/lib:/app/emby/extra/lib";
    const char *target = "/usr/local/bin/emby-ffmpeg-real";
    if (is_name(argv0, "ffprobe")) target = "/usr/local/bin/emby-ffprobe-real";
    if (is_name(argv0, "ffdetect")) target = "/usr/local/bin/emby-ffdetect-real";

    char *envp[] = {
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "APP_DIR=/app/emby",
        "AMDGPU_IDS=/app/emby/share/libdrm/amdgpu.ids",
        "FONTCONFIG_PATH=/app/emby/etc/fonts",
        "LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu:/app/emby/lib:/app/emby/extra/lib",
        "LIBVA_DRIVERS_PATH=/app/emby/extra/lib/dri",
        "OCL_ICD_VENDORS=/app/emby/extra/etc/OpenCL/vendors",
        "PCI_IDS_PATH=/app/emby/share/hwdata/pci.ids",
        "SSL_CERT_FILE=/app/emby/etc/ssl/certs/ca-certificates.crt",
        "NEOReadDebugKeys=1",
        "OverrideGpuAddressSpace=48",
        NULL
    };

    char **tool_argv;
    if (is_name(argv0, "ffmpeg") && !is_name(argv0, "ffprobe") && !is_name(argv0, "ffdetect")) {
        tool_argv = rewrite_ffmpeg_args(argc, argv, target);
    } else {
        tool_argv = calloc((size_t)argc + 1, sizeof(char *));
        if (!tool_argv) {
            perror("calloc");
            return 126;
        }
        tool_argv[0] = (char *)target;
        for (int i = 1; i < argc; i++) tool_argv[i] = argv[i];
    }

    int tool_argc = 0;
    while (tool_argv[tool_argc]) tool_argc++;

    char **next_argv = calloc((size_t)tool_argc + 4, sizeof(char *));
    if (!next_argv) {
        perror("calloc");
        return 126;
    }
    next_argv[0] = (char *)loader;
    next_argv[1] = "--library-path";
    next_argv[2] = (char *)library_path;
    for (int i = 0; i < tool_argc; i++) {
        next_argv[i + 3] = tool_argv[i];
    }

    execve(loader, next_argv, envp);
    fprintf(stderr, "emby-cleanexec: execve %s failed: %s\n", loader, strerror(errno));
    return 127;
}
