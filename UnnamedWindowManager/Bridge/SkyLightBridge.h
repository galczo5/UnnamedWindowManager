#ifndef SkyLightBridge_h
#define SkyLightBridge_h

#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include <stdbool.h>

// Callback type for window move/resize events from the window server.
typedef void (*SLBorderMoveCallback)(uint32_t window_id);

// Returns the SkyLight main connection ID, or 0 on failure.
int32_t sl_connection_id(void);

// Returns the window bounds in screen coordinates (top-left origin).
// Returns true on success.
bool sl_get_window_bounds(uint32_t window_id, CGRect *out_frame);

// Returns the corner radius for the given window via the SkyLight iterator API.
// Returns 0 if unavailable (pre-macOS 26 or lookup failure).
float sl_get_corner_radius(uint32_t window_id);

// Registers for SkyLight window move/resize events.
// The callback fires on the main thread with the moved/resized window's ID.
void sl_register_move_events(SLBorderMoveCallback callback);

#endif
