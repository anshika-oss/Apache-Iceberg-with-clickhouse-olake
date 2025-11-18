-- MySQL User Permissions Setup for OLake Integration
-- This script creates necessary users and permissions for OLake CDC operations
-- Note: ClickHouse queries Iceberg tables via REST catalog, not MySQL directly

-- Create OLake integration user for CDC
CREATE USER IF NOT EXISTS 'olake'@'%' IDENTIFIED BY 'olake_pass';

-- Grant necessary privileges for OLake CDC operations
GRANT SELECT ON demo_db.* TO 'olake'@'%';
GRANT SHOW DATABASES ON *.* TO 'olake'@'%';
GRANT SHOW VIEW ON demo_db.* TO 'olake'@'%';

-- Grant replication privileges for CDC
GRANT REPLICATION SLAVE ON *.* TO 'olake'@'%';
GRANT REPLICATION CLIENT ON *.* TO 'olake'@'%';

-- Grant privileges to read binary logs
GRANT SELECT ON mysql.* TO 'olake'@'%';

-- Create a monitoring user for health checks
CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'monitor_pass';
GRANT PROCESS ON *.* TO 'monitor'@'%';
GRANT SELECT ON performance_schema.* TO 'monitor'@'%';
-- Note: information_schema is accessible to all users by default in MySQL 8.0, no grant needed

-- Create demo user for manual testing
CREATE USER IF NOT EXISTS 'demo_user'@'%' IDENTIFIED BY 'demo_password';
GRANT ALL PRIVILEGES ON demo_db.* TO 'demo_user'@'%';

-- Flush privileges to ensure all changes take effect
FLUSH PRIVILEGES;

-- Display created users
SELECT 'User Permissions Summary' as info;

SELECT 'olake user created for CDC operations' as status;
SELECT 'monitor user created for health checks' as status;
SELECT 'demo_user created for manual testing' as status;

-- Verify binary log configuration
SHOW VARIABLES LIKE 'log_bin';
SHOW VARIABLES LIKE 'server_id';
SHOW VARIABLES LIKE 'binlog_format';
SHOW VARIABLES LIKE 'gtid_mode';

-- Show current binary log files
SHOW BINARY LOGS;

-- Display replication status (should show master status)
SHOW MASTER STATUS;
