# pingo (Python binding)

A generic Python binding for [Pingo](../README.md) — an embeddable, sandboxed
Scheme with an opportunistic effect model. It wraps `libpingo` (the C API in
`include/pingo.h`) via `ctypes` and marshals values to and from ordinary Python
objects, so you never handle raw s-expression strings.

Not tied to any agent framework: it exposes a `Session` and gets out of the way.

## Install

```sh
pip install pingo          # or: uv add pingo
```

The wheel bundles a compiled `libpingo` for your platform, so there is nothing
else to build. Building a wheel from source needs [Zig](https://ziglang.org)
(0.16+) on `PATH`; the build hook (`hatch_build.py`) runs `zig build` and embeds
the shared library. Build one yourself from the repo root with `uv build` (or
`python -m build`).

At runtime the binding locates `libpingo` in this order: `PINGO_LIB` (a full
path), the copy bundled in the installed package, the repo's `zig-out/lib`
(editable/dev checkouts), then the system loader.

## Synchronous

Register plain Python callables; `eval` runs a program to completion, calling a
handler whenever the guest uses that capability.

```python
from pingo import Session

with Session() as s:
    s.define("add", lambda a, b: a + b)
    print(s.eval("(add 2 (add 3 4))"))   # 9
    print(s.eval('(map (lambda (x) (* x x)) (list 1 2 3))'))  # [1, 4, 9]
```

## Asynchronous

Register coroutine handlers; `run` drives Pingo's blocked/resolve protocol and
services each batch of outstanding calls concurrently. Independent calls in a
program overlap for free — that is Pingo's opportunistic dispatch, not
something the caller arranges.

```python
import asyncio
from pingo import Session, INDEPENDENT

async def fetch(url):
    ...  # real async I/O
    return f"body of {url}"

async def main():
    async with Session() as s:
        s.define_async("fetch", fetch, cls=INDEPENDENT)
        # the two fetches are independent -> dispatched together -> run concurrently
        return await s.run('(list (fetch "a") (fetch "b"))')

asyncio.run(main())
```

## Value mapping

| Scheme          | Python                     |
|-----------------|----------------------------|
| integer / real  | `int` / `float`            |
| `#t` / `#f`     | `True` / `False`           |
| `"string"`      | `str`                      |
| symbol          | `pingo.Symbol`             |
| `#\c`           | `pingo.Char`               |
| `(a b c)` / `()`| `list` / `[]`             |
| `(a . b)`       | `pingo.Pair`               |
| `#(a b c)`      | `pingo.Vector`             |

A handler that raises signals a host failure (surfaces to the guest as
`host-error`); a guest evaluation error raises `pingo.PingoError`.

## Notes

- A `Session` is single-threaded and non-reentrant: do not call back into it
  from a handler, and do not share one across threads (all concurrency belongs
  to the host).
- Effect classes (`PURE`, `INDEPENDENT`, `RESOURCE`, `ORDERED`,
  `IRREVERSIBLE`) declare a capability's ordering contract (semantics S4);
  `INDEPENDENT` is the default and is what allows overlap.

## Tests

```sh
# from the repo root; builds the lib into the dev env and runs the suite
uv run --with pytest --with pytest-asyncio --with . pytest python/tests
```

The sexpr tests need no library; session tests skip without it.
