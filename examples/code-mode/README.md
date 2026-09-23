# POC — pydantic-ai Code Mode with pingo Scheme (embedded)

The official pydantic-ai Code Mode has the model write **Python** executed in
the Monty sandbox, and its runtime is not pluggable. This POC replicates the
pattern with **pingo Scheme** as the orchestration language: the model sees a
single `run_scheme` tool, writes one Scheme program that calls the real tools
as capabilities, and pingo runs it **embedded in the Python process** via the
C API (`libpingo.dylib`, ctypes — no subprocess, no server).

## How it works

```
pydantic-ai Agent (openrouter:anthropic/claude-opus-5)
  └── tool run_scheme(code)
        └── pingo.Session (ctypes → zig-out/lib/libpingo.dylib)
              feed(code)
              while BLOCKED:                       # sans-I/O blocked/resolve protocol
                  calls = outstanding()            # name + args as s-expr text
                  results = asyncio.gather(...)    # real Python tools, concurrently
                  resolve(token, result) ...
                  continue_run()
```

Control never leaves Python (no Zig→Python callbacks). pingo's opportunistic
dispatch turns plain Scheme into parallelism: independent calls arrive in one
`outstanding()` batch and are serviced concurrently; a call whose argument is a
pending result parks and dispatches itself when the argument settles.

The C API also has a **synchronous convenience layer** (`pingo_register_fn` +
`pingo_eval`, Chibi/s7-style), exposed as `Session.define(name, fn)` +
`Session.eval(code)` in the `pingo` package: Zig calls the Python tool directly
via a ctypes callback and runs to completion. Simpler (no asyncio), but calls
are serviced sequentially — the agent path uses the async driver to keep the
parallel batches.

## Files

The binding/codec layer is the official **`pingo` package** (`../python`,
editable path dependency): `Session.define_async` + `run` (async blocked/resolve
driver), `Session.define` + `eval` (synchronous path), `pingo.sexpr` codec.
Batch observability is the package's own `Session.run(on_batch=...)` hook
(each `pingo.Batch` carries the calls that ran together and their wall-clock
seconds) — no reaching into session internals. `pingo.alist_get` reads the
guest's alist records. The POC adds only the code-mode layer:

- `scheme_code_mode.py` — `SchemeTool`, `execute_scheme` and `build_agent`: the
  `run_scheme` tool and the language-subset instructions for the model.
- `demo.py` — the canonical Code Mode weather example over real Open-Meteo HTTP.
- `test_poc.py` — POC-level tests (fan-out batching, parked chaining, ordered
  draining, tool-failure reporting, execute_scheme; Session/codec basics are
  covered by `../python/tests`).

## Run

```bash
cd .. && zig build            # produces zig-out/lib/libpingo.dylib
cd poc
uv run pytest                 # offline tests, no LLM/network
echo 'OPENROUTER_API_KEY=sk-or-...' > .env
uv run python demo.py         # or: uv run python demo.py "your question"
```

Model defaults to `openrouter:anthropic/claude-opus-5`; override with
`POC_MODEL` (any pydantic-ai model string).

## Example demo output

The model writes one program; 12 native tool calls become 1 model round-trip
with two parallel batches:

```
⚡ batch: 4 call(s) in 501ms     ; get-lat-lng for the 4 cities, together
⚡ batch: 8 call(s) in 91ms      ; get-temp + description, parked → auto-dispatch
(("Paris" 18.8 "clear sky") ("Tokyo" 25.9 "mainly clear") ...)
```

## Accepted limitations

- No JSON in the guest → structured data is alists `(("k" . v) ...)`.
- No exceptions in the guest → any error aborts the whole `run_scheme`; the
  failing tool's Python exception is appended to the error and the agent
  retries (`ModelRetry`).
- Strings are byte-strings (multi-byte UTF-8 is seen byte-by-byte) — fine for
  passing through, careful with `string-length` on accented text.
- One fresh session per `run_scheme`; wall-clock timeout is the host's job
  (pingo only has fuel / call-depth / heap limits).
