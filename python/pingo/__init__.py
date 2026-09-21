"""Pingo — an embeddable, sandboxed Scheme with an opportunistic effect model.

This package binds `libpingo` (the C API) via ctypes and marshals values as
Python objects. See `Session` for the two ways to run programs.

    from pingo import Session
    with Session() as s:
        s.define("greet", lambda who: f"hello {who}")
        print(s.eval('(greet "world")'))   # hello world
"""

from __future__ import annotations

from ._lib import (
    INDEPENDENT,
    IRREVERSIBLE,
    ORDERED,
    PURE,
    RESOURCE,
    LibraryNotFound,
)
from .session import PingoError, Session
from .sexpr import Char, Pair, SExprError, Symbol, Vector, dumps, loads

__all__ = [
    "Session",
    "PingoError",
    "LibraryNotFound",
    "Symbol",
    "Char",
    "Pair",
    "Vector",
    "SExprError",
    "dumps",
    "loads",
    "PURE",
    "INDEPENDENT",
    "RESOURCE",
    "ORDERED",
    "IRREVERSIBLE",
]
