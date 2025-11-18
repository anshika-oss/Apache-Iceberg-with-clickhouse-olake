Building a Data Lakehouse with Apache Iceberg, ClickHouse and OLake
=====================================================================

I wanted a self-contained way to show how OLake’s UI can replicate data from MySQL into Apache Iceberg tables stored in MinIO and how ClickHouse can immediately query those tables through the Iceberg table engine. This walkthrough documents every step and references the configs/scripts bundled in this repo so that you can reproduce the pipeline on any laptop with Docker.

You will:

* Spin up MySQL, MinIO, ClickHouse, and helper clients with Docker Compose.
* Launch **OLake UI** as a separate stack (includes PostgreSQL, Temporal, Elasticsearch) and connect it to our network.
* Use **OLake UI** to register a CDC-enabled MySQL source, define an Iceberg-on-MinIO destination, and activate a pipeline that writes to a `demo_lakehouse` namespace.
* Map the Iceberg tables into ClickHouse using the Iceberg REST catalog and run analytics comparing raw Iceberg data with optimized Silver/Gold layers.

---

Table of Contents
-----------------

1. [Architecture at a Glance](#architecture-at-a-glance)
2. [Clone the Repo & Understand the Layout](#clone-the-repo--understand-the-layout)
3. [Bring Up the Core Services](#bring-up-the-core-services)
4. [Seed MySQL with Demo Data](#seed-mysql-with-demo-data)
5. [Prepare ClickHouse for Iceberg](#prepare-clickhouse-for-iceberg)
6. [Configure OLake UI (Source + Destination)](#configure-olake-ui-source--destination)
7. [Create and Run the OLake UI Pipeline](#create-and-run-the-olake-ui-pipeline)
8. [Hands-on Checklist](#hands-on-checklist)
9. [Query Iceberg Tables using ClickHouse](#query-iceberg-tables-from-clickhouse)
10. [Raw vs Optimized Analytics & Time Travel](#raw-vs-optimized-analytics--time-travel)
11. [Schema Evolution and Testing Changes](#schema-evolution-and-testing-changes)
12. [Troubleshooting Checklist](#troubleshooting-checklist)
13. [Where to Go Next](#where-to-go-next)

---

Architecture at a Glance
------------------------

```
┌───────────┐  Binlog CDC   ┌────────────┐   Iceberg files   ┌────────────┐
│  MySQL    │──────────────▶│  OLake UI  │──────────────────▶│  MinIO +   │
│  (OLTP)   │               │ (pipelines)│                   │ Apache     │
└───────────┘               └────────────┘                   │ Iceberg    │
                                                                 │
                                                                 │
                                                        ┌────────┴────────┐
                                                        │ Iceberg REST     │
                                                        │ Catalog (OLake)  │
                                                        └────────┬────────┘
                                                                 │
                                                          ClickHouse (Iceberg
                                                          REST + Silver/Gold)
```

* **MySQL 8.0** – Operational workload with realistic sample data, GTID + binlog enabled for CDC.
* **OLake UI** – Low-code interface for defining CDC pipelines that output Iceberg tables.
* **MinIO** – S3-compatible object store acting as the Iceberg warehouse.
* **ClickHouse** – Queries Iceberg data via the IcebergS3 engine.

---

Clone the Repo & Understand the Layout
--------------------------------------

```bash
git clone https://github.com/sandeep-devarapalli/Apache-Iceberg-with-clickhouse-olake.git
cd Apache-Iceberg-with-clickhouse-olake
tree -F -L 1
```

Directory highlights:

* `docker-compose.yml` – orchestrates every service (MySQL, MinIO, ClickHouse, OLake UI dependencies, helper clients).
* `mysql-init/` – DDL + seed data executed automatically for the demo schema.
* `clickhouse-config/` – server + user configs that enable the Iceberg feature flags.
* `olake-config/OLAKE_UI_PIPELINE.md` – UI runbook with all the field values you’ll type.
* `scripts/` – SQL helpers (`mysql-integration.sql` now acts as an Iceberg REST smoke test, plus `iceberg-setup.sql` & `cross-database-analytics.sql`).

---

Bring Up the Core Services
--------------------------

First, start the data plane services (MySQL, MinIO, ClickHouse, PostgreSQL, helper clients):

```bash
docker-compose up -d
docker-compose ps
```

| Service | Purpose | Host Access |
|---------|---------|-------------|
| `mysql-server` | Source OLTP DB | `localhost:3307` |
| `minio-server` | S3-compatible storage | API `http://localhost:9090`, Console `http://localhost:9091` |
| `clickhouse-server` | Query engine | HTTP `http://localhost:8123`, Native `localhost:19000` |
| `clickhouse-client`, `mysql-client`, `minio-client` | Utility containers | used for scripts |

**Note:** OLake UI runs as a separate stack with its own PostgreSQL, Temporal, and Elasticsearch services.

---

Launch OLake UI
---------------

**Important:** OLake UI is a complete, self-contained Docker Compose stack that includes:
- OLake UI (web interface)
- Temporal Worker (background jobs)
- PostgreSQL (for OLake's own metadata and job state)
- Temporal Server (workflow orchestration)
- Temporal UI (workflow monitoring)
- Elasticsearch (Temporal search backend)

According to the [OLake UI QuickStart guide](https://olake.io/docs/getting-started/quickstart/), start it with:

```bash
# Start OLake UI (this creates its own network and all services)
curl -sSL https://raw.githubusercontent.com/datazip-inc/olake-ui/master/docker-compose.yml | docker compose -f - up -d
```

**Connect OLake UI to our network:**

OLake UI runs in its own Docker network. To allow it to reach our MySQL and MinIO services, we need to connect the OLake UI container to our network:

```bash
# Find the OLake UI container name
OLAKE_CONTAINER=$(docker ps --filter "name=olake-ui" --format "{{.Names}}" | head -1)

# Auto-detect our network name (based on directory name)
NETWORK_NAME=$(docker network ls --filter "name=clickhouse_lakehouse-net" --format "{{.Name}}" | head -1)

# Connect to our network
docker network connect $NETWORK_NAME $OLAKE_CONTAINER

echo "Connected $OLAKE_CONTAINER to network $NETWORK_NAME"
```

**Access OLake UI:**
- **URL**: http://localhost:8000
- **Default credentials**: `admin` / `password`

**Important:** When configuring sources/destinations in OLake UI, use these Docker hostnames:
- **MySQL**: `mysql:3306` (not localhost:3307)
- **MinIO**: `minio:9000` (not localhost:9090)
- **MinIO Console**: `http://minio:9000` for API, `http://minio:9091` for console

OLake UI manages its own PostgreSQL for job metadata, so you don't need to configure a separate database connection.

---

Seed MySQL with Demo Data
-------------------------

The MySQL container automatically executes:

* `mysql-init/01-setup.sql` – creates the `demo_db` schema (`users`, `products`, `orders`, `user_sessions`) and inserts realistic sample data.
* `mysql-init/02-permissions.sql` – creates integration users:
  * `olake / olake_pass` (CDC + replication privileges).
  * `clickhouse / clickhouse_pass` (direct query access).

Verify counts:

```bash
docker exec -it mysql-server mysql -u demo_user -pdemo_password -e "USE demo_db; SELECT COUNT(*) AS users FROM users; SELECT COUNT(*) AS orders FROM orders;"
```

### 📊 Sample Data Overview

The demo includes realistic e-commerce data:

**Tables:**
- **users** (20+ users) - Customer information with demographics
- **products** (25+ products) - Product catalog across multiple categories
- **orders** (30+ orders) - Purchase history with various statuses
- **user_sessions** (15+ sessions) - User activity tracking

**Geographic Distribution:**
USA, Canada, UK, Germany, France, Spain, Japan, India, Australia, Norway, Brazil, Mexico, Singapore

**Product Categories:**
Electronics, Gaming, Software, Home, Health, Books, Education, Accessories, Furniture

---

Inspect MySQL Data Before Syncing
----------------------------------

Before configuring OLake UI, you may want to inspect what data is available in MySQL. 

**Quick script (recommended):**

```bash
# Run the helper script for a complete overview
./scripts/inspect-mysql-data.sh
```

This script shows row counts, sample data, and data distribution for all tables.

**Manual commands:**

**Quick overview of all tables and row counts:**

```bash
docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "
SELECT 
    'users' as table_name, COUNT(*) as row_count FROM users
UNION ALL
SELECT 'products', COUNT(*) FROM products
UNION ALL
SELECT 'orders', COUNT(*) FROM orders
UNION ALL
SELECT 'user_sessions', COUNT(*) FROM user_sessions;"
```

**View sample data from each table:**

```bash
# Sample users
docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "SELECT id, username, email, status, country FROM users LIMIT 5;"

# Sample products
docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "SELECT id, product_name, category, price, stock_quantity FROM products LIMIT 5;"

# Sample orders
docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "SELECT id, user_id, product_id, quantity, total_amount, status, order_date FROM orders LIMIT 5;"

# Sample user sessions
docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "SELECT id, user_id, session_token, login_time, is_active FROM user_sessions LIMIT 5;"
```

**Interactive MySQL shell (for more detailed exploration):**

```bash
docker exec -it mysql-client mysql -h mysql -u demo_user -pdemo_password demo_db
```

Once inside the MySQL shell, you can run queries like:

```sql
-- Show all tables
SHOW TABLES;

-- Describe table structure
DESCRIBE users;
DESCRIBE products;
DESCRIBE orders;
DESCRIBE user_sessions;

-- Check data distribution
SELECT status, COUNT(*) FROM users GROUP BY status;
SELECT category, COUNT(*) FROM products GROUP BY category;
SELECT status, COUNT(*) FROM orders GROUP BY status;

-- View full table contents
SELECT * FROM users;
SELECT * FROM products;
SELECT * FROM orders;
```

**Exit the MySQL shell:** Type `exit` or press `Ctrl+D`

---

Generate More Data for Performance Testing
------------------------------------------

To demonstrate the performance difference between raw Iceberg tables and optimized ClickHouse silver/gold tables, you'll want more data. The initial dataset has ~20 users and ~30 orders, which is too small to show meaningful performance differences.

**Quick way (recommended):**

```bash
# Generate ~1000 users, 200 products, ~10,000 orders, ~5,000 sessions
./scripts/generate-more-data.sh
```

**Manual way:**

```bash
# Run the SQL script directly
docker exec -i mysql-server mysql -u demo_user -pdemo_password demo_db < scripts/generate-more-data.sql
```

This script will:
- Add **1000+ users** with realistic demographics across 13 countries
- Add **200+ products** across 9 categories
- Generate **~10,000 orders** (approximately 10 orders per user)
- Generate **~5,000 user sessions** (approximately 5 sessions per user)

**After generating more data:**

1. **Re-sync to Iceberg** - Restart or trigger your OLake UI pipeline to sync the new data to MinIO
2. **Refresh ClickHouse tables** - Re-run the setup script to update silver/gold layers:
   ```bash
   docker exec -i clickhouse-server clickhouse-client < scripts/iceberg-setup.sql
   ```
3. **Compare performance** - Run the performance comparison script:
   ```bash
   docker exec -i clickhouse-server clickhouse-client < scripts/compare-query-performance.sql
   ```

**Note:** The data generation script uses stored procedures and may take a few minutes to complete, especially for the orders table. Be patient!

---

Prepare ClickHouse for the Iceberg REST Catalog
-----------------------------------------------

ClickHouse ships with experimental Iceberg support disabled by default. The repo already enables the necessary flags inside `clickhouse-config/config.xml` and expects an Iceberg REST catalog provided by OLake (default: `http://olake-ui:8181/api/catalog`, namespace `demo_lakehouse`, credentials `admin/password`). Update the constants in `scripts/iceberg-setup.sql` and `scripts/mysql-integration.sql` if your catalog endpoint or credentials differ.

Once the container is healthy you can jump straight into the OLake pipeline steps. There is no need to create MySQL engine tables because ClickHouse never queries MySQL in this architecture; all reads go through the REST catalog to the raw Iceberg data stored in MinIO.

---

Configure OLake UI (Source + Destination)
-----------------------------------------

Open `http://localhost:8000` and log in with `admin / password`. Follow `olake-config/OLAKE_UI_PIPELINE.md` for the exact field values—every screen is documented. Summary:

1. **Source** → MySQL
   * Host `mysql`, port `3306`, database `demo_db`.
   * User `olake`, password `olake_pass`.
   * Tables: `users`, `products`, `orders`, `user_sessions`.
   * CDC enabled, chunk size `1000`.

2. **Destination** → Iceberg (Hadoop catalog)
   * Warehouse `s3a://iceberg-warehouse/`.
   * Endpoint `http://minio:9000`, credentials `minioadmin / minioadmin123`, region `us-east-1`, path-style access ON.
   * File format `Parquet`, compression `snappy`.

3. **Per-table settings**
   * Namespace `demo_lakehouse`.
   * Partition strategies:
     * `users`: `month(created_at)` + `identity(country)`
     * `products`: `identity(category)`
     * `orders`: `month(order_date)` + `identity(status)`
     * `user_sessions`: `day(login_time)`
   * Write mode `upsert`, merge strategy `merge_on_read`.

Save both resources—we will start the pipeline in the next section.

---

Create and Run the OLake UI Pipeline
------------------------------------

1. From the pipeline dashboard, select the source + destination you just configured and create a new pipeline (either per table or a single multi-table pipeline).
2. Click **Start Pipeline**. OLake will take an initial snapshot followed by incremental binlog ingestion.
3. Watch the progress bar or open MinIO’s console at `http://localhost:9091` to see new folders appear under `iceberg-warehouse/demo_lakehouse/`.

CLI check:

```bash
docker exec -it minio-client /usr/bin/mc ls myminio/iceberg-warehouse/demo_lakehouse/
```

You should eventually see `users`, `products`, `orders`, and `user_sessions` directories—each containing Iceberg metadata (`metadata/`, `snapshots/`, data files).

---

Hands-on Checklist
------------------

Prefer a quick checklist after your first read-through? Copy/paste these commands in order:

1. **Clone & boot**
   ```bash
   git clone https://github.com/sandeep-devarapalli/Apache-Iceberg-with-clickhouse-olake.git
   cd Apache-Iceberg-with-clickhouse-olake
   docker-compose up -d
   ```
2. **Confirm health**  
   `docker-compose ps`
3. **Launch OLake UI** (separate stack) and connect to network:
   ```bash
   # Start OLake UI (includes its own PostgreSQL, Temporal, Elasticsearch)
   curl -sSL https://raw.githubusercontent.com/datazip-inc/olake-ui/master/docker-compose.yml | docker compose -f - up -d
   
   # Connect OLake UI container to our network so it can reach MySQL/MinIO
   OLAKE_CONTAINER=$(docker ps --filter "name=olake-ui" --format "{{.Names}}" | head -1)
   NETWORK_NAME=$(docker network ls --filter "name=clickhouse_lakehouse-net" --format "{{.Name}}" | head -1)
   docker network connect $NETWORK_NAME $OLAKE_CONTAINER
   echo "Connected $OLAKE_CONTAINER to network $NETWORK_NAME"
   ```
   Then log in at `http://localhost:8000` with `admin` / `password`.
4. **Configure OLake** using `olake-config/OLAKE_UI_PIPELINE.md`.
5. **Start the pipeline** → verify MinIO (`http://localhost:9091`) shows `iceberg-warehouse/demo_lakehouse/<tables>`.
6. **Smoke test Iceberg REST**
   ```bash
   docker exec -it clickhouse-client clickhouse-client --host clickhouse --queries-file /scripts/mysql-integration.sql
   ```
7. **Materialize raw + silver/gold**
   ```bash
   docker exec -it clickhouse-client clickhouse-client --host clickhouse --queries-file /scripts/iceberg-setup.sql
   ```
8. **Benchmark raw vs optimized**
   ```bash
   docker exec -it clickhouse-client clickhouse-client --host clickhouse --queries-file /scripts/cross-database-analytics.sql
   ```
9. **Experiment** with schema evolution, rerun the scripts, share results.

---

Query Iceberg Tables from ClickHouse
------------------------------------

Once OLake has written the Iceberg metadata, run:

```bash
docker exec -it clickhouse-client clickhouse-client --host clickhouse --queries-file /scripts/iceberg-setup.sql
```

`scripts/iceberg-setup.sql` registers four ClickHouse tables via the Iceberg REST engine and builds the Silver/Gold layers.

Verifications:

```sql
SELECT COUNT(*) FROM iceberg_users_lakehouse;
SELECT DISTINCT status FROM iceberg_orders_lakehouse;
```

The data you see here was written via OLake’s UI, not by ClickHouse.

---

Create Silver & Gold Tables in ClickHouse
-----------------------------------------

While the Iceberg tables remain the raw “bronze” layer, ClickHouse can host optimized copies:

1. `scripts/iceberg-setup.sql` now refreshes two extra tables every time you run it:
   * `ch_silver_orders` – a `MergeTree` copy of curated columns from `iceberg_orders_lakehouse`.
   * `ch_gold_order_metrics` – a per-month, per-status aggregate that tracks user counts, order counts, gross revenue, and average order value.
2. Why this matters:
   * Raw Iceberg scans prove that ClickHouse can read OLake-managed data directly, but the query has to parse Iceberg metadata and pull Parquet files over the network.
   * Silver/Gold tables live inside ClickHouse storage, so repeat queries hit local columnar data and return in milliseconds.
3. Compare the layers:

```sql
-- Raw Iceberg (OLake managed)
SELECT status, COUNT(*) AS orders, AVG(total_amount) AS avg_value
FROM iceberg_orders_lakehouse GROUP BY status;

-- Silver (ClickHouse MergeTree copy)
SELECT status, COUNT(*) AS orders, AVG(total_amount) AS avg_value
FROM ch_silver_orders GROUP BY status;

-- Gold (pre-aggregated KPIs)
SELECT status, SUM(order_count) AS orders, AVG(avg_order_value) AS avg_value
FROM ch_gold_order_metrics GROUP BY status;
```

Run the script again whenever OLake lands new data and you want to refresh the ClickHouse-managed tiers:

```bash
docker exec -it clickhouse-client clickhouse-client --host clickhouse --queries-file /scripts/iceberg-setup.sql
```

---

Raw vs Optimized Analytics & Performance Comparison
---------------------------------------------------

Run the demonstration queries to compare the raw Iceberg tables (queried via the REST catalog) with the ClickHouse-managed Silver and Gold layers:

**Quick analytics comparison:**

```bash
docker exec -it clickhouse-client clickhouse-client --host clickhouse --queries-file /scripts/cross-database-analytics.sql
```

**Comprehensive performance comparison:**

For a detailed performance analysis with timing information, use the dedicated performance comparison script:

```bash
docker exec -i clickhouse-server clickhouse-client < scripts/compare-query-performance.sql
```

This script runs the same queries against all three layers (raw Iceberg, silver, gold) and demonstrates:
- **Query speed differences** - See how much faster silver/gold tables are
- **Use case recommendations** - When to use each layer
- **Multiple query patterns** - Aggregations, time-based queries, complex filtering, distinct counts

**Tip:** For meaningful performance differences, generate more data first using `./scripts/generate-more-data.sh`. With only ~30 orders, all queries will be fast. With 10,000+ orders, you'll see significant differences (raw Iceberg: seconds, silver: milliseconds, gold: milliseconds).

Highlights inside the script:

* Benchmark the raw Iceberg scans coming directly from the REST catalog/MinIO against the Silver `MergeTree` copy.
* Read pre-aggregated KPIs out of the Gold table for BI-friendly latency.

You can also explore on your own:

```sql
SELECT status,
       COUNT(*) AS raw_orders,
       AVG(total_amount) AS raw_avg_value
FROM iceberg_orders_lakehouse
GROUP BY status;

SELECT status,
       COUNT(*) AS silver_orders,
       AVG(total_amount) AS silver_avg_value
FROM ch_silver_orders
GROUP BY status;
```

Time travel works too because the REST catalog exposes snapshot metadata:

```sql
SELECT id, status, total_amount
FROM iceberg_orders_lakehouse
SETTINGS iceberg_snapshot_id = 3;
```

---

Schema Evolution and Testing Changes
------------------------------------

Because OLake is capturing CDC metadata, schema changes flow downstream automatically.

1. Alter MySQL:

```sql
docker exec -it mysql-server mysql -u demo_user -pdemo_password -e "
USE demo_db;
ALTER TABLE users ADD COLUMN loyalty_tier VARCHAR(16) DEFAULT 'standard';
UPDATE users SET loyalty_tier = 'gold' WHERE id IN (1,2);"
```

2. Wait for OLake to apply the change and commit a new Iceberg snapshot.
3. Re-run the ClickHouse script or just inspect:

```sql
DESCRIBE TABLE iceberg_users_lakehouse;
SELECT username, loyalty_tier FROM iceberg_users_lakehouse WHERE loyalty_tier != 'standard';
```

If you see the new column populated, you just confirmed end-to-end schema evolution via OLake UI.

---

Troubleshooting Checklist
-------------------------

| Symptom | What to Check |
|---------|---------------|
| Pipeline stuck in `Starting` | `docker-compose logs olake-ui`, confirm PostgreSQL is healthy, ensure MySQL binlog options match `docker-compose.yml`. |
| MinIO permission errors | Re-run `minio-client` service or execute `/usr/bin/mc alias set myminio ...` manually. |
| ClickHouse Iceberg errors | Ensure OLake created metadata files **before** running `scripts/iceberg-setup.sql`. Look at `/var/log/clickhouse-server/clickhouse-server.err.log`. |
| Schema mismatch | Trigger a manual snapshot in OLake UI or resync the affected table. |
| Slow ingestion | Reduce OLake batch size or adjust partition strategies (documented in `olake-config/OLAKE_UI_PIPELINE.md`). |

---

Where to Go Next
----------------

* Swap MySQL for another source that OLake supports (PostgreSQL, SQL Server, etc.) while preserving the Iceberg destination.
* Connect ClickHouse to BI tools (Superset, Grafana) and point dashboards at the Iceberg tables for time-travel analytics.
* Experiment with additional ClickHouse features: `iceberg()` table function, `iceberg_catalog` SQL driver, or materialized views that ingest from Iceberg.
* Extend the MinIO bucket with lifecycle policies, object locking, or tiering if you want to mimic production-grade object storage.

Enjoy building—and let me know what other OLake + ClickHouse workflows you want to see!

