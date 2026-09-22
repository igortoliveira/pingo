"""Session tests — require a built libpingo (skipped otherwise)."""

import asyncio

import pytest

from pingo import INDEPENDENT, PingoError, Session
from pingo._lib import LibraryNotFound


def _session(**kw):
    try:
        return Session(**kw)
    except LibraryNotFound:
        pytest.skip("libpingo not built (run `zig build`)")


def test_pure_eval():
    with _session() as s:
        assert s.eval("(+ 1 2 3)") == 6
        assert s.eval('(list 1 "two" (quote three))')[1] == "two"


def test_define_and_use():
    with _session() as s:
        assert s.eval("(define x 10) (* x x)") == 100


def test_sync_capability():
    with _session() as s:
        s.define("add", lambda a, b: a + b)
        assert s.eval("(add 2 (add 3 4))") == 9


def test_sync_capability_receives_python_values():
    seen = {}

    def record(name, n):
        seen["name"] = name
        seen["n"] = n
        return [name, n]

    with _session() as s:
        s.define("record", record)
        result = s.eval('(record "hi" 7)')
    assert seen == {"name": "hi", "n": 7}
    assert result == ["hi", 7]


def test_error_raises():
    with _session() as s:
        with pytest.raises(PingoError):
            s.eval("(car '())")


def test_handler_failure_is_host_error():
    def boom():
        raise ValueError("nope")

    with _session() as s:
        s.define("boom", boom)
        with pytest.raises(PingoError):
            s.eval("(boom)")


def test_async_capabilities_overlap():
    order = []

    async def slow(tag, delay):
        await asyncio.sleep(delay)
        order.append(tag)
        return tag

    async def main():
        async with Session() as s:
            s.define_async("slow", slow, cls=INDEPENDENT)
            # both calls are independent -> dispatched together -> overlap
            return await s.run('(list (slow "a" 0.05) (slow "b" 0.01))')

    try:
        Session()
    except LibraryNotFound:
        pytest.skip("libpingo not built (run `zig build`)")

    result = asyncio.run(main())
    assert result == ["a", "b"]
    assert order == ["b", "a"]  # b finished first despite being second — real concurrency


def test_on_batch_hook():
    from pingo import Batch

    async def slow(tag, delay):
        await asyncio.sleep(delay)
        return tag

    async def f(n):
        await asyncio.sleep(0.01)
        return n + 1

    async def g(n):
        await asyncio.sleep(0.01)
        return n * 10

    async def main():
        batches: list[Batch] = []
        async with Session() as s:
            s.define_async("slow", slow)
            s.define_async("f", f)
            s.define_async("g", g)
            # fan-out: two calls dispatched together -> one batch of two
            await s.run('(list (slow "a" 0.02) (slow "b" 0.01))', on_batch=batches.append)
            fanout = list(batches)
            batches.clear()
            # chained: g depends on f -> two batches of one
            await s.run("(g (f 1))", on_batch=batches.append)
            chained = list(batches)
        return fanout, chained

    try:
        Session()
    except LibraryNotFound:
        pytest.skip("libpingo not built (run `zig build`)")

    fanout, chained = asyncio.run(main())
    assert len(fanout) == 1
    assert len(fanout[0].calls) == 2
    assert fanout[0].seconds >= 0
    assert [len(b.calls) for b in chained] == [1, 1]


def test_streaming_overlaps_across_stages():
    """A fast pipeline's second stage must start before a slow pipeline's
    first stage finishes — cross-stage streaming, not a per-round barrier."""
    import time as _t

    events: list[tuple[str, float]] = []

    async def f(tag, delay):
        await asyncio.sleep(delay)
        events.append((f"f:{tag}:done", _t.monotonic()))
        return tag

    async def g(tag):
        events.append((f"g:{tag}:start", _t.monotonic()))
        await asyncio.sleep(0.01)
        return tag

    async def main():
        async with Session() as s:
            s.define_async("f", f)
            s.define_async("g", g)
            # two independent pipelines: fast (a) and slow (b)
            return await s.run(
                '(list (g (f "a" 0.01)) (g (f "b" 0.20)))'
            )

    try:
        Session()
    except LibraryNotFound:
        pytest.skip("libpingo not built (run `zig build`)")

    asyncio.run(main())
    g_a_start = next(t for name, t in events if name == "g:a:start")
    f_b_done = next(t for name, t in events if name == "f:b:done")
    # g(a) must start well before f(b) finishes — the barrier model would
    # force g(a) to wait for the whole first stage (incl. f(b)).
    assert g_a_start < f_b_done


def test_async_result():
    async def double(n):
        return n * 2

    async def main():
        async with Session() as s:
            s.define_async("double", double)
            return await s.run("(+ 1 (double 20))")

    try:
        Session()
    except LibraryNotFound:
        pytest.skip("libpingo not built (run `zig build`)")
    assert asyncio.run(main()) == 41
