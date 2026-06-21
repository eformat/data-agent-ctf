#!/usr/bin/env python3
"""Load retail sample data into live Trino Iceberg tables.

Usage:
    # Via port-forward:
    oc port-forward svc/trino 18080:8080 -n trino &
    python3 examples/retail/deploy/trino/load-data.py --host localhost --port 18080

    # Via Route:
    python3 examples/retail/deploy/trino/load-data.py --host trino-trino.apps.example.com --port 80
"""

import argparse
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..', '..', 'src'))

from trino.dbapi import connect

from data_agent_core.testing.retail_sample_data import (
    REGIONS, PRODUCT_LINES, DEPARTMENTS, EXPENSE_CATEGORIES,
    CHANNELS, CARRIERS, WAREHOUSES, SEGMENTS, RETURN_REASONS,
    PIPELINE_STAGES,
    _REGION_WEIGHTS, _PRODUCT_WEIGHTS, _MONTHLY_BASE,
    _SEASONALITY, _GROWTH, _MARGINS,
)


def load_finance(conn):
    cur = conn.cursor()

    # Revenue
    rows = 0
    for year in range(2021, 2026):
        values = []
        for month in range(1, 13):
            for region in REGIONS:
                for pl in PRODUCT_LINES:
                    base = _MONTHLY_BASE * _REGION_WEIGHTS[region] * _PRODUCT_WEIGHTS[pl]
                    val = round(base * _SEASONALITY[month] * _GROWTH[year], 1)
                    values.append(f"({year}, {month}, '{region}', '{pl}', {val})")
                    rows += 1
        cur.execute(f"INSERT INTO finance.analytics.revenue VALUES {', '.join(values)}")
    print(f"  revenue: {rows} rows")

    # Expenses
    _dept_weights = {"Operations": 0.40, "Sales": 0.25, "Marketing": 0.15, "Finance": 0.10, "Technology": 0.10}
    _cat_weights = {"payroll": 0.50, "logistics": 0.20, "technology": 0.12, "marketing": 0.10, "facilities": 0.08}
    monthly_expense_base = 2_900_000
    rows = 0
    for year in range(2021, 2026):
        values = []
        for month in range(1, 13):
            for dept in DEPARTMENTS:
                for cat in EXPENSE_CATEGORIES:
                    val = round(monthly_expense_base * _dept_weights[dept] * _cat_weights[cat] * _GROWTH[year], 1)
                    values.append(f"({year}, {month}, '{dept}', '{cat}', {val})")
                    rows += 1
        cur.execute(f"INSERT INTO finance.analytics.expenses VALUES {', '.join(values)}")
    print(f"  expenses: {rows} rows")

    # Margins
    rows = 0
    values = []
    for year in range(2021, 2026):
        for quarter in range(1, 5):
            for pl in PRODUCT_LINES:
                q_months = range(quarter * 3 - 2, quarter * 3 + 1)
                q_rev = sum(
                    _MONTHLY_BASE * sum(_REGION_WEIGHTS.values()) * _PRODUCT_WEIGHTS[pl]
                    * _SEASONALITY[m] * _GROWTH[year]
                    for m in q_months
                )
                margin = _MARGINS[pl]
                cogs = round(q_rev * (1 - margin), 1)
                q_rev = round(q_rev, 1)
                margin_pct = round(margin * 100, 2)
                values.append(f"({year}, {quarter}, '{pl}', {q_rev}, {cogs}, {margin_pct})")
                rows += 1
    cur.execute(f"INSERT INTO finance.analytics.margins VALUES {', '.join(values)}")
    print(f"  margins: {rows} rows")

    # Forecasts
    _variance = {
        (2021, 1): -2.1, (2021, 2): 1.5, (2021, 3): -0.8, (2021, 4): 3.2,
        (2022, 1): -1.4, (2022, 2): 2.8, (2022, 3): 0.5, (2022, 4): 4.1,
        (2023, 1): -3.2, (2023, 2): -0.9, (2023, 3): 1.2, (2023, 4): 2.5,
        (2024, 1): -1.8, (2024, 2): 0.7, (2024, 3): -0.3, (2024, 4): 3.8,
        (2025, 1): -2.5, (2025, 2): 1.1, (2025, 3): 0.9, (2025, 4): 2.2,
    }
    rows = 0
    values = []
    for year in range(2021, 2026):
        for quarter in range(1, 5):
            for region in REGIONS:
                q_months = range(quarter * 3 - 2, quarter * 3 + 1)
                actual = round(sum(
                    _MONTHLY_BASE * _REGION_WEIGHTS[region] * _SEASONALITY[m] * _GROWTH[year]
                    for m in q_months
                ), 1)
                var_pct = _variance.get((year, quarter), 0.0)
                target = round(actual * (1 + var_pct / 100), 1)
                values.append(f"({year}, {quarter}, '{region}', {target}, {actual}, {var_pct})")
                rows += 1
    cur.execute(f"INSERT INTO finance.analytics.forecasts VALUES {', '.join(values)}")
    print(f"  forecasts: {rows} rows")


def load_sales(conn):
    cur = conn.cursor()

    # Orders
    order_count = 0
    _channel_weights = [("retail", 0.40), ("online", 0.35), ("wholesale", 0.15), ("marketplace", 0.10)]
    for year in range(2021, 2026):
        values = []
        for month in range(1, 13):
            base_orders = 8
            seasonal = _SEASONALITY[month]
            n_orders = int(base_orders * seasonal)
            for i in range(n_orders):
                order_count += 1
                oid = f"ORD-{year}{month:02d}-{order_count:05d}"
                cid = f"CUST-{(order_count * 7 + i) % 200 + 1:04d}"
                region = REGIONS[order_count % len(REGIONS)]
                pl = PRODUCT_LINES[order_count % len(PRODUCT_LINES)]
                qty = (order_count % 5) + 1
                rev = round(qty * (50 + (order_count % 200) * 2.5), 2)
                ch = _channel_weights[order_count % len(_channel_weights)][0]
                day = min((order_count % 28) + 1, 28)
                values.append(f"('{oid}', DATE '{year}-{month:02d}-{day:02d}', '{cid}', '{region}', '{pl}', {qty}, {rev}, '{ch}')")
        cur.execute(f"INSERT INTO sales.analytics.orders VALUES {', '.join(values)}")
    print(f"  orders: {order_count} rows")

    # Pipeline
    _stage_prob = {"Prospect": 10, "Qualified": 25, "Proposal": 50, "Negotiation": 75, "Closed Won": 100}
    reps = ["Alice Chen", "Bob Martinez", "Carol Kim", "Dave Patel", "Eva Johansson"]
    values = []
    for i in range(50):
        opp_id = f"OPP-{i+1:04d}"
        stage = PIPELINE_STAGES[i % len(PIPELINE_STAGES)]
        prob = _stage_prob[stage]
        expected_rev = round(50000 + (i * 7919) % 450000, 2)
        rep = reps[i % len(reps)]
        region = REGIONS[i % len(REGIONS)]
        year = 2023 + (i % 3)
        month = (i % 12) + 1
        day = min((i % 28) + 1, 28)
        close_month = min(month + 3, 12)
        values.append(f"('{opp_id}', '{stage}', {prob}, {expected_rev}, '{rep}', '{region}', DATE '{year}-{month:02d}-{day:02d}', DATE '{year}-{close_month:02d}-28')")
    cur.execute(f"INSERT INTO sales.analytics.pipeline VALUES {', '.join(values)}")
    print(f"  pipeline: 50 rows")

    # Customers
    values = []
    for i in range(200):
        cid = f"CUST-{i+1:04d}"
        segment = SEGMENTS[i % len(SEGMENTS)]
        region = REGIONS[i % len(REGIONS)]
        year = 2019 + (i % 7)
        month = (i % 12) + 1
        ltv = round(1000 + (i * 3571) % 99000, 2)
        ch = CHANNELS[i % len(CHANNELS)]
        values.append(f"('{cid}', '{segment}', '{region}', DATE '{year}-{month:02d}-15', {ltv}, '{ch}')")
    cur.execute(f"INSERT INTO sales.analytics.customers VALUES {', '.join(values)}")
    print(f"  customers: 200 rows")

    # Acquisition costs
    _channel_spend = {"retail": 800, "online": 1200, "wholesale": 400, "marketplace": 600}
    _channel_new_cust = {"retail": 120, "online": 200, "wholesale": 40, "marketplace": 80}
    values = []
    rows = 0
    for year in range(2021, 2026):
        for quarter in range(1, 5):
            for ch in CHANNELS:
                spend = round(_channel_spend[ch] * _GROWTH[year], 1)
                new_cust = int(_channel_new_cust[ch] * _GROWTH[year])
                cac = round(spend * 1000 / new_cust, 2) if new_cust > 0 else 0
                values.append(f"({year}, {quarter}, '{ch}', {spend}, {new_cust}, {cac})")
                rows += 1
    cur.execute(f"INSERT INTO sales.analytics.acquisition_costs VALUES {', '.join(values)}")
    print(f"  acquisition_costs: {rows} rows")


def load_ops(conn):
    cur = conn.cursor()

    # Inventory
    skus = [f"SKU-{i+1:04d}" for i in range(100)]
    values = []
    for sku in skus:
        for wh in WAREHOUSES:
            sku_num = int(sku.split("-")[1])
            qty = 50 + (sku_num * 37 + hash(wh)) % 950
            reorder = 100 + (sku_num * 13) % 200
            dos = round(qty / max(reorder / 7, 1), 1)
            values.append(f"(DATE '2025-01-15', '{sku}', '{wh}', {qty}, {reorder}, {dos})")
    cur.execute(f"INSERT INTO ops.analytics.inventory VALUES {', '.join(values)}")
    print(f"  inventory: {len(values)} rows")

    # Shipments
    statuses = ["delivered"] * 85 + ["in_transit"] * 10 + ["exception"] * 5
    values = []
    for i in range(300):
        sid = f"SHP-{i+1:06d}"
        oid = f"ORD-{2024}{(i%12)+1:02d}-{(i%500)+1:05d}"
        wh = WAREHOUSES[i % len(WAREHOUSES)]
        carrier = CARRIERS[i % len(CARRIERS)]
        year = 2024 + (i // 200)
        month = (i % 12) + 1
        day = min((i % 28) + 1, 28)
        transit = 2 + (i % 5)
        status = statuses[i % len(statuses)]
        del_day = min(day + transit, 28)
        values.append(f"('{sid}', '{oid}', '{wh}', '{carrier}', DATE '{year}-{month:02d}-{day:02d}', DATE '{year}-{month:02d}-{del_day:02d}', {transit}, '{status}')")
    cur.execute(f"INSERT INTO ops.analytics.shipments VALUES {', '.join(values)}")
    print(f"  shipments: 300 rows")

    # Warehouses
    _wh_capacity = {
        "DC-Northeast": 12000, "DC-Southeast": 15000, "DC-Midwest": 10000,
        "DC-West": 18000, "DC-International": 8000,
    }
    _wh_region = {
        "DC-Northeast": "Northeast", "DC-Southeast": "Southeast", "DC-Midwest": "Midwest",
        "DC-West": "West", "DC-International": "International",
    }
    values = []
    for wh in WAREHOUSES:
        for year in range(2021, 2026):
            for month in range(1, 13):
                cap = _wh_capacity[wh]
                util = round(65 + _SEASONALITY[month] * 20 + (year - 2021) * 1.5, 2)
                util = min(util, 98.0)
                cost = round(cap * 0.08 * _GROWTH[year], 1)
                values.append(f"('{wh}', '{_wh_region[wh]}', {year}, {month}, {cap}, {util}, {cost})")
    cur.execute(f"INSERT INTO ops.analytics.warehouses VALUES {', '.join(values)}")
    print(f"  warehouses: {len(values)} rows")

    # Returns
    values = []
    for i in range(80):
        rid = f"RET-{i+1:05d}"
        oid = f"ORD-{2024}{(i%12)+1:02d}-{(i%500)+1:05d}"
        sku = skus[i % len(skus)]
        month = (i % 12) + 1
        day = min((i % 28) + 1, 28)
        reason = RETURN_REASONS[i % len(RETURN_REASONS)]
        refund = round(25 + (i * 31) % 475, 2)
        values.append(f"('{rid}', '{oid}', '{sku}', DATE '2024-{month:02d}-{day:02d}', '{reason}', {refund})")
    cur.execute(f"INSERT INTO ops.analytics.returns VALUES {', '.join(values)}")
    print(f"  returns: 80 rows")


def main():
    parser = argparse.ArgumentParser(description="Load retail sample data into Trino")
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--user", default="prelude")
    args = parser.parse_args()

    print(f"Connecting to Trino at {args.host}:{args.port} as {args.user}")

    print("\n=== Loading finance data ===")
    conn = connect(host=args.host, port=args.port, user=args.user, catalog="finance")
    load_finance(conn)
    conn.close()

    print("\n=== Loading sales data ===")
    conn = connect(host=args.host, port=args.port, user=args.user, catalog="sales")
    load_sales(conn)
    conn.close()

    print("\n=== Loading ops data ===")
    conn = connect(host=args.host, port=args.port, user=args.user, catalog="ops")
    load_ops(conn)
    conn.close()

    print("\n=== Done ===")


if __name__ == "__main__":
    main()
