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
┌───────────┐  Binlog CDC   ┌────────────┐                    ┌────────────┐
│  MySQL    │──────────────▶│  OLake UI  │                    │   MinIO    │
│  (OLTP)   │               │ (pipelines)│                    │            │
└───────────┘               └────────────┘                    │  ┌─────────┴─────────┐
                                                                │  │ Raw Iceberg       │
                                                                │  │ (demo_lakehouse)  │
                                                                │  └─────────┬─────────┘
                                                                │            │
                                                                │  ┌─────────┴─────────┐
                                                                │  │ Silver Iceberg     │
                                                                │  │ (demo_lakehouse_   │
                                                                │  │  silver)           │
                                                                │  │ Written by CH      │
                                                                │  └─────────┬─────────┘
                                                                └────────────┼────────────┘
                                                                             │
                                                                    ┌────────┴────────┐
                                                                    │ Iceberg REST     │
                                                                    │ Catalog (OLake)  │
                                                                    └────────┬────────┘
                                                                             │
                                                                    ┌────────┴────────┐
                                                                    │   ClickHouse     │
                                                                    │                  │
                                                                    │  ┌─────────────┐ │
                                                                    │  │ Gold Tables │ │
                                                                    │  │ (MergeTree) │ │
                                                                    │  │ Local Store │ │
                                                                    │  └─────────────┘ │
                                                                    └──────────────────┘
```

**Data Flow:**
1. **MySQL** → **OLake UI** (CDC via binlog) → **Raw Iceberg tables** in MinIO (`demo_lakehouse` namespace)
2. **ClickHouse** reads raw Iceberg via REST catalog and writes **Silver Iceberg tables** to MinIO (`demo_lakehouse_silver` namespace, optimized)
3. **ClickHouse** creates **Gold tables** (pre-aggregated KPIs) in local storage for fastest queries

* **MySQL 8.0** – Operational workload with realistic sample data, GTID + binlog enabled for CDC.
* **OLake UI** – Low-code interface for defining CDC pipelines that output Iceberg tables.
* **MinIO** – S3-compatible object store acting as the Iceberg warehouse (stores both raw and silver Iceberg tables).
* **ClickHouse** – Queries Iceberg data via REST catalog, writes optimized Silver Iceberg tables to MinIO, and maintains Gold tables in local storage.

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

Bring Up All Services
---------------------

Start all services including MySQL, MinIO, ClickHouse, and OLake UI with all its dependencies:

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
| `olake-ui` | Data lake orchestration | Web UI `http://localhost:8000` |
| `temporal-postgresql`, `temporal`, `temporal-elasticsearch` | OLake dependencies | Internal services for OLake |
| `olake-temporal-worker` | OLake worker | Executes OLake workflows |

---

OLake UI is Included
--------------------

**Great news!** OLake UI and all its dependencies are now included in the main `docker-compose.yml` file. When you run `docker-compose up -d`, it automatically starts:

- **OLake UI** (web interface at http://localhost:8000)
- **PostgreSQL** (for OLake's metadata and job state)
- **Temporal Server** (workflow orchestration)
- **Elasticsearch** (Temporal search backend)
- **OLake Temporal Worker** (executes OLake workflows)

All services run on the same Docker network (`clickhouse_lakehouse-net`), so there are **no network connection steps needed** - everything can communicate directly!

**Access OLake UI:**
- **URL**: http://localhost:8000
- **Default credentials**: `admin` / `password`

The signup process runs automatically when the containers start, so the admin user is created for you.

**Important:** When configuring sources/destinations in OLake UI, use these Docker hostnames (they're all on the same network now):
- **MySQL**: `mysql:3306` (not localhost:3307)
- **MinIO**: `minio:9000` (not localhost:9090)
- **MinIO Console**: `http://minio:9000` for API, `http://minio:9091` for console

**Note:** OLake UI may take 30-60 seconds to fully start after `docker-compose up -d` because it depends on PostgreSQL, Temporal, and Elasticsearch starting first. You can check the status with:

```bash
docker-compose ps
```

Wait until `olake-ui` shows as "healthy" before accessing the web interface.

---

Seed MySQL with Demo Data
-------------------------

The MySQL container automatically executes:

* `mysql-init/01-setup.sql` – creates the `demo_db` schema (`users`, `products`, `orders`, `user_sessions`) and automatically generates a large dataset for performance testing:
  * **~1000 users** with realistic demographics across 13 countries
  * **~200 products** across 9 categories
  * **~10,000 orders** (approximately 10 orders per user)
  * **~5,000 user sessions** (approximately 5 sessions per user)
* `mysql-init/02-permissions.sql` – creates integration users:
  * `olake / olake_pass` (CDC + replication privileges for OLake UI).
  * `demo_user / demo_password` (for manual testing and inspection).
  

### 📊 Sample Data Overview

The demo includes realistic e-commerce data:

**Tables:**
- **users** (1000+ users) - Customer information with demographics
- **products** (200+ products) - Product catalog across multiple categories
- **orders** (10,000+ orders) - Purchase history with various statuses
- **user_sessions** (5,000+ sessions) - User activity tracking

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


Prepare ClickHouse for the Iceberg REST Catalog
-----------------------------------------------

ClickHouse ships with experimental Iceberg support disabled by default. The repo already enables the necessary flags inside `clickhouse-config/config.xml` and expects an Iceberg REST catalog provided by OLake (default: `http://olake-ui:8181/api/catalog`, namespace `demo_lakehouse`, credentials `admin/password`). Update the constants in `scripts/iceberg-setup.sql` and `scripts/mysql-integration.sql` if your catalog endpoint or credentials differ.

Once the container is healthy you can jump straight into the OLake pipeline steps. 
---

Configure OLake UI: Step-by-Step Guide
---------------------------------------

OLake UI is already running and connected to the same network as MySQL and MinIO (no network setup needed!). 

Now let's configure OLake UI to replicate data from MySQL to Iceberg tables in MinIO. Open your browser and navigate to `http://localhost:8000`. You'll see the OLake UI login page.

**Note:** If OLake UI isn't ready yet, wait a bit longer. It depends on PostgreSQL, Temporal, and Elasticsearch starting first. Check status with `docker-compose ps` and wait until `olake-ui` shows as "healthy".

**Step 1: Log in to OLake UI**

- URL: `http://localhost:8000`
- Username: `admin`
- Password: `password`

Once logged in, you'll see the OLake dashboard. We need to configure two things: a **Source** (MySQL) and a **Destination** (Iceberg on MinIO).

**Step 2: Register the MySQL Source**

1. In the left sidebar, click on **Sources**, then click **New Source**.
2. Select **MySQL** as the source type.
3. Fill in the connection details:
   - **Host**: `mysql` (use the Docker hostname, not `localhost`)
   - **Port**: `3306`
   - **Database**: `demo_db`
   - **Username**: `olake`
   - **Password**: `olake_pass`
   - **Enable SSL**: Leave this unchecked (set to `false`)
4. Click **Next** or **Test Connection** to verify the connection works.

   **Troubleshooting connection errors:**
   
   **Error 1: `"failed to ping database: dial tcp: lookup mysql on ...: no such host"`**
   
   This means OLake UI can't resolve the `mysql` hostname. This usually happens if:
   - The network connection wasn't established before starting OLake UI
   - OLake UI needs to be restarted after connecting to the network
   
   **Fix:** Run these commands and try the connection test again:
   ```bash
   # Connect to network and restart
   OLAKE_CONTAINER=$(docker ps --filter "name=olake-ui" --format "{{.Names}}" | head -1)
   NETWORK_NAME=$(docker network ls --filter "name=clickhouse_lakehouse-net" --format "{{.Name}}" | head -1)
   docker network connect $NETWORK_NAME $OLAKE_CONTAINER
   docker restart olake-ui olake-temporal-worker
   sleep 25  # Wait for OLake UI to be healthy
   ```
   
   **Error 2: `"failed to ping database: dial tcp 172.25.0.2:3306: i/o timeout"`**
   
   This means the connection is timing out. This can happen if:
   - MySQL is still initializing (wait a bit longer)
   - OLake UI's connection timeout is too short
   - Network delay on first connection
   
   **Fix:** Try these steps:
   ```bash
   # 1. Verify MySQL is ready
   docker exec mysql-server mysqladmin -u root -proot_password ping
   
   # 2. Test connection from olake-ui container
   docker exec olake-ui nc -zv mysql 3306
   
   # 3. If connection test works, try using hostname instead of IP
   # In OLake UI, use "mysql" as hostname (not the IP address)
   
   # 4. Wait 10-15 seconds and try the connection test again in OLake UI
   # Sometimes the first connection attempt is slow
   ```
   
   **If still failing:** Check OLake UI logs for more details:
   ```bash
   docker logs olake-ui --tail 50 | grep -i -E "mysql|connection|error"
   ```

5. Select the tables you want to replicate:
   - ✅ `users`
   - ✅ `products`
   - ✅ `orders`
   - ✅ `user_sessions`
6. In the advanced options:
   - **Chunk Size**: `1000` (number of rows to process per batch)
   - **CDC (Change Data Capture)**: Enable this checkbox (it will use the binlog we configured in MySQL)
7. Click **Save** or **Create Source**.

Great! Your MySQL source is now registered. OLake will use the binlog to capture changes in real-time.

**Step 3: Register the Iceberg Destination (MinIO)**

1. In the left sidebar, click on **Destinations**, then click **New Destination**.
2. Select **Iceberg (S3/Hadoop catalog)** as the destination type.
3. In the **Catalog** section:
   - **Type**: Select `hadoop`
   - **Warehouse**: `s3a://iceberg-warehouse/` (this is the S3 path where Iceberg tables will be stored)
   - **Metastore URI**: Leave this blank (MinIO doesn't need Hive Metastore for this demo)
4. In the **Storage** section (this connects to MinIO):
   - **Endpoint**: `http://minio:9000` (use Docker hostname, not `localhost`)
   - **Access Key**: `minioadmin`
   - **Secret Key**: `minioadmin123`
   - **Region**: `us-east-1`
   - **Bucket**: `iceberg-warehouse`
   - **Path Style Access**: Enable this checkbox (required for MinIO)
   - **SSL**: Leave unchecked (disabled)
5. In the **Format** section:
   - **File Format**: `Parquet`
   - **Compression**: `snappy`
6. Enable partitioning (this will be configured per-table in the pipeline).
7. Click **Save** or **Create Destination**.

Perfect! Now OLake knows where to write the Iceberg tables. The destination is configured to use MinIO as an S3-compatible storage backend.

**Step 4: Create and Configure the Pipeline**

Now we'll create a pipeline that connects the MySQL source to the Iceberg destination. You can create either:
- A single multi-table pipeline (recommended for this demo), or
- Separate pipelines for each table

1. In the left sidebar, click on **Pipelines**, then click **New Pipeline** or **Create Pipeline**.
2. Select your MySQL source (the one you just created).
3. Select your Iceberg destination (the one you just created).
4. Configure per-table settings. For each table, set:

   | Table | Namespace | Destination Table | Partition Strategy | Primary Key |
   |-------|-----------|-------------------|-------------------|-------------|
   | `users` | `demo_lakehouse` | `users` | `month(created_at)`, `identity(country)` | `id` |
   | `products` | `demo_lakehouse` | `products` | `identity(category)` | `id` |
   | `orders` | `demo_lakehouse` | `orders` | `month(order_date)`, `identity(status)` | `id` |
   | `user_sessions` | `demo_lakehouse` | `user_sessions` | `day(login_time)` | `id` |

   **Partitioning explained:**
   - `users`: Partitioned by month of creation and country (helps with time-based and geographic queries)
   - `products`: Partitioned by category (helps with product category analytics)
   - `orders`: Partitioned by month and status (helps with order status trends over time)
   - `user_sessions`: Partitioned by day (helps with daily session analytics)

5. Set the write options:
   - **Write Mode**: `upsert` (updates existing rows, inserts new ones)
   - **Merge Strategy**: `merge_on_read` (optimizes for query performance)
   - **Batch Size**: `10000` (number of rows per batch)
   - **Flush Interval**: `60s` (how often to flush data to storage)
   - **Commit Interval**: `300s` (how often to commit Iceberg snapshots)

6. Click **Save** or **Create Pipeline**.

**Step 5: Start the Pipeline and Monitor Progress**

1. Find your pipeline in the pipelines list and click on it.
2. Click the **Start** or **Start Pipeline** button.
3. OLake will now:
   - Take an initial snapshot of all data from MySQL (this may take a few minutes with 10,000+ orders)
   - Write the data to Iceberg tables in MinIO
   - Begin incremental CDC replication using the MySQL binlog

4. **Monitor the progress:**
   - Watch the progress bar in the OLake UI
   - Check the monitoring/logs tab for detailed status
   - You can also verify data is being written by checking MinIO:
     ```bash
     docker exec -it minio-client /usr/bin/mc ls myminio/iceberg-warehouse/demo_lakehouse/
     ```
   - Or open MinIO's web console at `http://localhost:9091` (login: `minioadmin` / `minioadmin123`) and navigate to the `iceberg-warehouse` bucket

5. **What to expect:**
   - You should see four directories appear: `users/`, `products/`, `orders/`, and `user_sessions/`
   - Each directory will contain Iceberg metadata files (`metadata/`, `snapshots/`, and Parquet data files)
   - The initial snapshot may take 2-5 minutes depending on your system

6. **Verify the data:**
   - In OLake UI, check the monitoring tab to see row counts for each table
   - You should see approximately:
     - ~1,010 users
     - ~200 products
     - ~10,000 orders
     - ~5,000 user sessions

Once you see the data counts matching and the pipeline status shows "Running" or "Active", you're ready to query the Iceberg tables from ClickHouse!

**Quick verification:** Before moving on, you can verify the Iceberg tables exist in MinIO:

```bash
# List the Iceberg tables in MinIO
docker exec -it minio-client /usr/bin/mc ls -r myminio/iceberg-warehouse/demo_lakehouse/

# You should see directories for: users/, products/, orders/, user_sessions/
# Each containing metadata/ and data/ subdirectories
```

---

Query Iceberg Tables from ClickHouse
------------------------------------

Now that OLake has written the Iceberg tables to MinIO, let's connect ClickHouse to query them. ClickHouse will use the Iceberg REST catalog (provided by OLake) to discover and read these tables.

Run the setup script to create ClickHouse table definitions that point to your Iceberg tables:

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

Create Silver & Gold Tables
---------------------------

The data architecture uses three layers for optimal performance:

1. **Raw Iceberg tables** (in MinIO) - Written by OLake from MySQL CDC
   * Namespace: `demo_lakehouse`
   * Unoptimized layout, all columns, original partitioning

2. **Silver Iceberg tables** (in MinIO) - Written by ClickHouse as optimized Iceberg tables
   * Namespace: `demo_lakehouse_silver`
   * ClickHouse writes curated columns with optimized partitioning and file layout
   * Faster than raw because ClickHouse optimizes the Iceberg table structure for querying

3. **Gold tables** (in ClickHouse local storage) - Pre-aggregated KPIs
   * `ch_gold_order_metrics` – a `MergeTree` table with pre-computed metrics
   * Fastest queries, no computation needed

`scripts/iceberg-setup.sql` creates:
   * `iceberg_silver_orders` – an optimized Iceberg table in MinIO (namespace `demo_lakehouse_silver`) written by ClickHouse
   * `ch_gold_order_metrics` – a per-month, per-status aggregate in ClickHouse local storage

**Why this architecture matters:**
   * **Raw Iceberg**: Proves ClickHouse can read OLake-managed data, but queries are slower due to unoptimized layout and network I/O
   * **Silver Iceberg**: ClickHouse writes optimized Iceberg tables to MinIO with better partitioning, file sizes, and column selection, making queries faster than raw
   * **Gold**: Pre-aggregated metrics in ClickHouse local storage provide instant dashboard queries
3. **What are the KPIs in the Gold table?**

The `ch_gold_order_metrics` table contains pre-aggregated Key Performance Indicators (KPIs) per month and status:
- **`order_month`**: Month of the order (Date)
- **`status`**: Order status (pending, confirmed, shipped, delivered, cancelled)
- **`user_count`**: Number of unique customers (using `uniqExact`)
- **`order_count`**: Total number of orders
- **`gross_revenue`**: Total revenue (sum of `total_amount`)
- **`avg_order_value`**: Average order value (gross_revenue / order_count)

These KPIs are pre-computed from the silver layer, enabling instant dashboard queries without recalculating aggregations.

4. **Compare the layers with example queries:**

```sql
-- Raw Iceberg (OLake managed) - Queries MinIO via REST API
-- Expected: 2-5 seconds for 10,000+ orders
SELECT status, COUNT(*) AS orders, AVG(total_amount) AS avg_value
FROM iceberg_orders_lakehouse GROUP BY status;

-- Silver Iceberg (ClickHouse-written, optimized) - Queries MinIO via REST API
-- Expected: 500ms-2 seconds for 10,000+ orders (faster than raw due to optimization)
SELECT status, COUNT(*) AS orders, AVG(total_amount) AS avg_value
FROM iceberg_silver_orders GROUP BY status;

-- Gold (pre-aggregated KPIs) - ClickHouse local storage
-- Expected: 10-50 milliseconds (fastest, no computation needed)
SELECT status, SUM(order_count) AS orders, AVG(avg_order_value) AS avg_value
FROM ch_gold_order_metrics GROUP BY status;
```

**Performance expectations with 10,000+ orders:**
- **Raw Iceberg**: 2-5 seconds (network I/O, Parquet parsing, unoptimized layout)
- **Silver Iceberg**: 500ms-2 seconds (ClickHouse-optimized Iceberg in MinIO, better partitioning and file layout)
- **Gold**: 10-50 milliseconds (pre-aggregated metrics in ClickHouse local storage)

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

**Comprehensive performance comparison with timing:**

For a detailed performance analysis, use the dedicated performance comparison script that runs the same queries against all three layers:

```bash
docker exec -i clickhouse-server clickhouse-client < scripts/compare-query-performance.sql
```

This script demonstrates:
- **Query speed differences** - Same queries run against raw, silver, and gold layers
- **Multiple query patterns** - Simple aggregations, time-based queries, complex filtering, distinct counts
- **KPI explanations** - What metrics are pre-computed in the gold table
- **Use case recommendations** - When to use each layer

**To see actual query execution times**, use the timing script:

```bash
# Run performance comparison with actual timing
./scripts/performance-with-timing.sh
```

This script uses the `time` command to show real execution times for the same query against all three layers.

**Or manually with ClickHouse timing:**

```bash
# Raw Iceberg
docker exec -it clickhouse-client clickhouse-client --host clickhouse --query "
SELECT status, COUNT(*) AS orders, ROUND(AVG(total_amount), 2) AS avg_value
FROM iceberg_orders_lakehouse GROUP BY status
" --format=Pretty --time

# Silver Iceberg (optimized, in MinIO)
docker exec -it clickhouse-client clickhouse-client --host clickhouse --query "
SELECT status, COUNT(*) AS orders, ROUND(AVG(total_amount), 2) AS avg_value
FROM iceberg_silver_orders GROUP BY status
" --format=Pretty --time

# Gold
docker exec -it clickhouse-client clickhouse-client --host clickhouse --query "
SELECT status, SUM(order_count) AS orders, ROUND(AVG(avg_order_value), 2) AS avg_value
FROM ch_gold_order_metrics GROUP BY status
" --format=Pretty --time
```

**Expected performance with 10,000+ orders:**
- **Raw Iceberg**: 2-5 seconds (network I/O, Parquet parsing, unoptimized layout)
- **Silver Iceberg**: 500ms-2 seconds (ClickHouse-optimized Iceberg in MinIO, better partitioning and file layout)
- **Gold**: 10-50 milliseconds (pre-aggregated metrics in ClickHouse local storage)

**Key insight:** Silver tables are faster than raw because ClickHouse writes them as optimized Iceberg tables in MinIO with:
- Better partitioning strategy (optimized for common query patterns)
- Optimized file sizes and Parquet compression
- Curated columns (only frequently queried columns)
- Better metadata organization

Highlights inside the script:

* Benchmark the raw Iceberg scans (unoptimized) against the Silver optimized Iceberg table (both in MinIO).
* Compare Silver Iceberg (ClickHouse-written, optimized) with Gold (pre-aggregated in ClickHouse local storage).
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
FROM iceberg_silver_orders
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

