"""Code Mode for pydantic-ai with pingo Scheme as the orchestration language.

Mirrors the official pydantic-ai CodeMode pattern (which is Python/Monty only):
the model sees a single `run_scheme` tool; the real tools become pingo
capabilities that the generated Scheme program calls. Independent calls are
dispatched opportunistically by the pingo machine and serviced concurrently on
the Python side (the `pingo` package's async driver), so one model round-trip
replaces many native tool calls.
"""

from __future__ import annotations

import inspect
import os
from dataclasses import dataclass
from typing import Any, Callable

from pydantic_ai import Agent, ModelRetry

from pingo import (
    INDEPENDENT,
    IRREVERSIBLE,
    ORDERED,
    PURE,
    RESOURCE,
    Batch,
    PingoError,
    Session,
)
from pingo.sexpr import UNSPECIFIED, dumps

DEFAULT_MODEL = os.environ.get("POC_MODEL", "openrouter:anthropic/claude-opus-5")

EFFECT_CLASSES = {
    "pure": PURE,
    "independent": INDEPENDENT,
    "resource": RESOURCE,
    "ordered": ORDERED,
    "irreversible": IRREVERSIBLE,
}


@dataclass
class SchemeTool:
    """A host tool exposed to the guest as a pingo capability."""

    name: str  # kebab-case, becomes the Scheme identifier
    fn: Callable[..., Any]  # sync or async; args/result must be pure data
    signature: str  # e.g. '(get-lat-lng city)'
    description: str
    effect_class: str = "independent"  # pure | independent | resource | ordered | irreversible


LANGUAGE_GUIDE = """\
You orchestrate tools by writing a single Scheme program for the `run_scheme`
tool. It runs on pingo, a pure R7RS-subset interpreter with opportunistic parallel
dispatch: tool calls whose arguments are ready are dispatched together, so
independent calls run concurrently without you asking for it. A tool call whose
argument is itself a pending tool result is parked and dispatched automatically
when the argument settles — plain nested composition already expresses a
pipeline. Prefer `(map (lambda (x) ...) items)` fan-out over sequential lets.

Language rules (deviations from full Scheme — follow strictly):
- pingo is PURE: there is no mutation. `set!`, `set-car!`, `set-cdr!`,
  `string-set!`, `vector-set!`, `string-fill!`, `vector-fill!` do NOT exist.
  Build new values (cons/list/append/string-append) and recurse or fold; never
  mutate. Data (pairs, strings, vectors) is immutable.
- To loop or accumulate WITHOUT `set!`, use the standard (R5RS/R7RS) pure
  idioms — a named `let`, `do`, `map`/`for-each`, or recursion. An accumulator
  is a loop parameter, not a mutated variable, e.g.
  `(let loop ((i 0) (acc 0)) (if (< i n) (loop (+ i 1) (+ acc i)) acc))`.
  Never reach for a mutable variable; there isn't one.
- Available forms: quote if define lambda begin let let* letrec (named let) do
  case cond and or when unless delay quasiquote define-syntax/syntax-rules
  let-values let*-values case-lambda define-record-type guard.
- Available primitives: pure numeric/list/string/char/vector/symbol library
  (+ - * / = < > <= >= quotient remainder modulo expt sqrt abs min max
  cons car cdr list append length reverse list-ref member assoc map for-each
  string-append substring string-length string->number number->string
  string=? string<? symbol->string vector-ref vector->list apply call/cc
  values ...). `map`/`for-each`/`do`/named `let` are standard (R5RS/R7RS).
  Plus list HOFs (R6RS/SRFI-1 extensions, also available): filter remove
  partition find fold-left fold-right for-all exists.
- Exceptions: raise, raise-continuable, with-exception-handler, and
  `(error "msg" irritant ...)`; catch with `guard`, e.g.
  `(guard (e (#t (list 'failed (error-object-message e)))) BODY)`. A caught
  failure (including a failed tool call) does not abort the program;
  error-object? / error-object-message / error-object-irritants inspect it.
- Regex (SRFI-115 SRE — patterns are s-expressions, not strings): sequence is
  `seq`, alternation `or`, repetition `* + ?`, named classes `num alpha alnum
  space`, ranges `(/ #\\a #\\z)`. e.g.
  `(regexp-search '(seq "id-" (+ num)) "id-123")`, `regexp-matches?`,
  `regexp-replace`, `regexp-match-submatch`.
- NOT available: any mutation (see above), display, newline, write, ports,
  exit, any I/O, JSON, hash tables, string-split. Do not use them.
- Only #f is false; 0, "" and '() are all true.
- Comments: only `;` to end of line. String escapes: only \\" \\\\ and \\n.
- Integers are exact i64 (overflow is an error); `/` yields a real unless it
  divides exactly — use `quotient` for integer division.
- `define` only at toplevel or at the start of a body.
- Operand order in a call is unspecified — but with no mutation that never
  matters; results depend only on data.
- Structured data is represented as alists: (("key" . value) ...). Look up
  with (cdr (assoc "key" alist)). Tool arguments and results are pure data
  only (numbers, strings, booleans, pairs/lists, vectors).
- The value of the LAST toplevel expression is the program's result — make it
  the complete answer (an alist or list with everything you need), since
  nothing else escapes the sandbox. A runtime error aborts the whole program.

Call the tools below like ordinary procedures, e.g. (get-lat-lng "Paris").
"""


def build_instructions(tools: list[SchemeTool]) -> str:
    catalog = "\n".join(
        f"- {t.signature} [{t.effect_class}]: {t.description}" for t in tools
    )
    return (
        LANGUAGE_GUIDE
        + "\nAvailable tools (already bound in the Scheme environment):\n"
        + catalog
        + "\n\nWrite ONE complete Scheme program per run_scheme call: gather all the"
        " data you need in it and return a final data structure, then answer the"
        " user from that result."
    )


async def execute_scheme(
    code: str,
    tools: list[SchemeTool],
    *,
    fuel: int = 10_000_000,
    call_depth: int = 1_000,
    on_batch: Callable[[Batch], None] | None = None,
) -> str:
    """Run one Scheme program against the given tools; return the result as
    s-expression text. Raises PingoError (with the failing tools' Python
    exceptions appended) on guest failure."""
    failures: list[str] = []
    async with Session(fuel=fuel, call_depth=call_depth) as sess:
        for t in tools:
            sess.define_async(t.name, _wrap(t, failures), cls=EFFECT_CLASSES[t.effect_class])
        try:
            value = await sess.run(code, on_batch=on_batch)
        except PingoError as e:
            message = str(e)
            if failures:
                message += " — failed tool calls: " + "; ".join(failures)
            raise PingoError(message) from e
    return "; unspecified" if value is UNSPECIFIED else dumps(value)


def _wrap(tool: SchemeTool, failures: list[str]) -> Callable[..., Any]:
    async def handler(*args: Any) -> Any:
        try:
            result = tool.fn(*args)
            if inspect.isawaitable(result):
                result = await result
            return result
        except Exception as e:
            failures.append(f"{tool.name}: {type(e).__name__}: {e}")
            raise

    return handler


def build_agent(
    tools: list[SchemeTool],
    model: str = DEFAULT_MODEL,
    fuel: int = 10_000_000,
    call_depth: int = 1_000,
    on_batch: Callable[[Batch], None] | None = None,
    on_code: Callable[[str], None] | None = None,
) -> Agent:
    """A pydantic-ai agent whose only tool is `run_scheme` over embedded pingo."""
    agent: Agent = Agent(model, instructions=build_instructions(tools), retries=3)

    @agent.tool_plain
    async def run_scheme(code: str) -> str:
        """Execute a Scheme program on the pingo interpreter and return the value
        of its last expression as s-expression text. The registered tools are
        available as procedures; independent calls run in parallel."""
        if on_code:
            on_code(code)
        try:
            return await execute_scheme(
                code, tools, fuel=fuel, call_depth=call_depth, on_batch=on_batch
            )
        except PingoError as e:
            raise ModelRetry(f"scheme error: {e}") from e

    return agent
