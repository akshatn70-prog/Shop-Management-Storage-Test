from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
import re
from typing import Any


@dataclass
class Product:
    name: str
    unit: str
    price_unit: str
    purchase_price: float
    selling_price: float
    stock_base: float = 0.0


@dataclass
class Account:
    name: str
    mobile: str
    balance: float = 0.0


@dataclass
class RunContext:
    session: Any
    run_id: str
    results: list[Any] = field(default_factory=list)
    products: dict[str, Product] = field(default_factory=dict)
    creditor: Account | None = None
    debtor: Account | None = None
    ids: dict[str, str] = field(default_factory=dict)
    owner: bool = True
    last_sale: dict[str, Any] | None = None
    last_cart: dict[str, Any] | None = None
    last_purchase: dict[str, Any] | None = None
    progress_callback: Any = None


def make_run_id(now: datetime | None = None) -> str:
    return (now or datetime.now().astimezone()).strftime("%Y%m%d-%H%M%S-%f")[:-3]


def unique_name(run_id: str, label: str) -> str:
    compact = re.sub(r"[^A-Za-z0-9]+", "-", label).strip("-")
    return f"RUN-{run_id}-{compact}"[:90]


def mobile_for(run_id: str, salt: str) -> str:
    digits = "".join(ch for ch in f"{run_id}{salt}" if ch.isdigit())
    return ("9" + digits[-9:]).ljust(10, "0")[:10]
