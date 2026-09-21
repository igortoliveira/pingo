/* C smoke test for libpingo (Phase 10.3): a capability round-trip through the
 * blocked/resolve protocol, driven from C. Built and run by `zig build capi-smoke`. */
#include "pingo.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail(const char *msg) {
    fprintf(stderr, "capi-smoke: %s\n", msg);
    return 1;
}

/* Synchronous handler: args arrive as "(n)"; double n. */
static const char *dbl(void *user, const char *args) {
    (void)user;
    static char buf[32];
    long n = atol(args + 1); /* skip '(' */
    snprintf(buf, sizeof buf, "%ld", n * 2);
    return buf;
}

static int async_path(void) {
    pingo_session *s = pingo_new(1000000, 500, 0);
    if (!s) return fail("pingo_new returned null");
    if (pingo_register(s, "double", PINGO_INDEPENDENT) != 0) return fail("register failed");

    /* (+ 1 (double 20)) blocks on `double`, which we resolve to 40 → 41. */
    int st = pingo_feed(s, "(+ 1 (double 20))");
    if (st != PINGO_BLOCKED) return fail("expected BLOCKED");
    if (pingo_outstanding_count(s) != 1) return fail("expected 1 outstanding");
    uint64_t tok = pingo_call_token(s, 0);
    if (strcmp(pingo_call_name(s, tok), "double") != 0) return fail("bad call name");
    if (strcmp(pingo_call_args(s, tok), "(20)") != 0) return fail("bad call args");
    if (pingo_resolve(s, tok, "40") != 0) return fail("resolve failed");
    st = pingo_continue(s);
    if (st != PINGO_VALUE) return fail("expected VALUE");
    if (strcmp(pingo_result(s), "41") != 0) return fail("bad result");

    pingo_free(s);
    printf("capi-smoke: async ok (41 via double->40)\n");
    return 0;
}

/* The synchronous path: register a C function, eval, get a string back —
 * Chibi/s7-style ergonomics, no GC rooting. */
static int sync_path(void) {
    pingo_session *s = pingo_new(1000000, 500, 0);
    if (!s) return fail("pingo_new returned null");
    if (pingo_register_fn(s, "double", PINGO_INDEPENDENT, dbl, NULL) != 0)
        return fail("register_fn failed");

    const char *res = pingo_eval(s, "(+ 1 (double 20))");
    if (!res) return fail("eval returned NULL");
    if (strcmp(res, "41") != 0) return fail("bad sync result");

    pingo_free(s);
    printf("capi-smoke: sync ok (41 via double 20)\n");
    return 0;
}

int main(void) {
    int rc = async_path();
    if (rc) return rc;
    return sync_path();
}
