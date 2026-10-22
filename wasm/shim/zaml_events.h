/* The event bridge between libyaml and the zaml core.
 *
 * The browser/WASM module is compiled without a libc, which means Zig's
 * `@cImport` is unavailable there and the libyaml structures cannot be
 * described in Zig. This shim hides them: it walks the libyaml event
 * stream and hands the core a small, stable event record instead.
 *
 * The records point into libyaml's own buffers, which are released when
 * the next event is requested, so the core copies what it needs before
 * asking for another event.
 */
#ifndef ZAML_EVENTS_H
#define ZAML_EVENTS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct zaml_parser zaml_parser;

typedef struct zaml_event {
    /* One of the ZAML_EVENT_* constants. */
    int type;
    /* The scalar text or the alias name. */
    const char *value;
    size_t value_len;
    /* The expanded tag, empty when the scalar has none. */
    const char *tag;
    size_t tag_len;
    /* The anchor name, NULL when there is none. */
    const char *anchor;
    size_t anchor_len;
} zaml_event;

enum {
    /* An event the core does not care about (stream and document markers). */
    ZAML_EVENT_NOOP = 0,
    ZAML_EVENT_SCALAR = 1,
    ZAML_EVENT_SEQ_START = 2,
    ZAML_EVENT_SEQ_END = 3,
    ZAML_EVENT_MAP_START = 4,
    ZAML_EVENT_MAP_END = 5,
    ZAML_EVENT_ALIAS = 6
};

/* Start parsing `input`. Returns NULL when the parser cannot be created. */
zaml_parser *zaml_parser_new(const unsigned char *input, size_t len);

/* Fill `ev` with the next event.
 * Returns 1 for an event, 0 at the end of the stream and -1 on error. */
int zaml_parser_next(zaml_parser *parser, zaml_event *ev);

/* Copy the details of the last error into `buf` (NUL terminated). */
void zaml_parser_problem(const zaml_parser *parser, char *buf, size_t cap,
                          size_t *out_len, unsigned int *line,
                          unsigned int *column);

/* Release the parser and everything it owns. */
void zaml_parser_free(zaml_parser *parser);

#ifdef __cplusplus
}
#endif

#endif /* ZAML_EVENTS_H */
