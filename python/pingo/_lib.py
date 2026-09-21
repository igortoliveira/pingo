"""ctypes bindings for libpingo (the Pingo C API, include/pingo.h).

Loading order for the shared library:
  1. the `PINGO_LIB` environment variable, if set (a full path);
  2. `zig-out/lib/` in the repository this package lives in;
  3. the system loader (`ctypes.util.find_library("pingo")`).
"""

from __future__ import annotations

import ctypes
import ctypes.util
import os
import sys
from pathlib import Path

# Effect classes (must match capability.EffectClass / the PINGO_* header macros).
PURE = 0
INDEPENDENT = 1
RESOURCE = 2
ORDERED = 3
IRREVERSIBLE = 4

# Status codes returned by feed/continue.
VALUE = 0
BLOCKED = 1
ERROR = 2

# Signature of a synchronous capability handler: (user, args) -> result address
# or None. The result is returned as c_void_p (an address of a caller-kept
# buffer) rather than c_char_p, so ctypes does not warn about leaking a Python
# bytes it cannot free; None becomes NULL, which the C side reads as a failure.
HANDLER = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p)


def _lib_filename() -> str:
    if sys.platform == "darwin":
        return "libpingo.dylib"
    if sys.platform in ("win32", "cygwin"):
        return "pingo.dll"
    return "libpingo.so"


def _candidate_paths() -> list[str]:
    paths: list[str] = []
    env = os.environ.get("PINGO_LIB")
    if env:
        paths.append(env)
    # walk up from this file looking for zig-out/lib
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "zig-out" / "lib" / _lib_filename()
        if candidate.exists():
            paths.append(str(candidate))
            break
    found = ctypes.util.find_library("pingo")
    if found:
        paths.append(found)
    return paths


class LibraryNotFound(RuntimeError):
    pass


def load() -> ctypes.CDLL:
    """Loads libpingo and declares the C signatures. Raises LibraryNotFound
    with the searched locations if it cannot be found (build it with
    `zig build`)."""
    tried = _candidate_paths()
    lib = None
    for path in tried:
        try:
            lib = ctypes.CDLL(path)
            break
        except OSError:
            continue
    if lib is None:
        raise LibraryNotFound(
            "could not load libpingo; set PINGO_LIB or run `zig build`. "
            f"Tried: {tried or '(nothing found)'}"
        )
    _declare(lib)
    return lib


def _declare(lib: ctypes.CDLL) -> None:
    P = ctypes.c_void_p
    cstr = ctypes.c_char_p

    lib.pingo_new.restype = P
    lib.pingo_new.argtypes = [ctypes.c_uint64, ctypes.c_size_t, ctypes.c_size_t]

    lib.pingo_free.restype = None
    lib.pingo_free.argtypes = [P]

    lib.pingo_register.restype = ctypes.c_int
    lib.pingo_register.argtypes = [P, cstr, ctypes.c_int]

    lib.pingo_feed.restype = ctypes.c_int
    lib.pingo_feed.argtypes = [P, cstr]

    lib.pingo_continue.restype = ctypes.c_int
    lib.pingo_continue.argtypes = [P]

    lib.pingo_result.restype = cstr
    lib.pingo_result.argtypes = [P]

    lib.pingo_error.restype = cstr
    lib.pingo_error.argtypes = [P]

    lib.pingo_outstanding_count.restype = ctypes.c_size_t
    lib.pingo_outstanding_count.argtypes = [P]

    lib.pingo_call_token.restype = ctypes.c_uint64
    lib.pingo_call_token.argtypes = [P, ctypes.c_size_t]

    lib.pingo_call_name.restype = cstr
    lib.pingo_call_name.argtypes = [P, ctypes.c_uint64]

    lib.pingo_call_args.restype = cstr
    lib.pingo_call_args.argtypes = [P, ctypes.c_uint64]

    lib.pingo_resolve.restype = ctypes.c_int
    lib.pingo_resolve.argtypes = [P, ctypes.c_uint64, cstr]

    lib.pingo_resolve_failure.restype = ctypes.c_int
    lib.pingo_resolve_failure.argtypes = [P, ctypes.c_uint64]

    lib.pingo_register_fn.restype = ctypes.c_int
    lib.pingo_register_fn.argtypes = [P, cstr, ctypes.c_int, HANDLER, ctypes.c_void_p]

    lib.pingo_eval.restype = cstr
    lib.pingo_eval.argtypes = [P, cstr]

    lib.pingo_version.restype = cstr
    lib.pingo_version.argtypes = []
