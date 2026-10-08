/*
 * ABI-compatible stubs for the GL display bridge, for a QEMU built without
 * OpenGL.
 *
 * The Swift app always calls Husk's public husk_display_gl_* symbols (through
 * HuskQemuLazy.c). When QEMU is configured with --enable-opengl the real
 * implementation, husk-display-gl.c, is compiled in QEMU's CONFIG_OPENGL
 * source set and this file compiles to nothing; with --disable-opengl these
 * stubs answer "no GL" so the app falls back cleanly to husk-display.c.
 *
 * The file itself is listed unconditionally in ui/meson.build (see
 * integrate_husk.sh), so the choice is made here, from config-host.h, rather
 * than in Meson.
 */
#include "qemu/osdep.h"

#ifndef CONFIG_OPENGL
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
#endif
