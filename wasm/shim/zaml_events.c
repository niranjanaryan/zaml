/* The event bridge between libyaml and the zaml core.
 *
 * See `zaml_events.h` for the contract.
 */

#include "zaml_events.h"

#include "yaml.h"

#include <stdlib.h>
#include <string.h>

struct zaml_parser {
    yaml_parser_t parser;
    int failed;
    char problem[256];
    char context[192];
    unsigned int line;
    unsigned int column;
};

static void copy_string(char *dst, size_t cap, const char *src)
{
    size_t n = 0;
    if (src) {
        while (n + 1 < cap && src[n] != '\0') n++;
    }
    if (n > 0) memcpy(dst, src, n);
    dst[n] = '\0';
}

zaml_parser *zaml_parser_new(const unsigned char *input, size_t len)
{
    zaml_parser *parser = (zaml_parser *)malloc(sizeof(zaml_parser));
    if (!parser) return NULL;

    memset(parser, 0, sizeof(*parser));
    if (!yaml_parser_initialize(&parser->parser)) {
        free(parser);
        return NULL;
    }
    yaml_parser_set_input_string(&parser->parser, input, len);
    return parser;
}

int zaml_parser_next(zaml_parser *parser, zaml_event *ev)
{
    yaml_event_t event;

    if (!parser || parser->failed) return -1;
    if (!yaml_parser_parse(&parser->parser, &event)) {
        parser->failed = 1;
        copy_string(parser->context, sizeof(parser->context), parser->parser.context);
        copy_string(parser->problem, sizeof(parser->problem), parser->parser.problem);
        parser->line = (unsigned int)parser->parser.problem_mark.line + 1;
        parser->column = (unsigned int)parser->parser.problem_mark.column + 1;
        return -1;
    }

    memset(ev, 0, sizeof(*ev));

    switch (event.type) {
    case YAML_SCALAR_EVENT:
        ev->type = ZAML_EVENT_SCALAR;
        ev->value = (const char *)event.data.scalar.value;
        ev->value_len = event.data.scalar.length;
        if (event.data.scalar.tag) {
            ev->tag = (const char *)event.data.scalar.tag;
            ev->tag_len = strlen(ev->tag);
        }
        if (event.data.scalar.anchor) {
            ev->anchor = (const char *)event.data.scalar.anchor;
            ev->anchor_len = strlen(ev->anchor);
        }
        break;

    case YAML_SEQUENCE_START_EVENT:
        ev->type = ZAML_EVENT_SEQ_START;
        if (event.data.sequence_start.anchor) {
            ev->anchor = (const char *)event.data.sequence_start.anchor;
            ev->anchor_len = strlen(ev->anchor);
        }
        break;

    case YAML_SEQUENCE_END_EVENT:
        ev->type = ZAML_EVENT_SEQ_END;
        break;

    case YAML_MAPPING_START_EVENT:
        ev->type = ZAML_EVENT_MAP_START;
        if (event.data.mapping_start.anchor) {
            ev->anchor = (const char *)event.data.mapping_start.anchor;
            ev->anchor_len = strlen(ev->anchor);
        }
        break;

    case YAML_MAPPING_END_EVENT:
        ev->type = ZAML_EVENT_MAP_END;
        break;

    case YAML_ALIAS_EVENT:
        ev->type = ZAML_EVENT_ALIAS;
        ev->value = (const char *)event.data.alias.anchor;
        ev->value_len = ev->value ? strlen(ev->value) : 0;
        break;

    case YAML_STREAM_END_EVENT:
        yaml_event_delete(&event);
        return 0;

    default:
        /* Stream and document events carry nothing the core needs. */
        ev->type = ZAML_EVENT_NOOP;
        break;
    }

    yaml_event_delete(&event);
    return 1;
}

void zaml_parser_problem(const zaml_parser *parser, char *buf, size_t cap,
                          size_t *out_len, unsigned int *line,
                          unsigned int *column)
{
    size_t n = 0;
    if (parser && parser->problem[0] != '\0') {
        while (n + 1 < cap && parser->problem[n] != '\0') n++;
    }
    if (n > 0 && buf) memcpy(buf, parser->problem, n);
    if (buf && cap > 0) buf[n] = '\0';
    if (out_len) *out_len = n;
    if (line) *line = parser ? parser->line : 0;
    if (column) *column = parser ? parser->column : 0;
}

void zaml_parser_free(zaml_parser *parser)
{
    if (!parser) return;
    yaml_parser_delete(&parser->parser);
    free(parser);
}
