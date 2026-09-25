# Pingo

**Pingo is a sandboxed Scheme with an opportunistic effect model** — a small,
pure interpreter whose programs call *out* to host-provided tools, and whose
runtime runs those calls concurrently on its own, without the program asking.
Written in Zig.

It is built for the case where an untrusted program (say, one an LLM wrote)
needs to orchestrate side-effecting tools: fetch things, call APIs, query a
database. The program is plain Scheme; the host decides which capabilities
exist and what each one is allowed to do. Independent calls overlap for free,
the language itself has no way to touch the outside world, and every run is
deterministic and replayable.

```scheme
; the three fetches are independent, so Pingo dispatches them together
; and they run concurrently — the program never mentions parallelism
(map (lambda (city) (get-weather city))
     (list "Paris" "Tokyo" "Lima"))
```

## The idea

- **Opportunistic execution.** A tool call whose arguments are ready is
  dispatched immediately; several ready calls are dispatched *as a batch* and
  serviced concurrently by the host. A call whose argument is still an
  outstanding result is *parked* and fires automatically when that result
  settles — so ordinary nested composition already expresses a dataflow
  pipeline. Concurrency is a property of the data dependencies, not something
  the program author arranges. (Model: PopPy / λᴼ.)

- **An explicit effect model.** Every capability is tagged with an effect
  class — `pure | independent | resource | ordered | irreversible` — that
  declares its ordering contract. `independent` calls may overlap and complete
  in any order; `ordered`/`irreversible` calls are constrained. The scheduler
  uses these to decide what may run together (semantics §4/§6).

- **Pure by default, no opt-out.** There is no mutation: no `set!`,
  `set-car!`, `vector-set!`, string/vector fills — pairs, strings and vectors
  are immutable. Only pure data crosses the host boundary. This is what makes
  runs deterministic and lets a recorded trace replay exactly.

- **An honest reference.** Two engines evaluate every program: a recursive
  **oracle** (the readable spec) and an explicit-stack **machine** (which adds
  `call/cc`, `dynamic-wind`, and exceptions). They are differentially tested
  against each other, so the spec and the fast path can't silently drift apart.

## The language

An R7RS-small subset, minus mutation, plus a few R6RS/SRFI extensions — all
pure:

- core R5RS forms and numeric/list/string/char/vector/symbol procedures;
- `syntax-rules` hygienic macros, `call/cc`, `dynamic-wind`, `values`;
- **records** (`define-record-type`), **exceptions**
  (`guard` / `raise` / `with-exception-handler` / `error`),
- list HOFs (`filter` `fold-left` `fold-right` `find` `partition` …),
- **regex** as SRFI-115 SREs — patterns are s-expressions, matched by a
  fuel-bounded matcher written in Scheme,
- sugar: `when` `unless` `let-values` `let*-values` `case-lambda`.

Conformance is tracked against vendored Chibi suites: R5RS runs strict (0
failures — we match R5RS-minus-mutation), R7RS is a forward coverage oracle
whose pass count climbs as features land. `zig build conformance`.

## Trying it

```
zig build
./zig-out/bin/pingo                      # REPL
./zig-out/bin/pingo program.scm          # run a file (print is granted)

# opportunistic execution from pure Scheme: declare simulated tools
./zig-out/bin/pingo tests/examples/p1-fanout.scm \
    --tool summarize:independent:100 --tool synthesize:independent:50 --trace
# [t=0ms] dispatch summarize("doc-1") ... x4 at t=0 — overlap, visibly
# virtual time: 150ms | sequential sum: 450ms | speedup: 3.00x
```

Tool classes are `pure | independent | resource | ordered | irreversible`;
latency is virtual — nothing actually sleeps.

- `--record run.trace` saves every settled call (op, args, result);
  `--replay run.trace` re-runs without `--tool` flags, serving the recorded
  results.
- `--async` runs on the native **libxev** event loop instead of the virtual
  clock: each call arms a real timer, so an independent batch overlaps in
  wall-clock time (kqueue/io_uring), and the report shows real elapsed vs the
  sequential sum.

## Embedding

Pingo is meant to be embedded. Three ways in:

- **C API** — `libpingo` over a small header (`include/pingo.h`).
  Pure data crosses as s-expression text; the host services
  capabilities through a blocked/resolve protocol, sync or async.
- **Python** — the `pingo` package wraps the C API via `ctypes` and marshals
  values to/from ordinary Python objects. `pip install pingo` ships a
  self-contained wheel (the compiled library is bundled). See `python/README.md`.
- **CLI** — the `pingo` binary above (REPL, file runner, record/replay,
  libxev host).

## Repository layout

```
src/            Zig sources, grouped as one module (`root.zig`, `main.zig` at top):
  syntax/         lexer, datum, reader, printer
  runtime/        value, env, capability, limits
  engine/         eval (oracle), machine, primitives, expand, macro
  host/           trace (record/replay), capi (C API)
  scheme/         prelude.scm, regex.scm
include/        pingo.h — the C API header
python/         the `pingo` Python package (+ its tests)
examples/       runnable examples — e.g. examples/code-mode (LLM code-mode over pydantic-ai)
tests/          Zig tests, conformance suites, example programs
pyproject.toml  builds the self-contained Python wheel (hatch_build.py runs `zig build`)
```

Zig: **0.16.0**
