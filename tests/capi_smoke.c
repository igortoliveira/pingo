/* C smoke test for libpingo (Phase 10.3): a capability round-trip through the
 * blocked/resolve protocol, driven from C. Built and run by `zig build capi-smoke`. */
#include "pingo.h"
#include <stdio.h>
#include <string.h>

static int fail(const char *msg) {
    fprintf(stderr, "capi-smoke: %s\n", msg);
    return 1;
}

int main(void) {
    pingo_session *s = pingo_new(1000000, 500, 0);
    if (!s) return fail("pingo_new returned null");

    if (pingo_register(s, "double", PINGO_INDEPENDENT) != 0)
        return fail("register failed");

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
    printf("capi-smoke: ok (result 41 via double->40)\n");
    return 0;
}
