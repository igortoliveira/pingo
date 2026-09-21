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
from .session import Batch, PingoError, Session
from .sexpr import Char, Pair, SExprError, Symbol, Vector, alist_get, dumps, loads

__all__ = [
    "Session",
    "Batch",
    "PingoError",
    "LibraryNotFound",
    "Symbol",
    "Char",
    "Pair",
    "Vector",
    "SExprError",
    "alist_get",
    "dumps",
    "loads",
    "PURE",
    "INDEPENDENT",
    "RESOURCE",
    "ORDERED",
    "IRREVERSIBLE",
]
