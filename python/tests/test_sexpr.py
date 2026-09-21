"""s-expression marshalling tests (no library needed)."""

import math

import pytest

from pingo import Char, Pair, Symbol, Vector, dumps, loads
from pingo.sexpr import UNSPECIFIED, SExprError


@pytest.mark.parametrize(
    "text,value",
    [
        ("42", 42),
        ("-7", -7),
        ("3.5", 3.5),
        ("4.0", 4.0),
        ("#t", True),
        ("#f", False),
        ('"hi"', "hi"),
        ('"a\\nb"', "a\nb"),
        ("foo", Symbol("foo")),
        ("()", []),
        ("(1 2 3)", [1, 2, 3]),
        ("(1 (2 3))", [1, [2, 3]]),
        ("#(1 2)", Vector([1, 2])),
        ("#\\a", Char("a")),
        ("#\\space", Char(" ")),
    ],
)
def test_loads(text, value):
    assert loads(text) == value


def test_dumps_roundtrip():
    for value in [42, -7, 3.5, True, False, "hi", Symbol("foo"), [1, [2, "x"]], Vector([1, 2])]:
        assert loads(dumps(value)) == value


def test_bool_before_int():
    assert dumps(True) == "#t"
    assert dumps(False) == "#f"
    assert dumps(1) == "1"


def test_dotted_pair():
    assert loads("(1 . 2)") == Pair(1, 2)
    assert dumps(Pair(1, 2)) == "(1 . 2)"


def test_reals():
    assert dumps(4.0) == "4.0"
    assert math.isinf(loads("+inf.0"))
    assert math.isnan(loads("+nan.0"))


def test_unspecified():
    assert loads("#<unspecified>") is UNSPECIFIED


def test_errors():
    with pytest.raises(SExprError):
        loads("(1 2")
    with pytest.raises(SExprError):
        loads("")
