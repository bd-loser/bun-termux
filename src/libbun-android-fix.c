/*
 * libbun-android-fix.c — LD_PRELOAD shim that fixes Bun on Android
 *
 * Problem:
 *   Bun 1.3.14 is the first native Android (Bionic-linked) build.
 *   Its installer uses linkat()/link()/symlinkat() to hardlink files
 *   from the global cache to node_modules/. On Android SELinux
 *   (untrusted_app_27 and similar), these syscalls sometimes return
 *   EACCES even when the process owns both directories. Bun's installer
 *   treats this as fatal, producing "EACCES: Permission denied while
 *   installing <pkg>" errors.
 *
 * Fix:
 *   Intercept linkat(), link(), symlinkat(), renameat2(). When the
 *   real syscall returns EACCES, fall back to copy_file_range() (or
 *   read/write loop on older kernels). The shim is transparent —
 *   Bun's binary is not modified.
 *
 * Usage:
 *   LD_PRELOAD=/data/data/com.termux/files/usr/lib/bun-termux/libbun-android-fix.so
 *
 * Build:
 *   See scripts/build-shim.sh — compiled in CI with Termux's clang
 *   targeting aarch64 Bionic.
 *
 * License: MIT
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sendfile.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* ─── Debug logging (set BUN_FIX_DEBUG=1 to enable) ─────────────────────── */
static int debug_enabled = -1;
static void debug_log(const char *fmt, ...) {
    if (debug_enabled == -1) {
        const char *env = getenv("BUN_FIX_DEBUG");
        debug_enabled = (env && *env) ? 1 : 0;
    }
    if (!debug_enabled) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fflush(stderr);
}

/* ─── Real syscall function pointers (lazy-initialized) ─────────────────── */
typedef int (*linkat_fn)(int, const char *, int, const char *, int);
typedef int (*link_fn)(const char *, const char *);
typedef int (*symlinkat_fn)(const char *, int, const char *);
typedef int (*symlink_fn)(const char *, const char *);
typedef int (*renameat_fn)(int, const char *, int, const char *);
typedef int (*renameat2_fn)(int, const char *, int, const char *, unsigned int);

static linkat_fn real_linkat = NULL;
static link_fn real_link = NULL;
static symlinkat_fn real_symlinkat = NULL;
static symlink_fn real_symlink = NULL;
static renameat_fn real_renameat = NULL;
static renameat2_fn real_renameat2 = NULL;

static void init_real(void) {
    if (real_linkat) return;
    real_linkat = (linkat_fn)dlsym(RTLD_NEXT, "linkat");
    real_link = (link_fn)dlsym(RTLD_NEXT, "link");
    real_symlinkat = (symlinkat_fn)dlsym(RTLD_NEXT, "symlinkat");
    real_symlink = (symlink_fn)dlsym(RTLD_NEXT, "symlink");
    real_renameat = (renameat_fn)dlsym(RTLD_NEXT, "renameat");
    real_renameat2 = (renameat2_fn)dlsym(RTLD_NEXT, "renameat2");
}

/* ─── Copy helpers ──────────────────────────────────────────────────────── */

/* Copy regular file contents from src_fd to dst_fd (already open) */
static int copy_fd_to_fd(int src_fd, int dst_fd) {
    struct stat st;
    if (fstat(src_fd, &st) < 0) return -1;

    /* Try sendfile first (works for regular files, available on Android) */
    off_t off = 0;
    size_t remaining = st.st_size;
    while (remaining > 0) {
        ssize_t n = sendfile(dst_fd, src_fd, &off, remaining);
        if (n < 0) {
            if (errno == ENOSYS) break; /* fall back to read/write */
            return -1;
        }
        if (n == 0) break;
        remaining -= n;
    }
    if (remaining == 0) return 0;

    /* Fallback: read/write loop (always works) */
    char buf[65536];
    lseek(src_fd, 0, SEEK_SET);
    lseek(dst_fd, 0, SEEK_SET);
    while (1) {
        ssize_t n = read(src_fd, buf, sizeof(buf));
        if (n < 0) return -1;
        if (n == 0) break;
        ssize_t w = 0;
        while (w < n) {
            ssize_t k = write(dst_fd, buf + w, n - w);
            if (k < 0) return -1;
            w += k;
        }
    }
    return 0;
}

/* Resolve olddirfd/olddirpath + newdirfd/newpath to absolute paths */
static int resolve_at_path(int dirfd, const char *path, char *out, size_t out_sz) {
    if (path == NULL) { errno = EFAULT; return -1; }
    if (path[0] == '/' || dirfd == AT_FDCWD) {
        snprintf(out, out_sz, "%s", path);
        return 0;
    }
    char dirpath[4096];
    char proc_path[64];
    snprintf(proc_path, sizeof(proc_path), "/proc/self/fd/%d", dirfd);
    ssize_t n = readlink(proc_path, dirpath, sizeof(dirpath) - 1);
    if (n < 0) return -1;
    dirpath[n] = '\0';
    snprintf(out, out_sz, "%s/%s", dirpath, path);
    return 0;
}

/* Copy a file from src to dst, preserving mode and timestamps */
static int copy_file(const char *src, const char *dst) {
    struct stat st;
    if (stat(src, &st) < 0) return -1;

    int src_fd = open(src, O_RDONLY | O_CLOEXEC);
    if (src_fd < 0) return -1;

    int dst_fd = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, st.st_mode & 0777);
    if (dst_fd < 0) {
        close(src_fd);
        return -1;
    }

    int rc = copy_fd_to_fd(src_fd, dst_fd);
    close(src_fd);
    if (rc < 0) {
        close(dst_fd);
        unlink(dst); /* cleanup partial */
        return -1;
    }

    /* Preserve timestamps */
    struct timespec times[2] = {st.st_atim, st.st_mtim};
    futimens(dst_fd, times);
    /* Preserve ownership */
    fchown(dst_fd, st.st_uid, st.st_gid);
    close(dst_fd);
    return 0;
}

/* ─── Interceptors ──────────────────────────────────────────────────────── */

int linkat(int olddirfd, const char *oldpath,
           int newdirfd, const char *newpath, int flags) {
    init_real();
    if (!real_linkat) { errno = ENOSYS; return -1; }

    int rc = real_linkat(olddirfd, oldpath, newdirfd, newpath, flags);
    if (rc == 0) return 0;
    if (errno != EACCES) return -1;

    /* EACCES — fall back to copy */
    char src[4096], dst[4096];
    if (resolve_at_path(olddirfd, oldpath, src, sizeof(src)) < 0) return -1;
    if (resolve_at_path(newdirfd, newpath, dst, sizeof(dst)) < 0) return -1;

    debug_log("[bun-fix] linkat EACCES fallback: %s -> %s\n", src, dst);
    if (copy_file(src, dst) < 0) {
        debug_log("[bun-fix] copy failed: %s\n", strerror(errno));
        return -1; /* errno already set by copy_file */
    }
    return 0;
}

int link(const char *oldpath, const char *newpath) {
    init_real();
    if (!real_link) { errno = ENOSYS; return -1; }

    int rc = real_link(oldpath, newpath);
    if (rc == 0) return 0;
    if (errno != EACCES) return -1;

    debug_log("[bun-fix] link EACCES fallback: %s -> %s\n", oldpath, newpath);
    return copy_file(oldpath, newpath);
}

int symlinkat(const char *target, int newdirfd, const char *linkpath) {
    init_real();
    if (!real_symlinkat) { errno = ENOSYS; return -1; }

    int rc = real_symlinkat(target, newdirfd, linkpath);
    if (rc == 0) return 0;
    if (errno != EACCES) return -1;

    /* For symlinks, fall back to copying the target file's CONTENTS
       (Android sometimes blocks symlink creation entirely) */
    char dst[4096];
    if (resolve_at_path(newdirfd, linkpath, dst, sizeof(dst)) < 0) return -1;

    debug_log("[bun-fix] symlinkat EACCES fallback: target=%s link=%s\n",
              target, dst);
    /* If target is a regular file, copy it. If target doesn't exist
       (broken symlink is intended), we have to fail. */
    struct stat st;
    if (stat(target, &st) < 0) return -1; /* can't copy, original error stands */
    if (!S_ISREG(st.st_mode)) return -1; /* only copy regular files */
    return copy_file(target, dst);
}

int symlink(const char *target, const char *linkpath) {
    init_real();
    if (!real_symlink) { errno = ENOSYS; return -1; }

    int rc = real_symlink(target, linkpath);
    if (rc == 0) return 0;
    if (errno != EACCES) return -1;

    debug_log("[bun-fix] symlink EACCES fallback: target=%s link=%s\n",
              target, linkpath);
    struct stat st;
    if (stat(target, &st) < 0) return -1;
    if (!S_ISREG(st.st_mode)) return -1;
    return copy_file(target, linkpath);
}

/* renameat — usually works on Android, but intercept just in case */
int renameat(int olddirfd, const char *oldpath,
             int newdirfd, const char *newpath) {
    init_real();
    if (!real_renameat) { errno = ENOSYS; return -1; }

    int rc = real_renameat(olddirfd, oldpath, newdirfd, newpath);
    if (rc == 0) return 0;
    if (errno != EACCES && errno != EXDEV) return -1;

    /* EACCES or EXDEV (cross-device) — fall back to copy + unlink */
    char src[4096], dst[4096];
    if (resolve_at_path(olddirfd, oldpath, src, sizeof(src)) < 0) return -1;
    if (resolve_at_path(newdirfd, newpath, dst, sizeof(dst)) < 0) return -1;

    debug_log("[bun-fix] renameat fallback (%s): %s -> %s\n",
              errno == EXDEV ? "EXDEV" : "EACCES", src, dst);
    if (copy_file(src, dst) < 0) return -1;
    if (unlink(src) < 0) {
        /* destination created but source not removed — partial state.
           Best effort: remove destination to keep consistency */
        unlink(dst);
        return -1;
    }
    return 0;
}

/* renameat2 — same approach as renameat */
int renameat2(int olddirfd, const char *oldpath,
              int newdirfd, const char *newpath, unsigned int flags) {
    init_real();
    if (!real_renameat2) {
        /* Kernel may not support renameat2 — fall back to renameat */
        return renameat(olddirfd, oldpath, newdirfd, newpath);
    }

    int rc = real_renameat2(olddirfd, oldpath, newdirfd, newpath, flags);
    if (rc == 0) return 0;
    if (errno != EACCES && errno != EXDEV) return -1;
    if (flags & RENAME_EXCHANGE) {
        /* Can't easily fall back for EXCHANGE — fail */
        return -1;
    }

    char src[4096], dst[4096];
    if (resolve_at_path(olddirfd, oldpath, src, sizeof(src)) < 0) return -1;
    if (resolve_at_path(newdirfd, newpath, dst, sizeof(dst)) < 0) return -1;

    debug_log("[bun-fix] renameat2 fallback: %s -> %s\n", src, dst);
    if (copy_file(src, dst) < 0) return -1;
    if (!(flags & RENAME_NOREPLACE)) {
        unlink(src);
    }
    return 0;
}

/* ─── Init — log that we're loaded ──────────────────────────────────────── */
__attribute__((constructor))
static void init(void) {
    debug_log("[bun-fix] libbun-android-fix.so loaded (BUN_FIX_DEBUG=%d)\n",
              debug_enabled == 1);
}
