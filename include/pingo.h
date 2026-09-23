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

/* Commutativity of a PINGO_RESOURCE capability on the same key (S18, opt-in). */
#define PINGO_COMM_NONE       0  /* non-commutative: same-key calls keep order  */
#define PINGO_COMM_READ_ONLY  1
#define PINGO_COMM_MONOID     2  /* commutative monoid: same-key calls overlap  */
#define PINGO_COMM_IDEMPOTENT 3

/* Status returned by pingo_feed / pingo_continue. */
#define PINGO_VALUE   0  /* finished; pingo_result() has the value            */
#define PINGO_BLOCKED 1  /* capability calls outstanding; resolve and continue */
#define PINGO_ERROR   2  /* failed; pingo_error() has the kind                 */

/* Session lifecycle. heap_bytes == 0 uses the default budget. */
pingo_session *pingo_new(uint64_t fuel, size_t call_depth, size_t heap_bytes);
void           pingo_free(pingo_session *s);

/* Register a capability the guest can call. Returns 0 on success, -1 on error. */
int pingo_register(pingo_session *s, const char *name, int effect_class);

/* Like pingo_register, with the S18 opt-in: resource_arg is the argument index
 * whose printed form is this call's resource key (-1 = none -> global ordering),
 * and commutativity is a PINGO_COMM_* constant. Two PINGO_RESOURCE calls
 * conflict only when their keys match and the op is non-commutative. */
int pingo_register_ex(pingo_session *s, const char *name, int effect_class,
                      int resource_arg, int commutativity);

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

/*
 * Synchronous convenience layer (Chibi/s7-style ergonomics, no GC rooting).
 * Register a C handler per capability, then pingo_eval runs to completion and
 * calls the handlers directly. Use this instead of the blocked/resolve loop
 * when the host does not need to own the wait.
 */

/* Receives the call's arguments as an s-expression list; returns the result as
 * an s-expression (pure data), or NULL to signal a host failure. The returned
 * string need only stay valid until the handler returns. */
typedef const char *(*pingo_handler)(void *user, const char *args);

int pingo_register_fn(pingo_session *s, const char *name, int effect_class,
                      pingo_handler handler, void *user);

/* Evaluate a program to completion via the registered handlers. Returns the
 * value as s-expression text (valid until the next call), or NULL on error
 * (then pingo_error() has the kind). */
const char *pingo_eval(pingo_session *s, const char *src);

const char *pingo_version(void);

#ifdef __cplusplus
}
#endif

#endif /* PINGO_H */
