#!/bin/bash
#
# postgres_performance_report.sh
# 
# Generates comprehensive PostgreSQL performance report using pg_stat_statements
# Author: Jamaurice Holt
# Usage: ./postgres_performance_report.sh [host] [port] [database] [user]
#
# Requirements: pg_stat_statements extension must be enabled
# To enable: CREATE EXTENSION pg_stat_statements;
#

set -euo pipefail

# Configuration
PG_HOST="${1:-localhost}"
PG_PORT="${2:-5432}"
PG_DATABASE="${3:-postgres}"
PG_USER="${4:-postgres}"
REPORT_DATE=$(date +"%Y-%m-%d_%H-%M-%S")
REPORT_FILE="postgres_performance_report_${REPORT_DATE}.txt"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to execute PostgreSQL query
run_query() {
    psql -h "${PG_HOST}" -p "${PG_PORT}" -d "${PG_DATABASE}" -U "${PG_USER}" -c "$1" 2>/dev/null
}

# Function to print section header
print_header() {
    echo "================================================================"
    echo "$1"
    echo "================================================================"
    echo ""
}

# Check if pg_stat_statements is enabled
check_extension() {
    if ! run_query "SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements';" | grep -q "1 row"; then
        echo -e "${RED}ERROR: pg_stat_statements extension is not installed.${NC}"
        echo "Please run: CREATE EXTENSION pg_stat_statements;"
        exit 1
    fi
}

# Start report
{
    print_header "PostgreSQL Performance Report - $(date)"
    
    echo "Host: ${PG_HOST}:${PG_PORT}"
    echo "Database: ${PG_DATABASE}"
    echo "Report Generated: ${REPORT_DATE}"
    echo ""
    
    # Verify pg_stat_statements is available
    check_extension
    
    # Section 1: Server Information
    print_header "1. SERVER INFORMATION"
    run_query "SELECT version();"
    run_query "SELECT name, setting, unit FROM pg_settings WHERE name IN 
        ('shared_buffers', 'effective_cache_size', 'work_mem', 'maintenance_work_mem', 'max_connections');"
    run_query "SELECT pg_postmaster_start_time() AS server_start_time, 
        now() - pg_postmaster_start_time() AS uptime;"
    
    # Section 2: Database Size
    print_header "2. DATABASE SIZES"
    run_query "
    SELECT 
        datname AS database_name,
        pg_size_pretty(pg_database_size(datname)) AS size
    FROM pg_database
    WHERE datname NOT IN ('template0', 'template1')
    ORDER BY pg_database_size(datname) DESC;
    "
    
    # Section 3: Top Slow Queries by Total Time
    print_header "3. TOP 20 QUERIES BY TOTAL EXECUTION TIME"
    run_query "
    SELECT 
        SUBSTRING(query, 1, 100) AS query_sample,
        calls AS exec_count,
        ROUND(total_exec_time::numeric / 1000, 2) AS total_seconds,
        ROUND(mean_exec_time::numeric, 2) AS avg_milliseconds,
        ROUND(max_exec_time::numeric, 2) AS max_milliseconds,
        ROUND((total_exec_time / sum(total_exec_time) OVER ()) * 100, 2) AS pct_total_time
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
        AND query NOT LIKE '%pg_stat_statements%'
    ORDER BY total_exec_time DESC
    LIMIT 20;
    "
    
    # Section 4: Top Queries by Execution Count
    print_header "4. TOP 10 QUERIES BY EXECUTION COUNT"
    run_query "
    SELECT 
        SUBSTRING(query, 1, 100) AS query_sample,
        calls AS exec_count,
        ROUND(mean_exec_time::numeric, 2) AS avg_milliseconds,
        ROUND(total_exec_time::numeric / 1000, 2) AS total_seconds
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
    ORDER BY calls DESC
    LIMIT 10;
    "
    
    # Section 5: Slowest Individual Queries
    print_header "5. TOP 10 SLOWEST INDIVIDUAL QUERY EXECUTIONS"
    run_query "
    SELECT 
        SUBSTRING(query, 1, 100) AS query_sample,
        calls AS exec_count,
        ROUND(max_exec_time::numeric, 2) AS max_milliseconds,
        ROUND(mean_exec_time::numeric, 2) AS avg_milliseconds,
        ROUND(stddev_exec_time::numeric, 2) AS stddev_milliseconds
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
    ORDER BY max_exec_time DESC
    LIMIT 10;
    "
    
    # Section 6: Table Sizes and Bloat
    print_header "6. TOP 20 LARGEST TABLES"
    run_query "
    SELECT 
        schemaname || '.' || tablename AS table_name,
        pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
        pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
        pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - 
            pg_relation_size(schemaname||'.'||tablename)) AS indexes_size,
        n_live_tup AS live_rows,
        n_dead_tup AS dead_rows,
        CASE 
            WHEN n_live_tup > 0 
            THEN ROUND((n_dead_tup::numeric / n_live_tup::numeric) * 100, 2)
            ELSE 0
        END AS dead_row_pct
    FROM pg_stat_user_tables
    ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
    LIMIT 20;
    "
    
    # Section 7: Index Usage Statistics
    print_header "7. UNUSED INDEXES (CANDIDATES FOR REMOVAL)"
    run_query "
    SELECT 
        schemaname || '.' || tablename AS table_name,
        indexname AS index_name,
        pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
        idx_scan AS index_scans,
        idx_tup_read AS rows_read,
        idx_tup_fetch AS rows_fetched
    FROM pg_stat_user_indexes
    WHERE idx_scan = 0
        AND indexrelname NOT LIKE '%_pkey'
    ORDER BY pg_relation_size(indexrelid) DESC
    LIMIT 20;
    "
    
    # Section 8: Table Scan Statistics
    print_header "8. TABLES WITH HIGH SEQUENTIAL SCANS (MISSING INDEXES?)"
    run_query "
    SELECT 
        schemaname || '.' || tablename AS table_name,
        seq_scan AS sequential_scans,
        seq_tup_read AS rows_read_seq_scan,
        idx_scan AS index_scans,
        n_live_tup AS live_rows,
        CASE 
            WHEN seq_scan > 0 
            THEN ROUND((seq_tup_read::numeric / seq_scan::numeric), 0)
            ELSE 0
        END AS avg_rows_per_seq_scan,
        pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size
    FROM pg_stat_user_tables
    WHERE seq_scan > 100
        AND n_live_tup > 10000
    ORDER BY seq_scan DESC
    LIMIT 10;
    "
    
    # Section 9: Cache Hit Ratio
    print_header "9. CACHE HIT RATIO (BUFFER CACHE EFFICIENCY)"
    run_query "
    SELECT 
        'Buffer Cache' AS cache_type,
        ROUND((sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0)) * 100, 2) 
            AS hit_ratio_pct
    FROM pg_statio_user_tables
    UNION ALL
    SELECT 
        'Index Cache' AS cache_type,
        ROUND((sum(idx_blks_hit) / nullif(sum(idx_blks_hit) + sum(idx_blks_read), 0)) * 100, 2) 
            AS hit_ratio_pct
    FROM pg_statio_user_tables;
    "
    
    # Section 10: Table I/O Statistics
    print_header "10. TOP 10 TABLES BY I/O ACTIVITY"
    run_query "
    SELECT 
        schemaname || '.' || tablename AS table_name,
        heap_blks_read AS heap_reads,
        heap_blks_hit AS heap_hits,
        idx_blks_read AS index_reads,
        idx_blks_hit AS index_hits,
        heap_blks_read + idx_blks_read AS total_disk_reads,
        CASE 
            WHEN (heap_blks_hit + idx_blks_hit) > 0
            THEN ROUND((heap_blks_read + idx_blks_read)::numeric / 
                (heap_blks_hit + idx_blks_hit + heap_blks_read + idx_blks_read)::numeric * 100, 2)
            ELSE 0
        END AS disk_read_pct
    FROM pg_statio_user_tables
    ORDER BY (heap_blks_read + idx_blks_read) DESC
    LIMIT 10;
    "
    
    # Section 11: VACUUM and ANALYZE Status
    print_header "11. VACUUM AND ANALYZE STATUS"
    run_query "
    SELECT 
        schemaname || '.' || tablename AS table_name,
        last_vacuum,
        last_autovacuum,
        last_analyze,
        last_autoanalyze,
        vacuum_count,
        autovacuum_count,
        analyze_count,
        autoanalyze_count,
        n_dead_tup AS dead_rows
    FROM pg_stat_user_tables
    WHERE n_dead_tup > 1000
    ORDER BY n_dead_tup DESC
    LIMIT 10;
    "
    
    # Section 12: Connection Statistics
    print_header "12. CONNECTION STATISTICS"
    run_query "
    SELECT 
        count(*) AS total_connections,
        count(*) FILTER (WHERE state = 'active') AS active_connections,
        count(*) FILTER (WHERE state = 'idle') AS idle_connections,
        count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction,
        count(*) FILTER (WHERE wait_event_type IS NOT NULL) AS waiting_connections
    FROM pg_stat_activity
    WHERE pid != pg_backend_pid();
    "
    
    echo ""
    echo "Active Queries:"
    run_query "
    SELECT 
        pid,
        usename AS username,
        application_name,
        client_addr,
        state,
        EXTRACT(EPOCH FROM (now() - query_start)) AS query_duration_seconds,
        SUBSTRING(query, 1, 100) AS query_sample
    FROM pg_stat_activity
    WHERE state = 'active'
        AND pid != pg_backend_pid()
    ORDER BY query_start;
    "
    
    # Section 13: Long-Running Queries
    print_header "13. LONG-RUNNING QUERIES (>60 SECONDS)"
    run_query "
    SELECT 
        pid,
        usename AS username,
        application_name,
        client_addr,
        EXTRACT(EPOCH FROM (now() - query_start)) AS duration_seconds,
        state,
        SUBSTRING(query, 1, 150) AS query_sample
    FROM pg_stat_activity
    WHERE state != 'idle'
        AND query NOT LIKE '%pg_stat_activity%'
        AND (now() - query_start) > interval '60 seconds'
    ORDER BY query_start;
    "
    
    # Section 14: Locks
    print_header "14. CURRENT LOCKS"
    run_query "
    SELECT 
        locktype,
        database,
        relation::regclass AS table_name,
        mode,
        granted,
        count(*) AS lock_count
    FROM pg_locks
    WHERE relation IS NOT NULL
    GROUP BY locktype, database, relation, mode, granted
    ORDER BY lock_count DESC
    LIMIT 20;
    "
    
    # Section 15: Replication Status (if applicable)
    print_header "15. REPLICATION STATUS"
    echo "Checking replication status..."
    
    echo ""
    echo "Replication Slots:"
    run_query "SELECT * FROM pg_replication_slots;" || echo "No replication slots configured."
    
    echo ""
    echo "Replication Statistics:"
    run_query "
    SELECT 
        client_addr,
        application_name,
        state,
        sync_state,
        pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn) AS send_lag_bytes,
        pg_wal_lsn_diff(sent_lsn, write_lsn) AS write_lag_bytes,
        pg_wal_lsn_diff(write_lsn, flush_lsn) AS flush_lag_bytes,
        pg_wal_lsn_diff(flush_lsn, replay_lsn) AS replay_lag_bytes
    FROM pg_stat_replication;
    " || echo "Not configured as primary or no replicas connected."
    
    # Section 16: Database Statistics
    print_header "16. DATABASE STATISTICS"
    run_query "
    SELECT 
        datname AS database_name,
        numbackends AS active_connections,
        xact_commit AS transactions_committed,
        xact_rollback AS transactions_rolled_back,
        blks_read AS blocks_read_from_disk,
        blks_hit AS blocks_found_in_cache,
        CASE 
            WHEN (blks_hit + blks_read) > 0
            THEN ROUND((blks_hit::numeric / (blks_hit + blks_read)::numeric) * 100, 2)
            ELSE 0
        END AS cache_hit_ratio_pct,
        tup_returned AS rows_returned,
        tup_fetched AS rows_fetched,
        tup_inserted AS rows_inserted,
        tup_updated AS rows_updated,
        tup_deleted AS rows_deleted
    FROM pg_stat_database
    WHERE datname NOT IN ('template0', 'template1')
    ORDER BY datname;
    "
    
    # Section 17: Recommendations
    print_header "17. RECOMMENDATIONS"
    
    echo "Based on this analysis, consider the following:"
    echo ""
    echo "1. Review queries with high total execution time (Section 3)"
    echo "2. Add indexes for tables with high sequential scans (Section 8)"
    echo "3. Consider removing unused indexes (Section 7)"
    echo "4. Cache hit ratio should be >95% (Section 9)"
    echo "5. Run VACUUM on tables with high dead row percentage (Section 6)"
    echo "6. Monitor long-running queries (Section 13)"
    echo "7. Check replication lag if applicable (Section 15)"
    echo ""
    
    print_header "END OF REPORT"
    
} | tee "${REPORT_FILE}"

echo ""
echo -e "${GREEN}Report saved to: ${REPORT_FILE}${NC}"
echo ""
echo -e "${YELLOW}Key Performance Indicators:${NC}"
echo -e "- Cache Hit Ratio: Should be >95%"
echo -e "- Dead Row Percentage: Should be <10% per table"
echo -e "- Connection Usage: Should be <80% of max_connections"
echo -e "- Replication Lag: Should be <1MB for streaming replication"
echo ""