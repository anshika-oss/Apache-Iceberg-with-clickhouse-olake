#!/bin/bash
# Helper script to generate more data in MySQL for performance testing
# This will add ~1000 users, 200 products, ~10,000 orders, and ~5,000 sessions

echo "=== Generating More Data in MySQL ==="
echo ""

# Check if MySQL container is running
if ! docker ps | grep -q mysql-server; then
    echo "Error: MySQL container is not running. Please start it with: docker-compose up -d"
    exit 1
fi

echo "Step 1: Generating additional data in MySQL..."
docker exec -i mysql-server mysql -u demo_user -pdemo_password demo_db < "$(dirname "$0")/generate-more-data.sql"

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Data generation complete!"
    echo ""
    echo "Current data counts:"
    docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "
    SELECT 'users' AS table_name, COUNT(*) AS row_count FROM users
    UNION ALL
    SELECT 'products', COUNT(*) FROM products
    UNION ALL
    SELECT 'orders', COUNT(*) FROM orders
    UNION ALL
    SELECT 'user_sessions', COUNT(*) FROM user_sessions;"
    
    echo ""
    echo "=== Next Steps ==="
    echo "1. Re-sync data to Iceberg via OLake UI pipeline"
    echo "2. Re-run scripts/iceberg-setup.sql in ClickHouse to refresh silver/gold tables:"
    echo "   docker exec -i clickhouse-server clickhouse-client < scripts/iceberg-setup.sql"
    echo "3. Compare query performance:"
    echo "   docker exec -i clickhouse-server clickhouse-client < scripts/compare-query-performance.sql"
else
    echo ""
    echo "✗ Error generating data. Please check the MySQL logs."
    exit 1
fi

