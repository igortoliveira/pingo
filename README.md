# Pingo

An execution model for sandboxed programs — dependency-, suspension- and
effect-oriented — with Scheme as its first frontend. Implemented in Zig.

- Motivation and architecture: `deep-research-report.md`
- Execution plan (small commits): `PLAN.md`
- Normative semantics: `docs/semantics.md` (in progress)
- Source systems and papers (Thorin, Monty, PopPy/λᴼ, …): `docs/references.md`

## Trying it

```
zig build
./zig-out/bin/pingo                      # REPL
./zig-out/bin/pingo program.scm          # run a file (print is granted)

# test opportunistic execution from pure Scheme: declare simulated tools
./zig-out/bin/pingo tests/examples/p1-fanout.scm \
    --tool summarize:independent:100 --tool synthesize:independent:50 --trace
# [t=0ms] dispatch summarize("doc-1") ... x4 at t=0 — overlap, visibly
# virtual time: 150ms | sequential sum: 450ms | speedup: 3.00x
```

Tool classes: `pure | independent | resource | ordered | irreversible` (§4 of
the semantics); latency is virtual — nothing actually sleeps.

Add `--record run.trace` to save every settled call (op, args, result) to a
file; `--replay run.trace` re-runs without `--tool` flags, reconstructing the
tools from the trace and serving the recorded results (docs/host.md).

Add `--async` to run on the native **libxev** event loop instead of the
virtual clock: each tool call arms a real timer for its latency, so a batch of
independent calls overlaps in wall-clock time (kqueue/io_uring). The final
report shows real elapsed time vs the sequential sum.

Zig: **0.16.0**
