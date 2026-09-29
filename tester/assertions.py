from __future__ import annotations

from dataclasses import dataclass
from typing import Any


class CheckFailed(AssertionError):
    pass


class SuiteBlocked(RuntimeError):
    pass


def money_close(actual: float, expected: float, tolerance: float = 0.01) -> None:
    if abs(float(actual) - float(expected)) > tolerance:
        raise CheckFailed(f"Expected ₹{expected:.2f}; found ₹{actual:.2f}.")


def equal(actual: Any, expected: Any, label: str = "value") -> None:
    if actual != expected:
        raise CheckFailed(f"Expected {label} {expected!r}; found {actual!r}.")


def contains(actual: str, expected: str, label: str = "text") -> None:
    if expected.casefold() not in actual.casefold():
        raise CheckFailed(f"Expected {label} to contain {expected!r}; found {actual!r}.")


def positive(value: float, label: str) -> None:
    if float(value) <= 0:
        raise CheckFailed(f"Expected {label} to be positive; found {value}.")
