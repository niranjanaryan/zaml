/* Freestanding `<stdlib.h>` for the WASM build.
 *
 * Only the handful of functions libyaml needs are declared. The
 * implementations live in the Zig side of the module (`wasm/main.zig`),
 * which routes them through the WebAssembly memory allocator.
 */
#ifndef ZAML_SHIM_STDLIB_H
#define ZAML_SHIM_STDLIB_H

#include <stddef.h>

void *malloc(size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);
char *strdup(const char *s);
void abort(void);
void exit(int status);

#endif /* ZAML_SHIM_STDLIB_H */
