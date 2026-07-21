/*
 * libbun-android-fix.c — LD_PRELOAD shim that fixes Bun on Android/Termux
 *
 * PROBLEM ADDRESSED:
 *   Bun 1.3.14 is the first native Android (Bionic-linked) build. On Termux
 *   and broader Android, several syscalls and path conventions Bun assumes
 *   don't hold:
 *
 *     1. SELinux (untrusted_app_27+) blocks openat(O_DIRECTORY) on / and
 *        /data (mode 0771) during Bun's directory resolver ancestor walk.
 *     2. SELinux blocks linkat()/symlinkat() during `bun install`.
 *     3. /proc/stat is restricted → os.cpus() returns [].
 *     4. /etc/resolv.conf doesn't exist → c-ares DNS fails.
 *     5. /tmp is not writable → bun --bun shim creation fails.
 *     6. Shebangs #!/usr/bin/env ... don't resolve → bin scripts fail.
 *     7. openat with O_TMPFILE didn't extract mode → va_arg corruption.
 *
 * FIXES (in order of addition):
 *   - safe_dir_fd: duplicate a safe directory fd when openat(O_DIRECTORY)
 *     fails with EACCES on a CWD ancestor. Lets the resolver walk complete.
 *   - linkat/symlinkat/renameat: fall back to copy on EACCES/EXDEV.
 *   - openat: retry without O_NOFOLLOW/O_DIRECTORY on EACCES (older path).
 *   - /proc/stat: synthesize a minimal /proc/stat via memfd_create so
 *     os.cpus() returns the real CPU count.
 *   - fopen/fopen64: redirect /etc/{resolv.conf,nsswitch.conf,hosts} →
 *     $PREFIX/etc/ so c-ares DNS works.
 *   - mkdir/symlink: translate /tmp → $TMPDIR (Bun hardcodes /tmp/bun-node*).
 *   - execve: parse shebangs and translate /usr/bin/... → $PREFIX/bin/...
 *     so bin scripts with #!/usr/bin/env node work.
 *   - __OPEN_NEEDS_MODE: correctly handle O_TMPFILE in openat/open.
 *
 * USAGE:
 *   LD_PRELOAD=/data/data/com.termux/files/usr/lib/bun-termux/libbun-android-fix.so
 *
 * ENV VARS:
 *   BUN_FIX_DEBUG=1     — enable verbose stderr logging
 *   BUN_FIX_FAKE_ROOT   — override safe_dir_fd target (default: $TMPDIR)
 *   BUN_FIX_PREFIX       — override $PREFIX for path translations
 *
 * BUILD:
 *   See scripts/build-shim.sh — compiled with Termux's clang (or NDK clang)
 *   targeting aarch64 Bionic.
 *
 * CREDITS:
 *   Several patterns (safe_dir_fd EACCES-dup, /proc/stat memfd synthesis,
 *   fopen /etc redirect, execve shebang translation, /tmp -> TMPDIR
 *   mkdir/symlink translation, linkat EXDEV copyfile fallback,
 *   __OPEN_NEEDS_MODE Bionic-clang workaround) are adapted from
 *   Happ1ness-dev/bun-termux shim.c (MIT). Their upstream loads the shim
 *   under glibc via userland-exec; this shim is Bionic-native (no
 *   userland-exec, no glibc runner).
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
#include <sys/mman.h>      /* memfd_create, MFD_CLOEXEC */
#include <sys/stat.h>
#include <sys/syscall.h>   /* SYS_write fallback for early errors */
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <limits.h>

/* __OPEN_NEEDS_MODE is glibc-internal; Bionic/NDK clang 18 doesn't define it.
 * Define our own equivalent: open() needs mode if O_CREAT or O_TMPFILE is set.
 * (O_TMPFILE == (__O_TMPFILE | O_DIRECTORY) on Linux; checking O_TMPFILE
 *  covers both the O_TMPFILE and the __O_TMPFILE part.) */
#ifndef __OPEN_NEEDS_MODE
#define __OPEN_NEEDS_MODE(flags) \
    (((flags) & O_CREAT) != 0 || ((flags) & O_TMPFILE) != 0)
#endif

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001U
#endif

/*/* === Defaults ─────────────────────────────────────────────────────────── */
#define PREFIX_DEFAULT "/data/data/com.termux/files/usr"
#define TMPDIR_DEFAULT "/data/data/com.termux/files/usr/tmp"
#define SHEBANG_MAX 256

/*/* === Globals (set in constructor) ─────────────────────────────────────── */
static const char *PREFIX = NULL;
static const char *TMPDIR = NULL;
static const char *SAFE_DIR = NULL;
static int safe_dir_fd = -1;
static char orig_cwd[PATH_MAX] = {0};

/*/* === Helpers ──────────────────────────────────────────────────────────── */

static inline const char *getenv_nonempty(const char *name) {
    const char *val = getenv(name);
    return (val && *val) ? val : NULL;
}

/* Debug logging (set BUN_FIX_DEBUG=1 to enable) */
static int debug_enabled = -1;
static void debug_log(const char *fmt, ...) {
    if (debug_enabled == -1) {
        debug_enabled = getenv_nonempty("BUN_FIX_DEBUG") ? 1 : 0;
    }
    if (!debug_enabled) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fflush(stderr);
}

/*/* === Real syscall function pointers (resolved in constructor) ─────────── */
typedef int (*openat_fn)(int, const char *, int, ...);
typedef int (*open_fn)(const char *, int, ...);
typedef FILE *(*fopen_fn)(const char *, const char *);
typedef int (*linkat_fn)(int, const char *, int, const char *, int);
typedef int (*link_fn)(const char *, const char *);
typedef int (*symlinkat_fn)(const char *, int, const char *);
typedef int (*symlink_fn)(const char *, const char *);
typedef int (*renameat_fn)(int, const char *, int, const char *);
typedef int (*renameat2_fn)(int, const char *, int, const char *, unsigned int);
typedef int (*mkdir_fn)(const char *, mode_t);
typedef int (*execve_fn)(const char *, char *const[], char *const[]);
typedef char *(*getcwd_fn)(char *, size_t);
typedef int (*faccessat_fn)(int, const char *, int, int);

static openat_fn     real_openat     = NULL;
static open_fn       real_open       = NULL;
static fopen_fn      real_fopen      = NULL;
static fopen_fn      real_fopen64    = NULL;
static linkat_fn     real_linkat     = NULL;
static link_fn       real_link       = NULL;
static symlinkat_fn  real_symlinkat  = NULL;
static symlink_fn    real_symlink    = NULL;
static renameat_fn   real_renameat   = NULL;
static renameat2_fn  real_renameat2  = NULL;
static mkdir_fn      real_mkdir      = NULL;
static execve_fn     real_execve     = NULL;
static getcwd_fn     real_getcwd     = NULL;
static faccessat_fn  real_faccessat  = NULL;

static void init_real(void) {
    if (real_openat) return;
    real_openat     = (openat_fn)   dlsym(RTLD_NEXT, "openat");
    real_open       = (open_fn)     dlsym(RTLD_NEXT, "open");
    real_fopen      = (fopen_fn)    dlsym(RTLD_NEXT, "fopen");
    real_fopen64    = (fopen_fn)    dlsym(RTLD_NEXT, "fopen64");
    real_linkat     = (linkat_fn)   dlsym(RTLD_NEXT, "linkat");
    real_link       = (link_fn)     dlsym(RTLD_NEXT, "link");
    real_symlinkat  = (symlinkat_fn)dlsym(RTLD_NEXT, "symlinkat");
    real_symlink    = (symlink_fn)  dlsym(RTLD_NEXT, "symlink");
    real_renameat   = (renameat_fn) dlsym(RTLD_NEXT, "renameat");
    real_renameat2  = (renameat2_fn)dlsym(RTLD_NEXT, "renameat2");
    real_mkdir      = (mkdir_fn)    dlsym(RTLD_NEXT, "mkdir");
    real_execve     = (execve_fn)   dlsym(RTLD_NEXT, "execve");
    real_getcwd     = (getcwd_fn)   dlsym(RTLD_NEXT, "getcwd");
    real_faccessat  = (faccessat_fn)dlsym(RTLD_NEXT, "faccessat");
}

/*/* === Path translation helpers ─────────────────────────────────────────── */

/* Translate /usr/bin/, /bin/, /usr/sbin/, /sbin/ → $PREFIX/bin/ */
static const char *translate_path(const char *path, char *buf, size_t bufsize) {
    static const char *prefixes[] = {
        "/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/",
    };
    if (!path || !PREFIX) return path;
    for (size_t i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); i++) {
        size_t skip = strlen(prefixes[i]);
        if (strncmp(path, prefixes[i], skip) == 0) {
            int n = snprintf(buf, bufsize, "%s/bin/%s", PREFIX, path + skip);
            if (n < 0 || (size_t)n >= bufsize) return path;
            return buf;
        }
    }
    return path;
}

/* Translate /tmp and /tmp/... → $TMPDIR/... */
static const char *translate_tmp(const char *path, char *buf, size_t bufsize) {
    if (!path || !TMPDIR) return path;
    if (strcmp(path, "/tmp") == 0 || strncmp(path, "/tmp/", 5) == 0) {
        int n = snprintf(buf, bufsize, "%s%s", TMPDIR, path + 4);
        if (n < 0 || (size_t)n >= bufsize) return path;
        return buf;
    }
    return path;
}

/* Translate /etc/resolv.conf, /etc/nsswitch.conf, /etc/hosts → $PREFIX/etc/ */
static const char *translate_etc(const char *path, char *buf, size_t bufsize) {
    if (!path || !PREFIX) return path;
    if (strcmp(path, "/etc/resolv.conf")   == 0 ||
        strcmp(path, "/etc/nsswitch.conf") == 0 ||
        strcmp(path, "/etc/hosts")         == 0) {
        int n = snprintf(buf, bufsize, "%s%s", PREFIX, path);
        if (n < 0 || (size_t)n >= bufsize) return path;
        return buf;
    }
    return path;
}

/* Is `pathname` an ancestor of orig_cwd? (e.g. "/", "/data", "/data/data") */
static int is_ancestor(const char *pathname) {
    if (!orig_cwd[0] || !pathname || !*pathname) return 0;
    size_t plen = strlen(pathname);
    /* Bun opens CWD ancestors with trailing slashes (e.g. "/data/"). Strip
     * them so the prefix match against orig_cwd (no trailing slash) works. */
    while (plen > 1 && pathname[plen - 1] == '/') plen--;
    if (strncmp(orig_cwd, pathname, plen) != 0) return 0;
    return (plen == 1) || (orig_cwd[plen] == '/');
}

/*/* === /proc/stat faking (fixes os.cpus()) ──────────────────────────────── */

static int generate_proc_stat(char *buf, size_t size) {
    int ncpu = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (ncpu < 1) ncpu = 1;
    if (ncpu > 256) ncpu = 256;  /* cap to bound buffer */

    int total = 0, n;
    n = snprintf(buf + total, size - total, "cpu  0 0 0 0 0 0 0 0 0 0\n");
    if (n < 0) return n;
    total += n;

    for (int i = 0; i < ncpu && total < (int)size - 128; i++) {
        n = snprintf(buf + total, size - total, "cpu%d 0 0 0 0 0 0 0 0 0 0\n", i);
        if (n < 0) return n;
        total += n;
    }
    n = snprintf(buf + total, size - total,
        "intr 0\nctxt 0\nbtime %ld\nprocesses 1\nprocs_running 1\nprocs_blocked 0\n",
        (long)time(NULL));
    if (n < 0) return n;
    return total + n;
}

static int make_proc_stat_memfd(void) {
    int fd = (int)syscall(SYS_memfd_create, "proc_stat", MFD_CLOEXEC);
    if (fd < 0) return -1;
    char buf[8192];  /* sized for ncpu cap: header + 256 lines (~27B each) + footer */
    int n = generate_proc_stat(buf, sizeof(buf));
    if (n > 0) {
        ssize_t written = write(fd, buf, (size_t)n);
        if (written == n && lseek(fd, 0, SEEK_SET) == 0) return fd;
    }
    close(fd);
    return -1;
}

/*/* === Copy helpers (for linkat/symlinkat fallbacks) ────────────────────── */

static int copy_fd_to_fd(int src_fd, int dst_fd) {
    struct stat st;
    if (fstat(src_fd, &st) < 0) return -1;

    /* Try sendfile first (works for regular files, available on Android) */
    off_t off = 0;
    size_t remaining = (size_t)st.st_size;
    while (remaining > 0) {
        ssize_t n = sendfile(dst_fd, src_fd, &off, remaining);
        if (n < 0) {
            if (errno == ENOSYS) break;  /* fall back to read/write */
            return -1;
        }
        if (n == 0) break;
        remaining -= (size_t)n;
    }
    if (remaining == 0) return 0;

    /* Fallback: read/write loop */
    char buf[65536];
    if (lseek(src_fd, 0, SEEK_SET) < 0) return -1;
    if (lseek(dst_fd, 0, SEEK_SET) < 0) return -1;
    while (1) {
        ssize_t n = read(src_fd, buf, sizeof(buf));
        if (n < 0) return -1;
        if (n == 0) break;
        ssize_t w = 0;
        while (w < n) {
            ssize_t k = write(dst_fd, buf + w, (size_t)(n - w));
            if (k < 0) return -1;
            w += k;
        }
    }
    return 0;
}

static int resolve_at_path(int dirfd, const char *path, char *out, size_t out_sz) {
    if (path == NULL) { errno = EFAULT; return -1; }
    if (path[0] == '/' || dirfd == AT_FDCWD) {
        if (strlen(path) >= out_sz) { errno = ENAMETOOLONG; return -1; }
        memcpy(out, path, strlen(path) + 1);
        return 0;
    }
    char dirpath[PATH_MAX];
    char proc_path[64];
    snprintf(proc_path, sizeof(proc_path), "/proc/self/fd/%d", dirfd);
    ssize_t n = readlink(proc_path, dirpath, sizeof(dirpath) - 1);
    if (n < 0) return -1;
    dirpath[n] = '\0';
    int wn = snprintf(out, out_sz, "%s/%s", dirpath, path);
    if (wn < 0 || (size_t)wn >= out_sz) { errno = ENAMETOOLONG; return -1; }
    return 0;
}

static int copy_file(const char *src, const char *dst) {
    struct stat st;
    if (stat(src, &st) < 0) return -1;

    int src_fd = open(src, O_RDONLY | O_CLOEXEC);
    if (src_fd < 0) return -1;

    int dst_fd = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                      st.st_mode & 0777);
    if (dst_fd < 0) {
        close(src_fd);
        return -1;
    }

    int rc = copy_fd_to_fd(src_fd, dst_fd);
    close(src_fd);
    if (rc < 0) {
        close(dst_fd);
        unlink(dst);
        return -1;
    }

    /* Preserve timestamps and ownership (best effort) */
    struct timespec times[2] = {st.st_atim, st.st_mtim};
    futimens(dst_fd, times);
    fchown(dst_fd, st.st_uid, st.st_gid);
    close(dst_fd);
    return 0;
}

/*/* === openat/open interceptor (with /proc/stat, safe_dir_fd, mode fix) ── */

static int do_openat(int (*real_fn)(int, const char *, int, ...),
                     int dirfd, const char *pathname, int flags, va_list ap) {
    if (!real_fn) { errno = ENOSYS; return -1; }

    /* Extract mode only if needed (handles O_CREAT AND O_TMPFILE) */
    mode_t mode = 0;
    if (__OPEN_NEEDS_MODE(flags)) {
        mode = va_arg(ap, mode_t);
    }

    /* /proc/stat shortcut — synthesize before real openat (which would
     * likely return EACCES on Android SELinux anyway). */
    if (pathname && strcmp(pathname, "/proc/stat") == 0) {
        int fd = make_proc_stat_memfd();
        if (fd >= 0) {
            debug_log("[bun-fix] synthesized /proc/stat (fd=%d)\n", fd);
            return fd;
        }
        debug_log("[bun-fix] /proc/stat memfd failed, falling through\n");
    }

    int fd = real_fn(dirfd, pathname, flags, mode);
    if (fd >= 0) return fd;
    if (errno != EACCES) return -1;

    /* EACCES — Tier 1: retry without O_NOFOLLOW */
    if (flags & O_NOFOLLOW) {
        int new_flags = flags & ~O_NOFOLLOW;
        debug_log("[bun-fix] openat EACCES — retry without O_NOFOLLOW: %s\n",
                  pathname ? pathname : "(null)");
        fd = real_fn(dirfd, pathname, new_flags, mode);
        if (fd >= 0) return fd;
        if (errno != EACCES) return -1;
    }

    /* EACCES — Tier 2: retry without O_DIRECTORY (callers that only stat/access) */
    if (flags & O_DIRECTORY) {
        int new_flags = flags & ~(O_DIRECTORY | O_NOFOLLOW);
        debug_log("[bun-fix] openat EACCES — retry without O_DIRECTORY: %s\n",
                  pathname ? pathname : "(null)");
        fd = real_fn(dirfd, pathname, new_flags, mode);
        if (fd >= 0) return fd;
        if (errno != EACCES) return -1;
    }

    /* EACCES — Tier 3: if O_DIRECTORY + CWD ancestor, return dup of safe_dir_fd.
     * This gives Bun a valid directory fd it can readdir() on, completing the
     * resolver ancestor walk. Adapted from Happ1ness-dev/bun-termux. */
    if ((flags & O_DIRECTORY) && safe_dir_fd >= 0 && is_ancestor(pathname)) {
        int saved_errno = errno;
        int cmd = (flags & O_CLOEXEC) ? F_DUPFD_CLOEXEC : F_DUPFD;
        int dup_fd = fcntl(safe_dir_fd, cmd, 0);
        if (dup_fd >= 0) {
            debug_log("[bun-fix] openat EACCES ancestor — returning safe_dir_fd dup: %s\n",
                      pathname ? pathname : "(null)");
            return dup_fd;
        }
        errno = saved_errno;
    }

    return -1;
}

int openat(int dirfd, const char *pathname, int flags, ...) {
    init_real();
    va_list ap;
    va_start(ap, flags);
    int result = do_openat(real_openat, dirfd, pathname, flags, ap);
    va_end(ap);
    return result;
}

int open(const char *pathname, int flags, ...) {
    init_real();
    if (!real_open) { errno = ENOSYS; return -1; }

    va_list ap;
    va_start(ap, flags);
    mode_t mode = 0;
    if (__OPEN_NEEDS_MODE(flags)) {
        mode = va_arg(ap, mode_t);
    }
    va_end(ap);

    /* /proc/stat shortcut (same as openat) */
    if (pathname && strcmp(pathname, "/proc/stat") == 0) {
        int fd = make_proc_stat_memfd();
        if (fd >= 0) return fd;
    }

    int rc = real_open(pathname, flags, mode);
    if (rc >= 0) return rc;
    if (errno != EACCES) return -1;

    if (flags & O_NOFOLLOW) {
        int new_flags = flags & ~O_NOFOLLOW;
        debug_log("[bun-fix] open EACCES — retry without O_NOFOLLOW: %s\n",
                  pathname ? pathname : "(null)");
        rc = real_open(pathname, new_flags, mode);
        if (rc >= 0) return rc;
        if (errno != EACCES) return -1;
    }

    if (flags & O_DIRECTORY) {
        int new_flags = flags & ~(O_DIRECTORY | O_NOFOLLOW);
        debug_log("[bun-fix] open EACCES — retry without O_DIRECTORY: %s\n",
                  pathname ? pathname : "(null)");
        rc = real_open(pathname, new_flags, mode);
        if (rc >= 0) return rc;
    }

    /* open() doesn't have a dirfd, so is_ancestor check still works
     * because pathname is absolute. */
    if ((flags & O_DIRECTORY) && safe_dir_fd >= 0 && is_ancestor(pathname)) {
        int saved_errno = errno;
        int cmd = (flags & O_CLOEXEC) ? F_DUPFD_CLOEXEC : F_DUPFD;
        int dup_fd = fcntl(safe_dir_fd, cmd, 0);
        if (dup_fd >= 0) {
            debug_log("[bun-fix] open EACCES ancestor — returning safe_dir_fd dup: %s\n",
                      pathname ? pathname : "(null)");
            return dup_fd;
        }
        errno = saved_errno;
    }

    return -1;
}

/* === fopen interceptor: redirect /etc/x to $PREFIX/etc/x === */

FILE *fopen(const char *pathname, const char *mode) {
    init_real();
    if (!real_fopen) { errno = ENOSYS; return NULL; }
    char buf[PATH_MAX];
    if (pathname) {
        pathname = translate_etc(pathname, buf, sizeof(buf));
    }
    return real_fopen(pathname, mode);
}

FILE *fopen64(const char *pathname, const char *mode) {
    init_real();
    if (!real_fopen64) {
        /* Bionic may not have a separate fopen64 — fall back to fopen */
        return fopen(pathname, mode);
    }
    char buf[PATH_MAX];
    if (pathname) {
        pathname = translate_etc(pathname, buf, sizeof(buf));
    }
    return real_fopen64(pathname, mode);
}

/*/* === linkat/link/symlinkat/symlink/renameat/renameat2 (EACCES fallback) ─ */

int linkat(int olddirfd, const char *oldpath,
           int newdirfd, const char *newpath, int flags) {
    init_real();
    if (!real_linkat) { errno = ENOSYS; return -1; }

    int rc = real_linkat(olddirfd, oldpath, newdirfd, newpath, flags);
    if (rc == 0) return 0;
    if (errno != EACCES) return -1;

    char src[PATH_MAX], dst[PATH_MAX];
    if (resolve_at_path(olddirfd, oldpath, src, sizeof(src)) < 0) return -1;
    if (resolve_at_path(newdirfd, newpath, dst, sizeof(dst)) < 0) return -1;

    debug_log("[bun-fix] linkat EACCES fallback: %s -> %s\n", src, dst);
    return copy_file(src, dst);
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

    /* Translate /tmp in target to $TMPDIR first */
    char tbuf[PATH_MAX];
    target = translate_tmp(target, tbuf, sizeof(tbuf));

    int rc = real_symlinkat(target, newdirfd, linkpath);
    if (rc == 0) return 0;
    if (errno != EACCES) return -1;

    char dst[PATH_MAX];
    if (resolve_at_path(newdirfd, linkpath, dst, sizeof(dst)) < 0) return -1;

    debug_log("[bun-fix] symlinkat EACCES fallback: target=%s link=%s\n",
              target, dst);
    struct stat st;
    if (stat(target, &st) < 0) return -1;
    if (!S_ISREG(st.st_mode)) return -1;
    return copy_file(target, dst);
}

int symlink(const char *target, const char *linkpath) {
    init_real();
    if (!real_symlink) { errno = ENOSYS; return -1; }

    char tbuf[PATH_MAX], lbuf[PATH_MAX];
    target   = translate_tmp(target,   tbuf, sizeof(tbuf));
    linkpath = translate_tmp(linkpath, lbuf, sizeof(lbuf));

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

int renameat(int olddirfd, const char *oldpath,
             int newdirfd, const char *newpath) {
    init_real();
    if (!real_renameat) { errno = ENOSYS; return -1; }

    int rc = real_renameat(olddirfd, oldpath, newdirfd, newpath);
    if (rc == 0) return 0;
    if (errno != EACCES && errno != EXDEV) return -1;

    char src[PATH_MAX], dst[PATH_MAX];
    if (resolve_at_path(olddirfd, oldpath, src, sizeof(src)) < 0) return -1;
    if (resolve_at_path(newdirfd, newpath, dst, sizeof(dst)) < 0) return -1;

    debug_log("[bun-fix] renameat fallback (%s): %s -> %s\n",
              errno == EXDEV ? "EXDEV" : "EACCES", src, dst);
    if (copy_file(src, dst) < 0) return -1;
    if (unlink(src) < 0) {
        unlink(dst);
        return -1;
    }
    return 0;
}

int renameat2(int olddirfd, const char *oldpath,
              int newdirfd, const char *newpath, unsigned int flags) {
    init_real();
    if (!real_renameat2) {
        return renameat(olddirfd, oldpath, newdirfd, newpath);
    }

    int rc = real_renameat2(olddirfd, oldpath, newdirfd, newpath, flags);
    if (rc == 0) return 0;
    if (errno != EACCES && errno != EXDEV) return -1;
    if (flags & RENAME_EXCHANGE) return -1;

    char src[PATH_MAX], dst[PATH_MAX];
    if (resolve_at_path(olddirfd, oldpath, src, sizeof(src)) < 0) return -1;
    if (resolve_at_path(newdirfd, newpath, dst, sizeof(dst)) < 0) return -1;

    debug_log("[bun-fix] renameat2 fallback: %s -> %s\n", src, dst);
    if (copy_file(src, dst) < 0) return -1;
    if (!(flags & RENAME_NOREPLACE)) {
        unlink(src);
    }
    return 0;
}

/*/* === mkdir interceptor (translates /tmp → $TMPDIR) ────────────────────── */

int mkdir(const char *pathname, mode_t mode) {
    init_real();
    if (!real_mkdir) { errno = ENOSYS; return -1; }
    char buf[PATH_MAX];
    pathname = translate_tmp(pathname, buf, sizeof(buf));
    return real_mkdir(pathname, mode);
}

/*/* === execve interceptor (shebang translation) ─────────────────────────── */

static int parse_shebang(const char *path, char *interp, size_t interp_size,
                         char *interp_arg, size_t arg_size) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;

    char buf[SHEBANG_MAX];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n < 2 || buf[0] != '#' || buf[1] != '!') return -1;

    char *start = buf + 2;
    while (start < buf + n && (*start == ' ' || *start == '\t')) start++;
    if (start >= buf + n) return -1;

    char *end = start;
    while (end < buf + n && *end != ' ' && *end != '\t' &&
           *end != '\n' && *end != '\r') end++;

    size_t interp_len = (size_t)(end - start);
    if (interp_len == 0 || interp_len >= interp_size) return -1;
    memcpy(interp, start, interp_len);
    interp[interp_len] = '\0';

    /* Parse optional single argument */
    if (interp_arg && arg_size > 0) interp_arg[0] = '\0';
    if (interp_arg && end < buf + n && (*end == ' ' || *end == '\t')) {
        char *arg_start = end + 1;
        while (arg_start < buf + n && (*arg_start == ' ' || *arg_start == '\t')) arg_start++;
        char *arg_end = arg_start;
        while (arg_end < buf + n && *arg_end != '\n' && *arg_end != '\r') arg_end++;
        size_t arg_len = (size_t)(arg_end - arg_start);
        /* Trim trailing whitespace */
        while (arg_len > 0 && (arg_start[arg_len - 1] == ' ' || arg_start[arg_len - 1] == '\t')) arg_len--;
        if (arg_len > 0 && arg_len < arg_size) {
            memcpy(interp_arg, arg_start, arg_len);
            interp_arg[arg_len] = '\0';
        }
    }
    return 0;
}

int execve(const char *pathname, char *const argv[], char *const envp[]) {
    init_real();
    if (!real_execve) { errno = ENOSYS; return -1; }

    /* Translate /tmp in pathname to $TMPDIR (bun-node shim path) */
    char pbuf[PATH_MAX];
    pathname = translate_tmp(pathname, pbuf, sizeof(pbuf));

    char interp_buf[PATH_MAX], arg_buf[PATH_MAX], translated_buf[PATH_MAX];
    if (parse_shebang(pathname, interp_buf, sizeof(interp_buf),
                      arg_buf, sizeof(arg_buf)) == 0) {
        const char *translated = translate_path(interp_buf, translated_buf,
                                                sizeof(translated_buf));
        if (translated != interp_buf) {
            /* Shebang interpreter was translated — rebuild argv */
            int orig_argc = 0;
            while (argv[orig_argc]) orig_argc++;

            int has_arg = arg_buf[0] ? 1 : 0;
            int new_argc = 1 + has_arg + 1 + orig_argc;
            char **new_argv = malloc((size_t)(new_argc + 1) * sizeof(char *));
            if (!new_argv) { errno = ENOMEM; return -1; }

            int i = 0;
            new_argv[i++] = (char *)translated;
            if (has_arg) new_argv[i++] = arg_buf;
            /* Use pathname (full path), NOT argv[0] — matches Linux kernel
             * shebang behavior. The kernel replaces argv[0] with the full
             * script path. Using argv[0] (which may be just "ng") causes
             * the interpreter (node) to fail resolving the script relative
             * to cwd instead of using the full path. */
            new_argv[i++] = (char *)pathname;
            for (int j = 1; j < orig_argc; j++) new_argv[i++] = argv[j];
            new_argv[i] = NULL;

            debug_log("[bun-fix] execve shebang translated: %s -> %s\n",
                      interp_buf, translated);
            int rc = real_execve(translated, new_argv, envp);
            free(new_argv);
            return rc;
        }
    }
    return real_execve(pathname, argv, envp);
}

/*/* === getcwd interceptor (EACCES fallback) ─────────────────────────────── */

char *getcwd(char *buf, size_t size) {
    init_real();
    if (!real_getcwd) { errno = ENOSYS; return NULL; }

    char *rc = real_getcwd(buf, size);
    if (rc != NULL) return rc;
    if (errno != EACCES) return NULL;

    debug_log("[bun-fix] getcwd EACCES — trying /proc/self/cwd\n");
    char proc_buf[PATH_MAX];
    ssize_t n = readlink("/proc/self/cwd", proc_buf, sizeof(proc_buf) - 1);
    if (n > 0) {
        proc_buf[n] = '\0';
        size_t needed = (size_t)n + 1;
        if (size < needed) { errno = ERANGE; return NULL; }
        memcpy(buf, proc_buf, needed);
        return buf;
    }

    const char *pwd = getenv_nonempty("PWD");
    if (pwd) {
        size_t needed = strlen(pwd) + 1;
        if (size < needed) { errno = ERANGE; return NULL; }
        memcpy(buf, pwd, needed);
        return buf;
    }
    return NULL;
}

/*/* === faccessat interceptor (AT_EACCESS fallback) ──────────────────────── */

int faccessat(int dirfd, const char *path, int mode, int flags) {
    init_real();
    if (!real_faccessat) { errno = ENOSYS; return -1; }

    int rc = real_faccessat(dirfd, path, mode, flags);
    if (rc == 0) return 0;
    if (errno != EACCES) return -1;

    if (flags & AT_EACCESS) {
        int new_flags = flags & ~AT_EACCESS;
        debug_log("[bun-fix] faccessat EACCES — retry without AT_EACCESS: %s\n",
                  path ? path : "(null)");
        return real_faccessat(dirfd, path, mode, new_flags);
    }
    return -1;
}

/*/* === Constructor ──────────────────────────────────────────────────────── */

__attribute__((constructor))
static void init(void) {
    init_real();

    PREFIX  = getenv_nonempty("BUN_FIX_PREFIX");
    if (!PREFIX)  PREFIX  = getenv_nonempty("PREFIX");
    if (!PREFIX)  PREFIX  = PREFIX_DEFAULT;

    TMPDIR  = getenv_nonempty("TMPDIR");
    if (!TMPDIR)  TMPDIR  = TMPDIR_DEFAULT;

    SAFE_DIR = getenv_nonempty("BUN_FIX_FAKE_ROOT");
    if (!SAFE_DIR) SAFE_DIR = TMPDIR;

    /* Open safe_dir_fd for use in openat ancestor fallback */
    safe_dir_fd = open(SAFE_DIR, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (safe_dir_fd < 0) {
        debug_log("[bun-fix] warning: could not open safe_dir %s: %s\n",
                  SAFE_DIR, strerror(errno));
        safe_dir_fd = -1;
    }

    /* Cache CWD for ancestor checks */
    if (!getcwd(orig_cwd, sizeof(orig_cwd))) {
        orig_cwd[0] = '\0';
    }

    debug_log("[bun-fix] libbun-android-fix.so loaded (debug=%d, PREFIX=%s, TMPDIR=%s, safe_dir_fd=%d, cwd=%s)\n",
              debug_enabled == 1, PREFIX, TMPDIR, safe_dir_fd, orig_cwd);
}
