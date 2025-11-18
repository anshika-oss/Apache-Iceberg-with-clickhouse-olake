#!/bin/bash
# Performance comparison script with actual timing
# This script runs the same queries against raw, silver, and gold tables and shows execution times

echo "=== QUERY PERFORMANCE COMPARISON WITH TIMING ==="
echo ""
echo "Running the same query against all three layers..."
echo ""

QUERY="SELECT status, COUNT(*) AS orders, ROUND(AVG(total_amount), 2) AS avg_value FROM"

echo "--- RAW ICEBERG (REST Catalog) ---"
echo "Query: $QUERY iceberg_orders_lakehouse GROUP BY status"
echo ""
time docker exec -i clickhouse-server clickhouse-client --query "$QUERY iceberg_orders_lakehouse GROUP BY status ORDER BY orders DESC" --format=Pretty 2>&1 | head -20
echo ""

echo "--- SILVER (ClickHouse MergeTree) ---"
echo "Query: $QUERY ch_silver_orders GROUP BY status"
echo ""
time docker exec -i clickhouse-server clickhouse-client --query "$QUERY ch_silver_orders GROUP BY status ORDER BY orders DESC" --format=Pretty 2>&1 | head -20
echo ""

echo "--- GOLD (Pre-aggregated KPIs) ---"
echo "Query: SELECT status, SUM(order_count) AS orders, ROUND(AVG(avg_order_value), 2) AS avg_value FROM ch_gold_order_metrics GROUP BY status"
echo ""
time docker exec -i clickhouse-server clickhouse-client --query "SELECT status, SUM(order_count) AS orders, ROUND(AVG(avg_order_value), 2) AS avg_value FROM ch_gold_order_metrics GROUP BY status ORDER BY orders DESC" --format=Pretty 2>&1 | head -20
echo ""

echo "=== SUMMARY ==="
echo "The 'time' command shows:"
echo "  - real: Wall clock time (what you experience)"
echo "  - user: CPU time spent in user mode"
echo "  - sys: CPU time spent in system mode"
echo ""
echo "Expected differences with 10,000+ orders:"
echo "  - Raw Iceberg: 2-5 seconds (network I/O, Parquet parsing)"
echo "  - Silver: 50-200 milliseconds (local optimized storage)"
echo "  - Gold: 10-50 milliseconds (pre-aggregated metrics)"

