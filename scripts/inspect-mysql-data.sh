#!/bin/bash
# Quick script to inspect MySQL data before syncing with OLake

echo "=== MySQL Data Overview ==="
echo ""

echo "Table Row Counts:"
docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "
SELECT 
    'users' as table_name, COUNT(*) as row_count FROM users
UNION ALL
SELECT 'products', COUNT(*) FROM products
UNION ALL
SELECT 'orders', COUNT(*) FROM orders
UNION ALL
SELECT 'user_sessions', COUNT(*) FROM user_sessions;" 2>/dev/null

echo ""
echo "=== Sample Data ==="
echo ""

echo "Sample Users (first 5):"
docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "SELECT id, username, email, status, country FROM users LIMIT 5;" 2>/dev/null

echo ""
echo "Sample Products (first 5):"
docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "SELECT id, product_name, category, price FROM products LIMIT 5;" 2>/dev/null

echo ""
echo "Sample Orders (first 5):"
docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "SELECT id, user_id, product_id, total_amount, status FROM orders LIMIT 5;" 2>/dev/null

echo ""
echo "=== Data Distribution ==="
echo ""

echo "Users by Status:"
docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "SELECT status, COUNT(*) as count FROM users GROUP BY status;" 2>/dev/null

echo ""
echo "Products by Category:"
docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "SELECT category, COUNT(*) as count FROM products GROUP BY category;" 2>/dev/null

echo ""
echo "Orders by Status:"
docker exec -it mysql-server mysql -u demo_user -pdemo_password demo_db -e "SELECT status, COUNT(*) as count FROM orders GROUP BY status;" 2>/dev/null

echo ""
echo "=== To explore interactively, run: ==="
echo "docker exec -it mysql-client mysql -h mysql -u demo_user -pdemo_password demo_db"

