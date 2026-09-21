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

Zig: **0.16.0**
