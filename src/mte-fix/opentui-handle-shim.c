/*
 * opentui-handle-shim.c — C-side handle table for opentui FFI
 *
 * PROBLEM:
 *   Bun's FFI trampoline strips scudo's TBI tag (top byte 0xb4) when
 *   passing tagged pointers from JS to native functions. This causes
 *   Bionic's free() to abort with "Pointer tag was truncated".
 *
 *   - H0-A (cc, internal malloc+free): ✅ PASS (pointer never goes through JS)
 *   - H3 (dlopen malloc + dlopen free): ❌ CRASH (tag stripped in JS→C)
 *   - H5 (dlopen malloc + cc free):     ❌ CRASH (tag stripped in JS→C)
 *   - CPU MTE support: NO (this is TBI software tagging, not MTE hardware)
 *
 * SOLUTION:
 *   This C shim is compiled with cc() (TinyCC). It:
 *   1. dlopen's libopentui.so IN C (not JS)
 *   2. dlsym's all function pointers IN C
 *   3. Stores all native pointers in a C-side handle table
 *   4. Exposes wrapper functions that take integer handles (not pointers)
 *
 *   JS never sees a tagged pointer. JS only sees integer handles.
 *   All pointer arithmetic and dereferencing happens in C.
 *
 * USAGE (from JS):
 *   const { cc } = require("bun:ffi")
 *   const lib = cc({
 *     source: "opentui-handle-shim.c",
 *     symbols: {
 *       shim_init: { args: ["cstring"], returns: "i32" },
 *       shim_createRenderer: { args: ["u32", "u32", "u8", "u8"], returns: "u32" },
 *       shim_destroyRenderer: { args: ["u32"], returns: "void" },
 *       shim_yogaNodeCreate: { args: [], returns: "u32" },
 *       shim_yogaNodeFree: { args: ["u32"], returns: "void" },
 *       shim_yogaNodeStyleSetValue: { args: ["u32", "u32", "u32", "u32", "f32"], returns: "void" },
 *       shim_yogaNodeStyleSetEnum: { args: ["u32", "u32", "u32"], returns: "void" },
 *       shim_yogaNodeCalculateLayout: { args: ["u32", "f32", "f32"], returns: "void" },
 *     }
 *   })
 *   lib.symbols.shim_init("/path/to/libopentui.so")
 *   const renderer = lib.symbols.shim_createRenderer(80, 24, 0, 0)
 *   const node = lib.symbols.shim_yogaNodeCreate()
 *   lib.symbols.shim_yogaNodeStyleSetValue(node, 0, 0, 1, 80)
 *   lib.symbols.shim_yogaNodeCalculateLayout(node, 80, 24)
 *   lib.symbols.shim_yogaNodeFree(node)
 *   lib.symbols.shim_destroyRenderer(renderer)
 */

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ─── Handle table ──────────────────────────────────────────────── */
#define MAX_HANDLES 4096
static void* handles[MAX_HANDLES];
static int handle_count = 1;  /* 0 = invalid */

static int ptr_to_handle(void* ptr) {
    if (handle_count >= MAX_HANDLES) return 0;
    handles[handle_count] = ptr;
    return handle_count++;
}

static void* handle_to_ptr(int handle) {
    if (handle <= 0 || handle >= MAX_HANDLES) return NULL;
    return handles[handle];
}

static void free_handle(int handle) {
    if (handle > 0 && handle < MAX_HANDLES) {
        handles[handle] = NULL;
    }
}

/* ─── opentui function pointers (resolved in C) ────────────────── */
typedef unsigned int (*createRenderer_fn)(unsigned int, unsigned int, unsigned char, unsigned char, void*);
typedef void (*destroyRenderer_fn)(unsigned int);
typedef void (*setUseThread_fn)(unsigned int, int);
typedef void (*setClearOnShutdown_fn)(unsigned int, int);
typedef void (*setupTerminal_fn)(unsigned int, int);
typedef void* (*yogaNodeCreateForOpenTUI_fn)(void);
typedef void (*yogaNodeFree_fn)(void*);
typedef void (*yogaNodeStyleSetValue_fn)(void*, unsigned int, unsigned int, unsigned int, float);
typedef void (*yogaNodeStyleSetEnum_fn)(void*, unsigned int, unsigned int);
typedef void (*yogaNodeCalculateLayout_fn)(void*, float, float);

static struct {
    createRenderer_fn createRenderer;
    destroyRenderer_fn destroyRenderer;
    setUseThread_fn setUseThread;
    setClearOnShutdown_fn setClearOnShutdown;
    setupTerminal_fn setupTerminal;
    yogaNodeCreateForOpenTUI_fn yogaNodeCreateForOpenTUI;
    yogaNodeFree_fn yogaNodeFree;
    yogaNodeStyleSetValue_fn yogaNodeStyleSetValue;
    yogaNodeStyleSetEnum_fn yogaNodeStyleSetEnum;
    yogaNodeCalculateLayout_fn yogaNodeCalculateLayout;
} opentui;

static void* opentui_lib = NULL;

/* ─── Init: dlopen + dlsym (all in C) ───────────────────────────── */
int shim_init(const char* libpath) {
    opentui_lib = dlopen(libpath, 1 /* RTLD_LAZY */);
    if (!opentui_lib) {
        fprintf(stderr, "[shim] dlopen failed: %s\n", dlerror());
        return -1;
    }

    opentui.createRenderer = (createRenderer_fn)dlsym(opentui_lib, "createRenderer");
    opentui.destroyRenderer = (destroyRenderer_fn)dlsym(opentui_lib, "destroyRenderer");
    opentui.setUseThread = (setUseThread_fn)dlsym(opentui_lib, "setUseThread");
    opentui.setClearOnShutdown = (setClearOnShutdown_fn)dlsym(opentui_lib, "setClearOnShutdown");
    opentui.setupTerminal = (setupTerminal_fn)dlsym(opentui_lib, "setupTerminal");
    opentui.yogaNodeCreateForOpenTUI = (yogaNodeCreateForOpenTUI_fn)dlsym(opentui_lib, "yogaNodeCreateForOpenTUI");
    opentui.yogaNodeFree = (yogaNodeFree_fn)dlsym(opentui_lib, "yogaNodeFree");
    opentui.yogaNodeStyleSetValue = (yogaNodeStyleSetValue_fn)dlsym(opentui_lib, "yogaNodeStyleSetValue");
    opentui.yogaNodeStyleSetEnum = (yogaNodeStyleSetEnum_fn)dlsym(opentui_lib, "yogaNodeStyleSetEnum");
    opentui.yogaNodeCalculateLayout = (yogaNodeCalculateLayout_fn)dlsym(opentui_lib, "yogaNodeCalculateLayout");

    if (!opentui.createRenderer || !opentui.yogaNodeCreateForOpenTUI) {
        fprintf(stderr, "[shim] dlsym failed for core functions\n");
        return -2;
    }

    return 0;
}

/* ─── Wrapper functions (take handles, not pointers) ───────────── */

unsigned int shim_createRenderer(unsigned int w, unsigned int h, unsigned char a, unsigned char b) {
    return opentui.createRenderer(w, h, a, b, NULL);
}

void shim_destroyRenderer(unsigned int renderer) {
    opentui.destroyRenderer(renderer);
}

void shim_setupTerminal(unsigned int renderer, int use_thread) {
    opentui.setUseThread(renderer, 0);
    opentui.setClearOnShutdown(renderer, 0);
    opentui.setupTerminal(renderer, use_thread);
}

unsigned int shim_yogaNodeCreate(void) {
    void* node = opentui.yogaNodeCreateForOpenTUI();
    if (!node) return 0;
    return ptr_to_handle(node);
}

void shim_yogaNodeFree(unsigned int handle) {
    void* node = handle_to_ptr(handle);
    if (node) {
        opentui.yogaNodeFree(node);
        free_handle(handle);
    }
}

void shim_yogaNodeStyleSetValue(unsigned int handle, unsigned int kind, unsigned int edge, unsigned int unit, float value) {
    void* node = handle_to_ptr(handle);
    if (node) {
        opentui.yogaNodeStyleSetValue(node, kind, edge, unit, value);
    }
}

void shim_yogaNodeStyleSetEnum(unsigned int handle, unsigned int kind, unsigned int value) {
    void* node = handle_to_ptr(handle);
    if (node) {
        opentui.yogaNodeStyleSetEnum(node, kind, value);
    }
}

void shim_yogaNodeCalculateLayout(unsigned int handle, float width, float height) {
    void* node = handle_to_ptr(handle);
    if (node) {
        opentui.yogaNodeCalculateLayout(node, width, height);
    }
}
