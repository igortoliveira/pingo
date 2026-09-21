"""S-expression marshalling between Python objects and Pingo's text form.

The Pingo C API exchanges pure data as s-expression text (only pure data
crosses the host boundary, semantics S4). This module converts that text to and
from ordinary Python objects so callers never touch raw strings:

    Scheme            Python
    ------            ------
    integer           int
    real              float
    #t / #f           True / False
    "string"          str
    symbol            Symbol
    #\\c              Char
    (a b c)           list
    (a . b)           Pair
    #(a b c)          Vector
    ()                []

`loads` parses one datum from text; `dumps` renders a Python value. They are
inverses for the types above (a proper list round-trips to a list).
"""

from __future__ import annotations

import math
from dataclasses import dataclass


class Symbol(str):
    """A Scheme symbol. Subclasses str so it compares by name, but stays
    distinct from a Scheme string when rendering."""

    __slots__ = ()

    def __repr__(self) -> str:  # pragma: no cover - cosmetic
        return f"Symbol({str.__repr__(self)})"


@dataclass(frozen=True)
class Char:
    """A Scheme character (one byte in Pingo v0)."""

    value: str  # a length-1 string


@dataclass(frozen=True)
class Pair:
    """An improper (dotted) pair. Proper lists use Python lists instead."""

    car: object
    cdr: object


class Vector(list):
    """A Scheme vector `#(...)`. A list subclass so it behaves like a sequence
    but renders with the `#(` prefix."""

    __slots__ = ()


class Unspecified:
    """The unique unspecified value (e.g. the result of `define`)."""

    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __repr__(self) -> str:  # pragma: no cover - cosmetic
        return "Unspecified"


UNSPECIFIED = Unspecified()


class SExprError(ValueError):
    """Raised on malformed s-expression text."""


# -- writer ---------------------------------------------------------------

_STRING_ESCAPES = {'"': '\\"', "\\": "\\\\", "\n": "\\n"}


def dumps(value: object) -> str:
    """Render a Python value as s-expression text (re-readable by Pingo)."""
    # bool must precede int (bool is a subclass of int)
    if value is True:
        return "#t"
    if value is False:
        return "#f"
    if value is None or (isinstance(value, Unspecified)):
        return "()" if value is None else "#<unspecified>"
    if isinstance(value, Symbol):
        return str(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return _dump_real(value)
    if isinstance(value, str):
        return '"' + "".join(_STRING_ESCAPES.get(c, c) for c in value) + '"'
    if isinstance(value, Char):
        return _dump_char(value.value)
    if isinstance(value, Vector):
        return "#(" + " ".join(dumps(v) for v in value) + ")"
    if isinstance(value, (list, tuple)):
        return "(" + " ".join(dumps(v) for v in value) + ")"
    if isinstance(value, Pair):
        return f"({dumps(value.car)} . {dumps(value.cdr)})"
    raise SExprError(f"cannot render {type(value).__name__} as an s-expression")


def _dump_real(x: float) -> str:
    if math.isnan(x):
        return "+nan.0"
    if math.isinf(x):
        return "+inf.0" if x > 0 else "-inf.0"
    if x == int(x):
        return f"{int(x)}.0"
    return repr(x)


_CHAR_NAMES = {" ": "#\\space", "\n": "#\\newline", "\t": "#\\tab"}


def _dump_char(c: str) -> str:
    return _CHAR_NAMES.get(c, f"#\\{c}")


# -- reader ---------------------------------------------------------------

_NAMED_CHARS = {"space": " ", "newline": "\n", "tab": "\t"}


def loads(text: str) -> object:
    """Parse exactly one datum from `text`."""
    p = _Parser(text)
    p.skip_ws()
    if p.at_end():
        raise SExprError("empty input")
    value = p.read()
    p.skip_ws()
    if not p.at_end():
        raise SExprError("trailing data after datum")
    return value


class _Parser:
    def __init__(self, text: str):
        self.s = text
        self.i = 0

    def at_end(self) -> bool:
        return self.i >= len(self.s)

    def skip_ws(self) -> None:
        while self.i < len(self.s):
            c = self.s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif c == ";":
                while self.i < len(self.s) and self.s[self.i] != "\n":
                    self.i += 1
            else:
                break

    def read(self) -> object:
        self.skip_ws()
        if self.at_end():
            raise SExprError("unexpected end of input")
        c = self.s[self.i]
        if c == "(":
            return self._read_list(")")
        if c == ")":
            raise SExprError("unexpected )")
        if c == '"':
            return self._read_string()
        if c == "#":
            return self._read_hash()
        return self._read_atom()

    def _read_list(self, close: str) -> object:
        self.i += 1  # consume opener
        items: list[object] = []
        tail: object = None
        while True:
            self.skip_ws()
            if self.at_end():
                raise SExprError("unterminated list")
            if self.s[self.i] == close:
                self.i += 1
                break
            if self.s[self.i] == "." and self._dot_is_delimiter():
                self.i += 1
                tail = self.read()
                self.skip_ws()
                if self.at_end() or self.s[self.i] != close:
                    raise SExprError("malformed dotted pair")
                self.i += 1
                break
            items.append(self.read())
        if tail is not None:
            result: object = tail
            for item in reversed(items):
                result = Pair(item, result)
            return result
        return items

    def _dot_is_delimiter(self) -> bool:
        nxt = self.i + 1
        return nxt >= len(self.s) or self.s[nxt] in " \t\r\n()"

    def _read_string(self) -> str:
        self.i += 1  # opening quote
        out: list[str] = []
        while True:
            if self.at_end():
                raise SExprError("unterminated string")
            c = self.s[self.i]
            self.i += 1
            if c == '"':
                return "".join(out)
            if c == "\\":
                if self.at_end():
                    raise SExprError("dangling escape")
                e = self.s[self.i]
                self.i += 1
                out.append({"n": "\n", '"': '"', "\\": "\\", "t": "\t"}.get(e, e))
            else:
                out.append(c)

    def _read_hash(self) -> object:
        # self.s[self.i] == '#'
        rest = self.s[self.i:]
        if rest.startswith("#t"):
            self.i += 2
            return True
        if rest.startswith("#f"):
            self.i += 2
            return False
        if rest.startswith("#("):
            self.i += 1  # leave '(' for _read_list
            inner = self._read_list(")")
            if isinstance(inner, Pair):
                raise SExprError("dotted vector")
            return Vector(inner)
        if rest.startswith("#\\"):
            return self._read_char()
        if rest.startswith("#<"):
            # non-readable printed form (e.g. #<unspecified>) — consume a token
            token = self._token()
            return UNSPECIFIED if token == "#<unspecified>" else Symbol(token)
        raise SExprError(f"unknown # syntax at {rest[:4]!r}")

    def _read_char(self) -> Char:
        self.i += 2  # consume '#\'
        # a named char (letters) or a single character
        start = self.i
        if self.i < len(self.s) and self.s[self.i].isalpha():
            while self.i < len(self.s) and self.s[self.i].isalpha():
                self.i += 1
            name = self.s[start:self.i]
            if len(name) == 1:
                return Char(name)
            if name in _NAMED_CHARS:
                return Char(_NAMED_CHARS[name])
            raise SExprError(f"unknown char name {name!r}")
        if self.at_end():
            raise SExprError("dangling #\\")
        ch = self.s[self.i]
        self.i += 1
        return Char(ch)

    def _token(self) -> str:
        start = self.i
        while self.i < len(self.s) and self.s[self.i] not in " \t\r\n()":
            self.i += 1
        return self.s[start:self.i]

    def _read_atom(self) -> object:
        token = self._token()
        if not token:
            raise SExprError("empty token")
        return _atom(token)


def alist_get(alist: object, key: object, default: object = None) -> object:
    """Looks up `key` in a parsed association list — the guest's idiom for a
    structured record. Accepts both entry shapes Pingo's reader produces: a
    dotted pair `(key . value)` (a `Pair`) and a two-element list `(key value)`.
    Returns `default` when `alist` is not a list or the key is absent."""
    if isinstance(alist, list):
        for entry in alist:
            if isinstance(entry, Pair) and entry.car == key:
                return entry.cdr
            if isinstance(entry, list) and len(entry) == 2 and entry[0] == key:
                return entry[1]
    return default


def _atom(token: str) -> object:
    if token in ("+inf.0", "-inf.0"):
        return math.inf if token[0] == "+" else -math.inf
    if token in ("+nan.0", "-nan.0"):
        return math.nan
    try:
        return int(token)
    except ValueError:
        pass
    try:
        f = float(token)
        # only accept floats that actually look numeric (float("inf") etc. gone)
        return f
    except ValueError:
        return Symbol(token)
