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
