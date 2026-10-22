/* Freestanding `<stdio.h>` for the WASM build.
 *
 * The parser only ever reads from a string buffer, so the file based
 * parts of libyaml are declared but never used. `FILE` is an opaque
 * type: the stubs in the module reject every use.
 */
#ifndef ZAML_SHIM_STDIO_H
#define ZAML_SHIM_STDIO_H

#include <stddef.h>

typedef struct zaml_file FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

size_t fread(void *ptr, size_t size, size_t count, FILE *stream);
size_t fwrite(const void *ptr, size_t size, size_t count, FILE *stream);
int ferror(FILE *stream);
int feof(FILE *stream);

#endif /* ZAML_SHIM_STDIO_H */
