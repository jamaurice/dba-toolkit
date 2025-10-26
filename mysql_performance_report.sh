#!/bin/bash
#
# mysql_performance_report.sh
# 
# Generates comprehensive MySQL performance report using Performance Schema
# Author: Jamaurice Holt
# Usage: ./mysql_performance_report.sh [host] [user] [password]
#
# This script analyzes:
# - Top 20 slowest queries by total execution time
# - Top 10 queries by execution count
# - Table I/O statistics
# - Index usage analysis
# - Connection statistics
# - InnoDB buffer pool efficiency
#

set -euo pipefail

# Configuration
MYSQL_HOST="${1:-localhost}"
MYSQL_USER="${2:-root}"
MYSQL_PASS="${3}"
REPORT_DATE=$(date +"%Y-%m-%d_%H-%M-%S")
REPORT_FILE="mysql_performance_report_${REPORT_DATE}.txt"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to execute MySQL query
run_query() {
    mysql -h"${MYSQL_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "$1" 2>/dev/null
}

# Function to print section header
print_header() {
    echo "================================================================"
    echo "$1"
    echo "================================================================"
    echo ""
}

# Start report
{
    print_header "MySQL Performance Report - $(date)"
    
    echo "Host: ${MYSQL_HOST}"
    echo "Report Generated: ${REPORT_DATE}"
    echo ""
    
    # Section 1: Server Information
    print_header "1. SERVER INFORMATION"
    run_query "SELECT VERSION() AS mysql_version;"
    run_query "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';"
    run_query "SHOW VARIABLES LIKE 'max_connections';"
    run_query "SHOW GLOBAL STATUS LIKE 'Uptime';"
    
    # Section 2: Top Slow Queries by Total Execution Time
    print_header "2. TOP 20 QUERIES BY TOTAL EXECUTION TIME"
    run_query "
    SELECT 
        SUBSTRING(DIGEST_TEXT, 1, 100) AS query_sample,
        COUNT_STAR AS exec_count,
        ROUND(AVG_TIMER_WAIT/1000000000000, 2) AS avg_seconds,
        ROUND(MAX_TIMER_WAIT/1000000000000, 2) AS max_seconds,
        ROUND(SUM_TIMER_WAIT/1000000000000, 2) AS total_seconds,
        ROUND((SUM_TIMER_WAIT / (SELECT SUM(SUM_TIMER_WAIT) 
            FROM performance_schema.events_statements_summary_by_digest)) * 100, 2) AS pct_total_time
    FROM performance_schema.events_statements_summary_by_digest
    WHERE SCHEMA_NAME NOT IN ('performance_schema', 'information_schema', 'mysql')
        AND DIGEST_TEXT NOT LIKE '%performance_schema%'
    ORDER BY SUM_TIMER_WAIT DESC
    LIMIT 20;
    "
    
    # Section 3: Top Queries by Execution Count
    print_header "3. TOP 10 QUERIES BY EXECUTION COUNT"
    run_query "
    SELECT 
        SUBSTRING(DIGEST_TEXT, 1, 100) AS query_sample,
        COUNT_STAR AS exec_count,
        ROUND(AVG_TIMER_WAIT/1000000000000, 3) AS avg_seconds,
        ROUND(SUM_TIMER_WAIT/1000000000000, 2) AS total_seconds
    FROM performance_schema.events_statements_summary_by_digest
    WHERE SCHEMA_NAME NOT IN ('performance_schema', 'information_schema', 'mysql')
    ORDER BY COUNT_STAR DESC
    LIMIT 10;
    "
    
    # Section 4: Table I/O Statistics
    print_header "4. TOP 10 TABLES BY I/O ACTIVITY"
    run_query "
    SELECT 
        OBJECT_SCHEMA AS database_name,
        OBJECT_NAME AS table_name,
        COUNT_READ AS read_operations,
        COUNT_WRITE AS write_operations,
        COUNT_READ + COUNT_WRITE AS total_operations,
        ROUND(SUM_TIMER_READ/1000000000000, 2) AS read_seconds,
        ROUND(SUM_TIMER_WRITE/1000000000000, 2) AS write_seconds
    FROM performance_schema.table_io_waits_summary_by_table
    WHERE OBJECT_SCHEMA NOT IN ('performance_schema', 'information_schema', 'mysql')
    ORDER BY total_operations DESC
    LIMIT 10;
    "
    
    # Section 5: Index Usage Analysis
    print_header "5. UNUSED INDEXES (CANDIDATES FOR REMOVAL)"
    run_query "
    SELECT 
        t.OBJECT_SCHEMA AS database_name,
        t.OBJECT_NAME AS table_name,
        t.INDEX_NAME AS index_name,
        t.COUNT_READ AS index_reads,
        ROUND((s.data_length + s.index_length) / 1024 / 1024, 2) AS table_size_mb
    FROM performance_schema.table_io_waits_summary_by_index_usage t
    JOIN information_schema.tables s 
        ON t.OBJECT_SCHEMA = s.table_schema 
        AND t.OBJECT_NAME = s.table_name
    WHERE t.INDEX_NAME IS NOT NULL
        AND t.INDEX_NAME != 'PRIMARY'
        AND t.COUNT_READ = 0
        AND t.OBJECT_SCHEMA NOT IN ('performance_schema', 'information_schema', 'mysql')
    ORDER BY table_size_mb DESC
    LIMIT 20;
    "
    
    # Section 6: Missing Indexes (Full Table Scans)
    print_header "6. QUERIES WITH FULL TABLE SCANS (MISSING INDEXES?)"
    run_query "
    SELECT 
        SUBSTRING(DIGEST_TEXT, 1, 100) AS query_sample,
        COUNT_STAR AS exec_count,
        SUM_NO_INDEX_USED AS full_scans,
        SUM_NO_GOOD_INDEX_USED AS bad_index_scans,
        ROUND(AVG_TIMER_WAIT/1000000000000, 3) AS avg_seconds
    FROM performance_schema.events_statements_summary_by_digest
    WHERE SUM_NO_INDEX_USED > 0 OR SUM_NO_GOOD_INDEX_USED > 0
    ORDER BY SUM_NO_INDEX_USED DESC, COUNT_STAR DESC
    LIMIT 10;
    "
    
    # Section 7: InnoDB Buffer Pool Efficiency
    print_header "7. INNODB BUFFER POOL EFFICIENCY"
    run_query "
    SELECT 
        ROUND((1 - (Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests)) * 100, 2) 
            AS buffer_pool_hit_rate_pct
    FROM 
        (SELECT VARIABLE_VALUE AS Innodb_buffer_pool_reads 
         FROM performance_schema.global_status 
         WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') AS reads,
        (SELECT VARIABLE_VALUE AS Innodb_buffer_pool_read_requests 
         FROM performance_schema.global_status 
         WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests') AS requests;
    "
    
    echo ""
    echo "Buffer Pool Status:"
    run_query "
    SELECT 
        VARIABLE_NAME,
        VARIABLE_VALUE
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME LIKE 'Innodb_buffer_pool%'
        AND VARIABLE_NAME IN (
            'Innodb_buffer_pool_pages_total',
            'Innodb_buffer_pool_pages_free',
            'Innodb_buffer_pool_pages_dirty',
            'Innodb_buffer_pool_read_requests',
            'Innodb_buffer_pool_reads'
        );
    "
    
    # Section 8: Connection Statistics
    print_header "8. CONNECTION STATISTICS"
    run_query "
    SELECT 
        VARIABLE_NAME,
        VARIABLE_VALUE
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME IN (
        'Threads_connected',
        'Threads_running',
        'Max_used_connections',
        'Aborted_connects',
        'Aborted_clients',
        'Connection_errors_max_connections'
    );
    "
    
    # Section 9: Temporary Table Usage
    print_header "9. TEMPORARY TABLE USAGE"
    run_query "
    SELECT 
        VARIABLE_NAME,
        VARIABLE_VALUE
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME LIKE '%tmp%'
        AND VARIABLE_NAME IN (
            'Created_tmp_disk_tables',
            'Created_tmp_tables',
            'Created_tmp_files'
        );
    "
    
    # Calculate temp table to disk ratio
    echo ""
    echo "Temporary Tables to Disk Ratio:"
    run_query "
    SELECT 
        ROUND((tmp_disk.VARIABLE_VALUE / tmp_total.VARIABLE_VALUE) * 100, 2) 
            AS temp_tables_to_disk_pct
    FROM 
        (SELECT VARIABLE_VALUE 
         FROM performance_schema.global_status 
         WHERE VARIABLE_NAME = 'Created_tmp_disk_tables') AS tmp_disk,
        (SELECT VARIABLE_VALUE 
         FROM performance_schema.global_status 
         WHERE VARIABLE_NAME = 'Created_tmp_tables') AS tmp_total;
    "
    
    # Section 10: Table Sizes
    print_header "10. TOP 20 LARGEST TABLES"
    run_query "
    SELECT 
        table_schema AS database_name,
        table_name,
        ROUND((data_length + index_length) / 1024 / 1024 / 1024, 2) AS total_size_gb,
        ROUND(data_length / 1024 / 1024 / 1024, 2) AS data_size_gb,
        ROUND(index_length / 1024 / 1024 / 1024, 2) AS index_size_gb,
        table_rows AS estimated_rows
    FROM information_schema.tables
    WHERE table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys')
    ORDER BY (data_length + index_length) DESC
    LIMIT 20;
    "
    
    # Section 11: Replication Status (if applicable)
    print_header "11. REPLICATION STATUS"
    echo "Checking replication status..."
    if run_query "SHOW SLAVE STATUS\G" | grep -q "Slave_IO_Running"; then
        run_query "SHOW SLAVE STATUS\G"
    else
        echo "Not configured as replica or no replication running."
    fi
    
    # Section 12: Recommendations
    print_header "12. RECOMMENDATIONS"
    
    echo "Based on this analysis, consider the following:"
    echo ""
    echo "1. Review queries with high total execution time (Section 2)"
    echo "2. Add indexes for queries with full table scans (Section 6)"
    echo "3. Consider removing unused indexes (Section 5)"
    echo "4. Buffer pool hit rate should be >99% (Section 7)"
    echo "5. Temp tables to disk should be <25% (Section 9)"
    echo "6. Monitor replication lag if applicable (Section 11)"
    echo ""
    
    print_header "END OF REPORT"
    
} | tee "${REPORT_FILE}"

echo ""
echo -e "${GREEN}Report saved to: ${REPORT_FILE}${NC}"
echo ""
echo -e "${YELLOW}Key Performance Indicators:${NC}"
echo -e "- Buffer Pool Hit Rate: Should be >99%"
echo -e "- Temp Tables to Disk: Should be <25%"
echo -e "- Connection Usage: Should be <80% of max_connections"
echo -e "- Replication Lag: Should be <5 seconds"
echo ""