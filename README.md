# Pingo

**A sandboxed language for AI agents whose tool calls run in parallel — automatically.**

Give an agent a single `run` tool and it writes a small program instead of one
tool call per turn ("code mode"). Pingo executes that program: a tiny, pure
Scheme that starts with **zero** access to the world and reaches out only through
the tools you grant it. The part nobody else does — Pingo figures out which of
those tool calls are **independent and runs them together**, without the model
ever writing `async` or `gather`. It runs in-process: no container, no
subprocess, no server. Written in Zig.

```scheme
;; The model wrote this to answer "which of these cities is hottest?".
;; It reads like straight-line code — Pingo runs it in two parallel waves.
(define cities (list "Paris" "Tokyo" "Lima"))
(define coords (map geocode cities))    ; 3 geocode calls — dispatched together
(define temps  (map forecast coords))   ; each forecast waits only on its own
(apply max temps)                       ; coord, so all 3 fire together too
```

No promises, no annotations, no `gather`. Two calls run at the same time whenever
their inputs don't depend on each other — that falls out of the **data flow**,
not out of the prompt.

## Why Pingo

- **Parallelism for free.** Independent tool calls go out as a batch and are
  serviced concurrently; a call waiting on another's result *parks* and fires
  itself the moment that result lands. Plain `(map f xs)` fans out. The agent
  never asks for concurrency — the runtime reads it from the program.
- **Effects the runtime understands.** Each tool declares an effect class —
  `pure`, `independent`, `resource`, `ordered`, `irreversible` — so Pingo knows
  what may overlap, what may be retried, and what must never run early. An
  irreversible call (charge a card, send an email) is never dispatched
  speculatively.
- **Deterministic and replayable.** The language has *no mutation* — everything
  is immutable — so a run depends only on its inputs and its tool results.
  Record every settled call and replay the whole program later, exactly, offline.
- **Sandboxed by construction.** No filesystem, no environment, no network, no
  ambient authority anywhere. Pure data goes in, pure data comes out; the tools
  are the only door.

## Try it

```sh
zig build                        # builds ./zig-out/bin/pingo   (Zig 0.16)
./zig-out/bin/pingo              # a REPL
./zig-out/bin/pingo prog.scm     # run a file
```

Watch the parallelism, with simulated tools on a virtual clock:

```sh
./zig-out/bin/pingo tests/examples/p1-fanout.scm \
    --tool summarize:independent:100 --tool synthesize:independent:50 --trace
# ... 4 summarize calls dispatched together at t=0 ...
# virtual time: 150ms | sequential sum: 450ms | speedup: 3.00x
```

`--record run.trace` / `--replay run.trace` capture and re-run a session;
`--async` swaps the virtual clock for a real libxev event loop (kqueue/io_uring)
so an independent batch overlaps in wall-clock time.

## Embed it

Pingo is a library first. The Python binding wraps it via `ctypes` and marshals
values to and from ordinary Python objects:

```python
import asyncio
from pingo import Session, INDEPENDENT

async def geocode(city): ...                  # your real async tool

async def main():
    async with Session() as s:
        s.define_async("geocode", geocode, cls=INDEPENDENT)
        # both calls are independent -> dispatched together -> run concurrently
        return await s.run('(map geocode (list "Paris" "Tokyo"))')

asyncio.run(main())
```

The binding, the CLI, and `examples/code-mode` (an LLM writing Pingo through
pydantic-ai) are all thin layers over one C library — `libpingo`, a small header
(`include/pingo.h`): feed a program, service the outstanding calls, resume. Build
a self-contained Python wheel with `uv build` (the compiled library is bundled);
see `python/README.md`.

## The language

A pure subset of R7RS-small plus a few R6RS/SRFI extensions: `syntax-rules`
hygienic macros, `call/cc`, `dynamic-wind`, records (`define-record-type`),
exceptions (`guard`/`raise`), list HOFs (`map`/`fold-left`/`filter`/…), and
SRFI-115 regex whose patterns are s-expressions. No mutation, by design — loops
and accumulation are recursion, `do`, `map`, and `fold`. Two engines evaluate
every program — a readable reference and a fast explicit-stack machine —
differentially tested against each other so they can't drift.

The execution model is opportunistic evaluation (PopPy / λᴼ); the capability
boundary follows Monty's "no ambient authority" stance. `zig build test` runs the
suite; `zig build conformance` runs the vendored R5RS/R7RS oracles.

Zig **0.16**
