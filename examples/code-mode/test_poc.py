"""POC-level tests: batch observability + the code-mode execution path.

Codec and Session basics are covered by python/tests in the pingo package;
here we test what the POC adds on top — visible batches, effect-class shapes,
tool-failure reporting, and `execute_scheme` (the body of `run_scheme`).
"""

import asyncio

import pytest

from pingo import PingoError, Session, alist_get
from scheme_code_mode import SchemeTool, execute_scheme


def run_observed(code: str, tools: dict, classes: dict | None = None):
    async def main():
        batches = []
        async with Session() as s:
            for name, fn in tools.items():
                cls = (classes or {}).get(name, 1)  # INDEPENDENT
                s.define_async(name, fn, cls=cls)
            result = await s.run(code, on_batch=batches.append)
            return result, batches

    return asyncio.run(main())


async def aident(x):
    return x


def test_fanout_single_batch():
    """N independent calls must arrive in ONE outstanding batch."""

    async def double(n):
        return n * 2

    result, batches = run_observed("(map (lambda (n) (double n)) (list 1 2 3 4))", {"double": double})
    assert result == [2, 4, 6, 8]
    assert [len(b.calls) for b in batches] == [4]


def test_chained_call_parks_second_round():
    """(g (f x)) blocks on f first; g dispatches in the next batch."""

    async def f(n):
        return n + 1

    async def g(n):
        return n * 2

    result, batches = run_observed("(g (f 10))", {"f": f, "g": g})
    assert result == 22
    assert [len(b.calls) for b in batches] == [1, 1]
    assert batches[0].calls[0].startswith("f")
    assert batches[1].calls[0].startswith("g")


def test_ordered_drains_before_dispatch():
    """A globally-ordered call must not share a batch with earlier independents."""
    from pingo import INDEPENDENT, ORDERED

    result, batches = run_observed(
        '(begin (fetch 1) (fetch 2) (log "done"))',
        {"fetch": aident, "log": aident},
        classes={"fetch": INDEPENDENT, "log": ORDERED},
    )
    assert result == "done"
    names = [[c.split("(")[0] for c in b.calls] for b in batches]
    assert names[0] == ["fetch", "fetch"]
    assert names[-1] == ["log"]


def test_batches_run_concurrently():
    """4 tools sleeping 50ms each must take ~50ms total, not ~200ms."""

    async def slow(n):
        await asyncio.sleep(0.05)
        return n

    result, batches = run_observed("(map (lambda (n) (slow n)) (list 1 2 3 4))", {"slow": slow})
    assert result == [1, 2, 3, 4]
    assert len(batches) == 1
    assert batches[0].seconds < 0.15


# -- execute_scheme (the run_scheme body) --------------------------------------


def tool(name, fn, cls="independent"):
    return SchemeTool(name=name, fn=fn, signature=f"({name} ...)", description="t", effect_class=cls)


def test_execute_scheme_returns_sexpr_text():
    text = asyncio.run(execute_scheme('(list (cons "answer" (dbl 21)) "ok")', [tool("dbl", lambda n: n * 2)]))
    assert text == '(("answer" . 42) "ok")'


def test_execute_scheme_sync_and_async_tools():
    async def afn(x):
        return x + 1

    text = asyncio.run(execute_scheme("(+ (sfn 1) (afn 1))", [tool("sfn", lambda x: x + 1), tool("afn", afn)]))
    assert text == "4"


def test_execute_scheme_guest_error():
    with pytest.raises(PingoError, match="unbound-variable"):
        asyncio.run(execute_scheme("(nope)", []))


def test_execute_scheme_reports_failing_tool():
    def boom(_n):
        raise RuntimeError("api down")

    with pytest.raises(PingoError) as exc:
        asyncio.run(execute_scheme("(boom 1)", [tool("boom", boom)]))
    assert "host-error" in str(exc.value)
    assert "boom: RuntimeError: api down" in str(exc.value)


def test_execute_scheme_unspecified():
    assert asyncio.run(execute_scheme("(define x 1)", [])) == "; unspecified"


# -- alist helper ---------------------------------------------------------------


def test_alist_get():
    from pingo import loads

    alist = loads('(("lat" . 48.85) ("lng" . 2.35))')
    assert alist_get(alist, "lat") == 48.85
    assert alist_get(alist, "missing", "d") == "d"
