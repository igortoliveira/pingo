/*
 * Pingo C API (Phase 10; design in docs/c-api.md).
 *
 * Values cross the boundary as s-expression text: the guest sandbox lets only
 * pure data reach the host (semantics S4), and Pingo's printer/reader round-
 * trip pure data losslessly. So a returned value is re-readable source, and a
 * capability result you supply is parsed the same way.
 *
 * Host protocol (blocked/resolve, docs/host.md):
 *   1. pingo_feed(session, src) runs the program until it finishes, blocks on
 *      capability calls, or errors.
 *   2. On PINGO_BLOCKED, enumerate outstanding calls, resolve each by its
 *      token, then pingo_continue(session). Repeat until PINGO_VALUE/ERROR.
 *
 * A pingo_session is single-threaded: never call into one concurrently.
 * Returned const char* strings are owned by the session and valid only until
 * the next call on that session — copy them if you need to keep them.
 */
#ifndef PINGO_H
#define PINGO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pingo_session pingo_session;

/* Effect classes (semantics S4). */
#define PINGO_PURE         0
#define PINGO_INDEPENDENT  1
#define PINGO_RESOURCE     2
#define PINGO_ORDERED      3
#define PINGO_IRREVERSIBLE 4

/* Status returned by pingo_feed / pingo_continue. */
#define PINGO_VALUE   0  /* finished; pingo_result() has the value            */
#define PINGO_BLOCKED 1  /* capability calls outstanding; resolve and continue */
#define PINGO_ERROR   2  /* failed; pingo_error() has the kind                 */

/* Session lifecycle. heap_bytes == 0 uses the default budget. */
pingo_session *pingo_new(uint64_t fuel, size_t call_depth, size_t heap_bytes);
void           pingo_free(pingo_session *s);

/* Register a capability the guest can call. Returns 0 on success, -1 on error. */
int pingo_register(pingo_session *s, const char *name, int effect_class);

/* Feed a program and drive it to the first stop. Returns a PINGO_* status. */
int pingo_feed(pingo_session *s, const char *src);
/* Resume after resolving outstanding calls. Returns a PINGO_* status. */
int pingo_continue(pingo_session *s);

/* The finished value as s-expression text (PINGO_VALUE), else "". */
const char *pingo_result(pingo_session *s);
/* The error kind and context (PINGO_ERROR), else "". */
const char *pingo_error(pingo_session *s);

/* Outstanding capability calls (meaningful after PINGO_BLOCKED). */
size_t   pingo_outstanding_count(pingo_session *s);
uint64_t pingo_call_token(pingo_session *s, size_t i); /* stable until resolved */
const char *pingo_call_name(pingo_session *s, uint64_t token);
const char *pingo_call_args(pingo_session *s, uint64_t token); /* s-expr list   */

/* Resolve one outstanding call. result_src must be pure-data s-expression.
 * Returns 0 on success, -1 on a bad token or parse error. */
int pingo_resolve(pingo_session *s, uint64_t token, const char *result_src);
int pingo_resolve_failure(pingo_session *s, uint64_t token);

const char *pingo_version(void);

#ifdef __cplusplus
}
#endif

#endif /* PINGO_H */
