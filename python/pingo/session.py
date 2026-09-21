"""The Pingo session: a sandboxed Scheme interpreter you feed programs to.

Two ways to service the capability calls a program makes:

* **Synchronous** — register plain Python callables and call `eval`; Pingo runs
  the program to completion, invoking a handler whenever the guest calls that
  capability::

      with Session() as s:
          s.define("add", lambda a, b: a + b)
          s.eval("(add 2 3)")            # -> 5

* **Async** — register coroutine handlers and `await run`; Pingo pauses on each
  batch of outstanding calls, the driver runs them concurrently
  (`asyncio.gather`), resolves them, and resumes. Independent calls overlap for
  free (Pingo's opportunistic dispatch)::

      async with Session() as s:
          s.define_async("fetch", fetch, cls=INDEPENDENT)
          await s.run('(list (fetch "a") (fetch "b"))')

A session is single-threaded and non-reentrant: do not call back into it from a
handler, and do not share one across threads.
"""

from __future__ import annotations

import asyncio
import ctypes
from typing import Any, Awaitable, Callable

from . import _lib
from ._lib import BLOCKED, ERROR, INDEPENDENT, ORDERED, PURE, RESOURCE, IRREVERSIBLE, VALUE
from .sexpr import dumps, loads

__all__ = [
    "Session",
    "PingoError",
    "PURE",
    "INDEPENDENT",
    "RESOURCE",
    "ORDERED",
    "IRREVERSIBLE",
]

DEFAULT_FUEL = 100_000_000
DEFAULT_CALL_DEPTH = 10_000


class PingoError(RuntimeError):
    """A guest evaluation error (the message is the Scheme error kind and
    context, e.g. ``unbound-variable (foo)``)."""


class Session:
    def __init__(
        self,
        *,
        fuel: int = DEFAULT_FUEL,
        call_depth: int = DEFAULT_CALL_DEPTH,
        heap_bytes: int = 0,
        lib: Any = None,
    ):
        self._lib = lib or _lib.load()
        self._ptr = self._lib.pingo_new(fuel, call_depth, heap_bytes)
        if not self._ptr:
            raise MemoryError("pingo_new failed")
        # Keep ctypes trampolines and returned buffers alive for the session.
        self._trampolines: list[Any] = []
        self._result_buf: Any = None
        self._async_handlers: dict[str, Callable[..., Awaitable[Any]]] = {}

    # -- lifecycle --------------------------------------------------------

    def close(self) -> None:
        if getattr(self, "_ptr", None):
            self._lib.pingo_free(self._ptr)
            self._ptr = None

    def __enter__(self) -> "Session":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    async def __aenter__(self) -> "Session":
        return self

    async def __aexit__(self, *exc: object) -> None:
        self.close()

    def __del__(self) -> None:  # best-effort
        self.close()

    # -- synchronous path -------------------------------------------------

    def define(self, name: str, handler: Callable[..., Any], *, cls: int = INDEPENDENT) -> None:
        """Registers a synchronous capability. `handler(*args)` receives the
        call's arguments as Python values and returns a Python value; raising
        signals a host failure (surfaces as `host-error`)."""

        def trampoline(_user: Any, args_c: bytes) -> int | None:
            try:
                args = loads(args_c.decode("utf-8"))
                result = handler(*args)
                # Keep the buffer alive until the next call; the C bridge reads
                # it (and copies) before returning, so one slot is enough.
                self._result_buf = ctypes.create_string_buffer(dumps(result).encode("utf-8"))
                return ctypes.cast(self._result_buf, ctypes.c_void_p).value
            except Exception:  # noqa: BLE001 - any failure is a host-error
                return None

        cb = _lib.HANDLER(trampoline)
        self._trampolines.append(cb)  # prevent GC while registered
        if self._lib.pingo_register_fn(self._ptr, name.encode("utf-8"), cls, cb, None) != 0:
            raise ValueError(f"could not register capability {name!r}")

    def eval(self, src: str) -> Any:
        """Runs `src` to completion (servicing synchronous capabilities) and
        returns the last form's value. Raises `PingoError` on failure."""
        res = self._lib.pingo_eval(self._ptr, src.encode("utf-8"))
        if res is None:
            raise PingoError(self._error())
        return loads(res.decode("utf-8"))

    # -- async path -------------------------------------------------------

    def define_async(
        self, name: str, handler: Callable[..., Awaitable[Any]], *, cls: int = INDEPENDENT
    ) -> None:
        """Registers an async capability serviced by `run`. `handler(*args)` is
        a coroutine returning a Python value."""
        self._async_handlers[name] = handler
        if self._lib.pingo_register(self._ptr, name.encode("utf-8"), cls) != 0:
            raise ValueError(f"could not register capability {name!r}")

    async def run(self, src: str) -> Any:
        """Feeds `src` and drives the blocked/resolve loop, running each batch
        of outstanding capability calls concurrently. Returns the last form's
        value; raises `PingoError` on failure."""
        status = self._lib.pingo_feed(self._ptr, src.encode("utf-8"))
        while status == BLOCKED:
            await self._service_batch()
            status = self._lib.pingo_continue(self._ptr)
        if status == ERROR:
            raise PingoError(self._error())
        return loads(self._lib.pingo_result(self._ptr).decode("utf-8"))

    async def _service_batch(self) -> None:
        count = self._lib.pingo_outstanding_count(self._ptr)
        tokens = [self._lib.pingo_call_token(self._ptr, i) for i in range(count)]

        async def one(token: int) -> tuple[int, Any, bool]:
            name = self._lib.pingo_call_name(self._ptr, token).decode("utf-8")
            args = loads(self._lib.pingo_call_args(self._ptr, token).decode("utf-8"))
            handler = self._async_handlers.get(name)
            if handler is None:
                return token, None, False
            try:
                return token, await handler(*args), True
            except Exception:  # noqa: BLE001 - any failure is a host-error
                return token, None, False

        for token, result, ok in await asyncio.gather(*(one(t) for t in tokens)):
            if ok:
                self._lib.pingo_resolve(self._ptr, token, dumps(result).encode("utf-8"))
            else:
                self._lib.pingo_resolve_failure(self._ptr, token)

    # -- misc -------------------------------------------------------------

    def _error(self) -> str:
        return self._lib.pingo_error(self._ptr).decode("utf-8")

    @property
    def version(self) -> str:
        return self._lib.pingo_version().decode("utf-8")
