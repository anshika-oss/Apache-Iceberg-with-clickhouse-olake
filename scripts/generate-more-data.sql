-- Generate More Data for Performance Testing
-- This script adds significantly more rows to demonstrate query performance differences
-- between raw Iceberg tables and optimized ClickHouse silver/gold tables
-- 
-- Usage: 
--   docker exec -i mysql-server mysql -u demo_user -pdemo_password demo_db < scripts/generate-more-data.sql
-- Or interactive:
--   docker exec -it mysql-client mysql -h mysql -u demo_user -pdemo_password demo_db
--   source /scripts/generate-more-data.sql

USE demo_db;

SELECT 'Starting data generation...' AS status;

-- Get current max IDs
SET @max_user_id = (SELECT COALESCE(MAX(id), 0) FROM users);
SET @max_product_id = (SELECT COALESCE(MAX(id), 0) FROM products);

SELECT CONCAT('Current max user_id: ', @max_user_id, ', max product_id: ', @max_product_id) AS status;

-- Generate 1000 additional users
INSERT INTO users (username, email, full_name, age, country, status, created_at)
SELECT 
    CONCAT('user_', @max_user_id + n) AS username,
    CONCAT('user_', @max_user_id + n, '@example.com') AS email,
    CONCAT('User ', @max_user_id + n) AS full_name,
    FLOOR(18 + RAND() * 50) AS age,
    ELT(1 + FLOOR(RAND() * 13), 'USA', 'Canada', 'UK', 'Germany', 'France', 'Spain', 
        'Japan', 'India', 'Australia', 'Norway', 'Brazil', 'Mexico', 'Singapore') AS country,
    ELT(1 + FLOOR(RAND() * 4), 'active', 'inactive', 'premium', 'banned') AS status,
    DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 365) DAY) AS created_at
FROM (
    SELECT a.N + b.N * 10 + c.N * 100 AS n
    FROM 
    (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION 
     SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN
    (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION 
     SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN
    (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION 
     SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    WHERE a.N + b.N * 10 + c.N * 100 < 1000
) numbers;

SELECT CONCAT('Generated ', COUNT(*), ' total users') AS status FROM users;

-- Generate 200 additional products
INSERT INTO products (product_name, category, price, stock_quantity, is_active, created_at)
SELECT 
    CONCAT('Product ', @max_product_id + n, ' - ', 
           ELT(1 + FLOOR(RAND() * 9), 'Electronics', 'Gaming', 'Software', 'Home', 
               'Health', 'Books', 'Education', 'Accessories', 'Furniture')) AS product_name,
    ELT(1 + FLOOR(RAND() * 9), 'Electronics', 'Gaming', 'Software', 'Home', 
        'Health', 'Books', 'Education', 'Accessories', 'Furniture') AS category,
    ROUND(10 + RAND() * 2990, 2) AS price,
    FLOOR(RAND() * 500) AS stock_quantity,
    IF(RAND() > 0.1, TRUE, FALSE) AS is_active,
    DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 180) DAY) AS created_at
FROM (
    SELECT a.N + b.N * 10 AS n
    FROM 
    (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION 
     SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN
    (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION 
     SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    WHERE a.N + b.N * 10 < 200
) numbers;

SELECT CONCAT('Generated ', COUNT(*), ' total products') AS status FROM products;

-- Generate orders (approximately 10 orders per user)
-- Using a stored procedure approach for better control
DELIMITER $$

CREATE PROCEDURE IF NOT EXISTS generate_orders()
BEGIN
    DECLARE done INT DEFAULT FALSE;
    DECLARE v_user_id INT;
    DECLARE v_product_id INT;
    DECLARE v_order_count INT;
    DECLARE i INT;
    
    DECLARE user_cursor CURSOR FOR SELECT id FROM users;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
    
    OPEN user_cursor;
    
    user_loop: LOOP
        FETCH user_cursor INTO v_user_id;
        IF done THEN
            LEAVE user_loop;
        END IF;
        
        -- Generate 10 orders for this user
        SET i = 0;
        WHILE i < 10 DO
            -- Pick a random product
            SELECT id INTO v_product_id 
            FROM products 
            ORDER BY RAND() 
            LIMIT 1;
            
            -- Insert order
            INSERT INTO orders (user_id, product_id, quantity, unit_price, status, shipping_address, notes, order_date)
            SELECT 
                v_user_id,
                v_product_id,
                FLOOR(1 + RAND() * 5),
                (SELECT price FROM products WHERE id = v_product_id),
                ELT(1 + FLOOR(RAND() * 5), 'pending', 'confirmed', 'shipped', 'delivered', 'cancelled'),
                CONCAT(FLOOR(100 + RAND() * 900), ' ', 
                       ELT(1 + FLOOR(RAND() * 10), 'Main St', 'Oak Ave', 'Pine Rd', 'Elm St', 
                           'Maple Dr', 'Cedar Ln', 'Birch Ave', 'Spruce St', 'Willow Way', 'Aspen Rd'),
                       ', ', (SELECT country FROM users WHERE id = v_user_id)),
                IF(RAND() > 0.7, CONCAT('Note ', FLOOR(RAND() * 1000)), NULL),
                DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 365) DAY);
            
            SET i = i + 1;
        END WHILE;
    END LOOP;
    
    CLOSE user_cursor;
END$$

DELIMITER ;

-- Call the procedure to generate orders
CALL generate_orders();
DROP PROCEDURE IF EXISTS generate_orders;

SELECT CONCAT('Generated ', COUNT(*), ' total orders') AS status FROM orders;

-- Generate user sessions (5 sessions per user)
DELIMITER $$

CREATE PROCEDURE IF NOT EXISTS generate_sessions()
BEGIN
    DECLARE done INT DEFAULT FALSE;
    DECLARE v_user_id INT;
    DECLARE i INT;
    
    DECLARE user_cursor CURSOR FOR SELECT id FROM users;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
    
    OPEN user_cursor;
    
    user_loop: LOOP
        FETCH user_cursor INTO v_user_id;
        IF done THEN
            LEAVE user_loop;
        END IF;
        
        -- Generate 5 sessions for this user
        SET i = 0;
        WHILE i < 5 DO
            INSERT INTO user_sessions (user_id, session_token, ip_address, user_agent, is_active, login_time, last_activity)
            SELECT 
                v_user_id,
                CONCAT('sess_', v_user_id, '_', UNIX_TIMESTAMP(NOW()) + i),
                CONCAT('192.168.', FLOOR(RAND() * 255), '.', FLOOR(RAND() * 255)),
                ELT(1 + FLOOR(RAND() * 5), 
                    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)',
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
                    'Mozilla/5.0 (X11; Linux x86_64)',
                    'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0)',
                    'Mozilla/5.0 (Android 13; Mobile)'),
                IF(RAND() > 0.3, TRUE, FALSE),
                DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 30) DAY),
                DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 7) DAY);
            
            SET i = i + 1;
        END WHILE;
    END LOOP;
    
    CLOSE user_cursor;
END$$

DELIMITER ;

-- Call the procedure to generate sessions
CALL generate_sessions();
DROP PROCEDURE IF EXISTS generate_sessions;

SELECT CONCAT('Generated ', COUNT(*), ' total user sessions') AS status FROM user_sessions;

-- Final summary
SELECT '=== Data Generation Complete ===' AS info;
SELECT 'users' AS table_name, COUNT(*) AS row_count FROM users
UNION ALL
SELECT 'products', COUNT(*) FROM products
UNION ALL
SELECT 'orders', COUNT(*) FROM orders
UNION ALL
SELECT 'user_sessions', COUNT(*) FROM user_sessions;

SELECT '=== Next Steps ===' AS info;
SELECT '1. Re-sync data to Iceberg via OLake UI pipeline' AS step;
SELECT '2. Re-run scripts/iceberg-setup.sql in ClickHouse to refresh silver/gold tables' AS step;
SELECT '3. Run scripts/compare-query-performance.sql to see performance differences' AS step;
