/* Freestanding `<string.h>` for the WASM build.
 *
 * `memcpy`, `memset`, `memmove`, `memcmp` and `strlen` come from Zig's
 * compiler runtime; the rest is implemented in the module itself.
 */
#ifndef ZAML_SHIM_STRING_H
#define ZAML_SHIM_STRING_H

#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
char *strdup(const char *s);

#endif /* ZAML_SHIM_STRING_H */
