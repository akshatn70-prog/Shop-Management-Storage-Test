from __future__ import annotations

from data_factory import Product, unique_name
from scenarios.common import ScenarioContext


async def create_product(
    ctx: ScenarioContext, key: str, unit: str, buy: float, sell: float, opening: float
) -> str:
    name = unique_name(ctx.run.run_id, key)
    await ctx.go("stock")
    await ctx.session.click(ctx.page.locator("#addProduct"))
    form = ctx.page.locator("#productForm")
    await form.wait_for(state="visible")
    await ctx.form_fill(form, "name", name)
    await ctx.form_select(form, "unit", unit)
    await ctx.form_fill(form, "qty", opening)
    await ctx.form_fill(form, "low", 0)
    await ctx.form_fill(form, "purchase", buy)
    await ctx.form_fill(form, "sale", sell)
    await ctx.form_select(form, "payment", "cash")
    await ctx.session.click(form.get_by_role("button", name="Add Product", exact=True))
    feedback = await ctx.wait_success()
    row = await ctx.wait_product(name)
    expected_stock = opening if unit in ("piece", "grams") else opening * 1000
    ctx.run.products[key] = Product(
        name=name,
        unit=unit,
        price_unit="piece" if unit == "piece" else ("kg" if unit == "kg" else "grams"),
        purchase_price=buy,
        selling_price=sell,
        stock_base=expected_stock,
    )
    stock = await ctx.stock(name)
    if abs(stock - expected_stock) > 0.001:
        raise AssertionError(f"Opening stock should be {expected_stock}; found {stock}.")
    return f"{row.strip()} | opening stock {stock}; feedback: {feedback}"


async def run(ctx: ScenarioContext) -> None:
    catalog = [("Piece", "piece"), ("Weight-Kg", "kg"), ("Weight-Gram", "grams")]
    remaining_units = ["piece"] * 31 + ["kg"] * 3 + ["grams"] * 3
    catalog.extend(
        (f"Product-{index:02d}", remaining_units[index - 4])
        for index in range(4, 41)
    )
    for index in range(1, 11):
        unit = "piece" if index < 9 else ("kg" if index == 9 else "grams")
        catalog.append((f"Cart-{index:02d}", unit))

    for key, unit in catalog:
        buy, sell = (0.42, 0.50) if unit == "grams" else (420, 500)
        await ctx.step(
            f"Products: create {key}",
            f"A unique {unit} product is created at its planned benchmark prices.",
            lambda key=key, unit=unit, buy=buy, sell=sell: create_product(ctx, key, unit, buy, sell, 0),
        )
    if len(ctx.run.products) != 50:
        raise AssertionError(f"Expected 50 created products; found {len(ctx.run.products)}.")
    await ctx.step(
        "Products: edit and restore a product price",
        "A price edit appears in Stock and the benchmark price is restored afterward.",
        lambda: edit_piece_price(ctx),
    )
    await ctx.step(
        "Products: delete a run-owned unused product",
        "Only this run's unused zero-stock product is removed from active Stock.",
        lambda: delete_unused_product(ctx),
    )


async def edit_piece_price(ctx: ScenarioContext) -> str:
    product = ctx.run.products.get("Piece")
    if not product:
        raise AssertionError("Piece product was not created.")
    await ctx.go("stock")
    row = ctx.page.get_by_role("row").filter(has_text=product.name)
    await ctx.session.click(row.get_by_role("button", name="Edit", exact=True))
    form = ctx.page.locator("#productEditForm")
    await form.wait_for(state="visible")
    await ctx.form_fill(form, "sale", 501)
    await ctx.session.click(form.get_by_role("button", name="Save Changes", exact=True))
    feedback = await ctx.wait_success("Product updated")
    product.selling_price = 501
    row_text = await ctx.wait_product_text_contains(product.name, "₹501.00")
    row = ctx.page.get_by_role("row").filter(has_text=product.name)
    await ctx.session.click(row.get_by_role("button", name="Edit", exact=True))
    form = ctx.page.locator("#productEditForm")
    await form.wait_for(state="visible")
    await ctx.form_fill(form, "sale", 500)
    await ctx.session.click(form.get_by_role("button", name="Save Changes", exact=True))
    restored_feedback = await ctx.wait_success("Product updated")
    product.selling_price = 500
    restored = await ctx.wait_product_text_contains(product.name, "₹500.00")
    return f"Edited: {row_text.strip()}; restored: {restored.strip()}; feedback: {feedback}, {restored_feedback}"


async def delete_unused_product(ctx: ScenarioContext) -> str:
    name = unique_name(ctx.run.run_id, "Delete-Only")
    await ctx.go("stock")
    await ctx.session.click(ctx.page.locator("#addProduct"))
    form = ctx.page.locator("#productForm")
    await form.wait_for(state="visible")
    await ctx.form_fill(form, "name", name)
    await ctx.form_select(form, "unit", "piece")
    await ctx.form_fill(form, "qty", 0)
    await ctx.form_fill(form, "low", 0)
    await ctx.form_fill(form, "purchase", 1)
    await ctx.form_fill(form, "sale", 2)
    await ctx.session.click(form.get_by_role("button", name="Add Product", exact=True))
    await ctx.wait_product(name)
    row = ctx.page.get_by_role("row").filter(has_text=name)
    ctx.session.confirm_next()
    await ctx.session.click(row.get_by_role("button", name="Delete", exact=True))
    feedback = await ctx.wait_success("Product deleted")
    await ctx.wait_product_gone(name)
    return f"{name} removed from active Stock; feedback: {feedback}"
