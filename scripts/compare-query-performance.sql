-- Compare Query Performance: Raw Iceberg vs Optimized Silver/Gold Tables
-- This script demonstrates the performance difference between querying raw Iceberg tables
-- (via REST catalog) and ClickHouse-optimized MergeTree tables (silver/gold layers)
--
-- Usage: docker exec -i clickhouse-server clickhouse-client < scripts/compare-query-performance.sql
-- Or: docker exec -it clickhouse-client clickhouse-client

SELECT '=== QUERY PERFORMANCE COMPARISON ===' AS title;
SELECT 'Comparing Raw Iceberg (REST Catalog) vs Optimized ClickHouse Tables' AS description;
SELECT '';

-- Test 1: Simple aggregation by status
SELECT '--- Test 1: Orders by Status (Simple Aggregation) ---' AS test;

SELECT 'RAW ICEBERG (REST Catalog) - Querying from MinIO via REST API' AS layer;
SELECT 
    status,
    COUNT(*) AS order_count,
    ROUND(AVG(total_amount), 2) AS avg_order_value,
    ROUND(SUM(total_amount), 2) AS total_revenue
FROM iceberg_orders_lakehouse
GROUP BY status
ORDER BY order_count DESC
SETTINGS max_execution_time = 300;

SELECT 'SILVER (ClickHouse MergeTree) - Optimized local table' AS layer;
SELECT 
    status,
    COUNT(*) AS order_count,
    ROUND(AVG(total_amount), 2) AS avg_order_value,
    ROUND(SUM(total_amount), 2) AS total_revenue
FROM ch_silver_orders
GROUP BY status
ORDER BY order_count DESC;

SELECT 'GOLD (Pre-aggregated KPIs) - Fastest, pre-computed metrics' AS layer;
SELECT 
    status,
    SUM(order_count) AS total_orders,
    ROUND(AVG(avg_order_value), 2) AS avg_order_value,
    ROUND(SUM(gross_revenue), 2) AS total_revenue
FROM ch_gold_order_metrics
GROUP BY status
ORDER BY total_orders DESC;

SELECT '';

-- Test 2: Time-based filtering and aggregation
SELECT '--- Test 2: Monthly Revenue Trends (Time-based Query) ---' AS test;

SELECT 'RAW ICEBERG (REST Catalog)' AS layer;
SELECT 
    toYYYYMM(order_date) AS order_month,
    status,
    COUNT(*) AS order_count,
    ROUND(SUM(total_amount), 2) AS monthly_revenue
FROM iceberg_orders_lakehouse
WHERE order_date >= today() - INTERVAL 12 MONTH
GROUP BY order_month, status
ORDER BY order_month DESC, status
SETTINGS max_execution_time = 300;

SELECT 'SILVER (ClickHouse MergeTree)' AS layer;
SELECT 
    toYYYYMM(order_date) AS order_month,
    status,
    COUNT(*) AS order_count,
    ROUND(SUM(total_amount), 2) AS monthly_revenue
FROM ch_silver_orders
WHERE order_date >= today() - INTERVAL 12 MONTH
GROUP BY order_month, status
ORDER BY order_month DESC, status;

SELECT 'GOLD (Pre-aggregated)' AS layer;
SELECT 
    toYYYYMM(order_month) AS order_month,
    status,
    SUM(order_count) AS total_orders,
    ROUND(SUM(gross_revenue), 2) AS monthly_revenue
FROM ch_gold_order_metrics
WHERE order_month >= today() - INTERVAL 12 MONTH
GROUP BY order_month, status
ORDER BY order_month DESC, status;

SELECT '';

-- Test 3: Complex filtering with multiple conditions
SELECT '--- Test 3: High-Value Orders Analysis (Complex Filtering) ---' AS test;

SELECT 'RAW ICEBERG (REST Catalog)' AS layer;
SELECT 
    status,
    COUNT(*) AS high_value_orders,
    ROUND(AVG(total_amount), 2) AS avg_amount,
    ROUND(MAX(total_amount), 2) AS max_amount
FROM iceberg_orders_lakehouse
WHERE total_amount > 1000 
  AND status IN ('delivered', 'shipped')
  AND order_date >= today() - INTERVAL 6 MONTH
GROUP BY status
ORDER BY high_value_orders DESC
SETTINGS max_execution_time = 300;

SELECT 'SILVER (ClickHouse MergeTree)' AS layer;
SELECT 
    status,
    COUNT(*) AS high_value_orders,
    ROUND(AVG(total_amount), 2) AS avg_amount,
    ROUND(MAX(total_amount), 2) AS max_amount
FROM ch_silver_orders
WHERE total_amount > 1000 
  AND status IN ('delivered', 'shipped')
  AND order_date >= today() - INTERVAL 6 MONTH
GROUP BY status
ORDER BY high_value_orders DESC;

SELECT '';

-- Test 4: Count distinct users
SELECT '--- Test 4: Unique Customers per Status (Distinct Count) ---' AS test;

SELECT 'RAW ICEBERG (REST Catalog)' AS layer;
SELECT 
    status,
    COUNT(*) AS order_count,
    uniqExact(user_id) AS unique_customers,
    ROUND(COUNT(*) / NULLIF(uniqExact(user_id), 0), 2) AS avg_orders_per_customer
FROM iceberg_orders_lakehouse
GROUP BY status
ORDER BY order_count DESC
SETTINGS max_execution_time = 300;

SELECT 'SILVER (ClickHouse MergeTree)' AS layer;
SELECT 
    status,
    COUNT(*) AS order_count,
    uniqExact(user_id) AS unique_customers,
    ROUND(COUNT(*) / NULLIF(uniqExact(user_id), 0), 2) AS avg_orders_per_customer
FROM ch_silver_orders
GROUP BY status
ORDER BY order_count DESC;

SELECT 'GOLD (Pre-aggregated)' AS layer;
SELECT 
    status,
    SUM(order_count) AS total_orders,
    SUM(user_count) AS unique_customers,
    ROUND(SUM(order_count) / NULLIF(SUM(user_count), 0), 2) AS avg_orders_per_customer
FROM ch_gold_order_metrics
GROUP BY status
ORDER BY total_orders DESC;

SELECT '';

-- Performance summary and recommendations
SELECT '=== PERFORMANCE SUMMARY ===' AS summary;
SELECT 'RAW ICEBERG (REST Catalog):' AS layer,
       'Slower - Queries MinIO via REST API, reads Parquet files, no local caching' AS characteristics;
SELECT 'SILVER (MergeTree):' AS layer,
       'Faster - ClickHouse-optimized columnar format, local storage, compression' AS characteristics;
SELECT 'GOLD (Pre-aggregated):' AS layer,
       'Fastest - Pre-computed metrics, minimal computation needed' AS characteristics;

SELECT '';
SELECT '=== GOLD TABLE KPIs EXPLAINED ===' AS kpi_section;
SELECT 'The ch_gold_order_metrics table contains pre-aggregated Key Performance Indicators:' AS info;
SELECT '  - order_month: Month of the order' AS kpi;
SELECT '  - status: Order status (pending, confirmed, shipped, delivered, cancelled)' AS kpi;
SELECT '  - user_count: Number of unique customers (uniqExact)' AS kpi;
SELECT '  - order_count: Total number of orders' AS kpi;
SELECT '  - gross_revenue: Total revenue (sum of total_amount)' AS kpi;
SELECT '  - avg_order_value: Average order value (gross_revenue / order_count)' AS kpi;
SELECT 'These KPIs are pre-computed from the silver layer, enabling instant dashboard queries.' AS note;

SELECT '';
SELECT '=== RECOMMENDATIONS ===' AS recommendations;
SELECT '1. Use RAW Iceberg for: Ad-hoc exploration, schema evolution, time travel queries' AS tip;
SELECT '2. Use SILVER for: Frequent analytical queries, real-time dashboards, complex joins' AS tip;
SELECT '3. Use GOLD for: KPIs, executive dashboards, scheduled reports, high-frequency metrics' AS tip;
SELECT '4. Refresh silver/gold tables periodically or via triggers when new data arrives' AS tip;

