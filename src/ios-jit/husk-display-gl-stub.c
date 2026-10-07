/*
 * Software-only Husk build: ABI-compatible stubs for the GL display bridge.
 *
 * The iOS 15 TrollStore target deliberately builds QEMU without OpenGL/virgl,
 * but the Swift app still links against these public Husk symbols. Keeping
 * stubs lets one app codebase fall back cleanly to husk-display.c.
 */
#include "husk-display-gl.h"

bool husk_display_gl_early(void) { return false; }
bool husk_display_gl_create(void *native_layer, int width, int height)
{
    (void)native_layer; (void)width; (void)height;
    return false;
}
bool husk_display_gl_probe(void) { return false; }
bool husk_display_gl_bind(void) { return false; }
uint64_t husk_display_gl_frames(void) { return 0; }
void husk_display_gl_set_metal_presenter(husk_metal_present_fn fn) { (void)fn; }
