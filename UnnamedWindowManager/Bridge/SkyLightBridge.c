#include "SkyLightBridge.h"
#include <dlfcn.h>
#include <dispatch/dispatch.h>

// SkyLight private API function pointers, resolved once at load time.

static void *skylight_lib = NULL;

static int32_t (*_SLSMainConnectionID)(void);
static CGError (*_SLSGetWindowBounds)(int32_t cid, uint32_t wid, CGRect *frame);
static CGError (*_SLSRegisterNotifyProc)(void *handler, uint32_t event, void *context);
static void *  (*_SLSWindowQueryWindows)(int32_t cid, CFArrayRef windows, uint32_t options);
static void *  (*_SLSWindowQueryResultCopyWindows)(void *query);
static bool    (*_SLSWindowIteratorAdvance)(void *iterator);
static int32_t (*_SLSWindowIteratorGetCount)(void *iterator);
static CFArrayRef (*_SLSWindowIteratorGetCornerRadii)(void *iterator);

__attribute__((constructor))
static void load_skylight(void) {
    skylight_lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                          RTLD_LAZY | RTLD_LOCAL);
    if (!skylight_lib) return;

    _SLSMainConnectionID             = dlsym(skylight_lib, "SLSMainConnectionID");
    _SLSGetWindowBounds              = dlsym(skylight_lib, "SLSGetWindowBounds");
    _SLSRegisterNotifyProc           = dlsym(skylight_lib, "SLSRegisterNotifyProc");
    _SLSWindowQueryWindows           = dlsym(skylight_lib, "SLSWindowQueryWindows");
    _SLSWindowQueryResultCopyWindows = dlsym(skylight_lib, "SLSWindowQueryResultCopyWindows");
    _SLSWindowIteratorAdvance        = dlsym(skylight_lib, "SLSWindowIteratorAdvance");
    _SLSWindowIteratorGetCount       = dlsym(skylight_lib, "SLSWindowIteratorGetCount");
    _SLSWindowIteratorGetCornerRadii = dlsym(skylight_lib, "SLSWindowIteratorGetCornerRadii");
}

// MARK: - Public API

int32_t sl_connection_id(void) {
    if (!_SLSMainConnectionID) return 0;
    return _SLSMainConnectionID();
}

bool sl_get_window_bounds(uint32_t window_id, CGRect *out_frame) {
    if (!_SLSGetWindowBounds || !_SLSMainConnectionID) return false;
    int32_t cid = _SLSMainConnectionID();
    return _SLSGetWindowBounds(cid, window_id, out_frame) == kCGErrorSuccess;
}

float sl_get_corner_radius(uint32_t window_id) {
    if (!_SLSWindowQueryWindows || !_SLSWindowQueryResultCopyWindows
        || !_SLSWindowIteratorAdvance || !_SLSWindowIteratorGetCount
        || !_SLSWindowIteratorGetCornerRadii || !_SLSMainConnectionID) {
        return 0;
    }

    int32_t cid = _SLSMainConnectionID();
    CFNumberRef wid_num = CFNumberCreate(NULL, kCFNumberSInt32Type, &window_id);
    CFArrayRef wid_array = CFArrayCreate(NULL, (const void **)&wid_num, 1, &kCFTypeArrayCallBacks);

    float radius = 0;
    void *query = _SLSWindowQueryWindows(cid, wid_array, 0x0);
    if (query) {
        void *iterator = _SLSWindowQueryResultCopyWindows(query);
        if (iterator) {
            if (_SLSWindowIteratorGetCount(iterator) > 0
                && _SLSWindowIteratorAdvance(iterator)) {
                CFArrayRef radii = _SLSWindowIteratorGetCornerRadii(iterator);
                if (radii && CFArrayGetCount(radii) > 0) {
                    CFNumberRef value = CFArrayGetValueAtIndex(radii, 0);
                    CFNumberGetValue(value, kCFNumberFloatType, &radius);
                }
            }
            CFRelease(iterator);
        }
        CFRelease(query);
    }

    CFRelease(wid_array);
    CFRelease(wid_num);
    return radius;
}

// MARK: - Event registration

#define EVENT_WINDOW_MOVE   806
#define EVENT_WINDOW_RESIZE 807

static SLBorderMoveCallback g_border_callback = NULL;

static void window_move_handler(uint32_t event, uint32_t *wid_ptr, size_t data_len, int32_t cid) {
    uint32_t wid = *wid_ptr;
    SLBorderMoveCallback cb = g_border_callback;
    if (!cb) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        cb(wid);
    });
}

void sl_register_move_events(SLBorderMoveCallback callback) {
    if (!_SLSRegisterNotifyProc || !_SLSMainConnectionID) return;
    g_border_callback = callback;
    int32_t cid = _SLSMainConnectionID();
    void *ctx = (void *)(intptr_t)cid;
    _SLSRegisterNotifyProc(window_move_handler, EVENT_WINDOW_MOVE, ctx);
    _SLSRegisterNotifyProc(window_move_handler, EVENT_WINDOW_RESIZE, ctx);
}
