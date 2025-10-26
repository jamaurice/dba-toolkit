#!/bin/bash
#
# database_health_check.sh
# 
# Comprehensive database health check for MySQL and PostgreSQL
# Author: Jamaurice Holt
# Usage: ./database_health_check.sh [db_type] [host]
#
# Checks: connections, performance, disk space, replication, backups
#

set -euo pipefail

# Configuration
DB_TYPE="${1:-mysql}"
DB_HOST="${2:-localhost}"
REPORT_DATE=$(date +"%Y-%m-%d_%H-%M-%S")
REPORT_FILE="health_check_${DB_TYPE}_${REPORT_DATE}.txt"

# Thresholds (customize as needed)
CPU_THRESHOLD=80
MEMORY_THRESHOLD=90
DISK_THRESHOLD=90
CONNECTION_THRESHOLD=80
REPLICATION_LAG_THRESHOLD=10

# MySQL credentials
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-}"

# PostgreSQL credentials
PG_USER="${PG_USER:-postgres}"
PG_PORT="${PG_PORT:-5432}"

# Health check status
HEALTH_STATUS="HEALTHY"
WARNINGS=0
ERRORS=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to print section header
print_header() {
    echo "================================================================"
    echo "$1"
    echo "================================================================"
    echo ""
}

# Function to log error
log_error() {
    echo -e "${RED}✗ ERROR: $1${NC}"
    ERRORS=$((ERRORS + 1))
    HEALTH_STATUS="CRITICAL"
}

# Function to log warning
log_warning() {
    echo -e "${YELLOW}⚠ WARNING: $1${NC}"
    WARNINGS=$((WARNINGS + 1))
    if [ "$HEALTH_STATUS" = "HEALTHY" ]; then
        HEALTH_STATUS="WARNING"
    fi
}

# Function to log success
log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Function to log info
log_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Start health check
{
    print_header "Database Health Check - $(date)"
    
    echo "Database Type: ${DB_TYPE}"
    echo "Host: ${DB_HOST}"
    echo "Report: ${REPORT_FILE}"
    echo ""
    
    if [ "$DB_TYPE" = "mysql" ]; then
        # MySQL Health Checks
        
        # Section 1: Connection Test
        print_header "1. DATABASE CONNECTION"
        
        if mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "SELECT 1" &>/dev/null; then
            log_success "Database connection successful"
            
            VERSION=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -B -e "SELECT VERSION();" 2>/dev/null)
            echo "MySQL Version: ${VERSION}"
            
            UPTIME=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -B -e "SHOW GLOBAL STATUS LIKE 'Uptime';" 2>/dev/null | awk '{print $2}')
            UPTIME_DAYS=$(echo "scale=1; $UPTIME / 86400" | bc)
            echo "Uptime: ${UPTIME_DAYS} days"
        else
            log_error "Cannot connect to MySQL database"
            exit 1
        fi
        
        # Section 2: Connection Usage
        print_header "2. CONNECTION USAGE"
        
        CURRENT_CONN=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -B \
            -e "SHOW GLOBAL STATUS LIKE 'Threads_connected';" 2>/dev/null | awk '{print $2}')
        
        MAX_CONN=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -B \
            -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | awk '{print $2}')
        
        CONN_PCT=$(echo "scale=2; ($CURRENT_CONN / $MAX_CONN) * 100" | bc)
        
        echo "Current Connections: ${CURRENT_CONN}"
        echo "Max Connections: ${MAX_CONN}"
        echo "Usage: ${CONN_PCT}%"
        
        if (( $(echo "$CONN_PCT > $CONNECTION_THRESHOLD" | bc -l) )); then
            log_warning "Connection usage is high: ${CONN_PCT}% (threshold: ${CONNECTION_THRESHOLD}%)"
        else
            log_success "Connection usage is healthy: ${CONN_PCT}%"
        fi
        
        # Section 3: InnoDB Buffer Pool
        print_header "3. INNODB BUFFER POOL EFFICIENCY"
        
        BUFFER_POOL_SIZE=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -B \
            -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null | awk '{print $2}')
        BUFFER_POOL_GB=$(echo "scale=2; $BUFFER_POOL_SIZE / 1024 / 1024 / 1024" | bc)
        
        echo "Buffer Pool Size: ${BUFFER_POOL_GB} GB"
        
        # Calculate hit rate
        READS=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -B \
            -e "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_reads';" 2>/dev/null | awk '{print $2}')
        
        REQUESTS=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -B \
            -e "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read_requests';" 2>/dev/null | awk '{print $2}')
        
        if [ "$REQUESTS" -gt 0 ]; then
            HIT_RATE=$(echo "scale=2; (1 - ($READS / $REQUESTS)) * 100" | bc)
            echo "Buffer Pool Hit Rate: ${HIT_RATE}%"
            
            if (( $(echo "$HIT_RATE < 99" | bc -l) )); then
                log_warning "Buffer pool hit rate is low: ${HIT_RATE}% (target: >99%)"
            else
                log_success "Buffer pool hit rate is excellent: ${HIT_RATE}%"
            fi
        fi
        
        # Section 4: Slow Query Log
        print_header "4. SLOW QUERIES"
        
        SLOW_QUERIES=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -B \
            -e "SHOW GLOBAL STATUS LIKE 'Slow_queries';" 2>/dev/null | awk '{print $2}')
        
        echo "Total Slow Queries: ${SLOW_QUERIES}"
        
        if [ "$SLOW_QUERIES" -gt 100 ]; then
            log_warning "High number of slow queries: ${SLOW_QUERIES}"
        else
            log_success "Slow query count is acceptable"
        fi
        
        # Section 5: Table Locks
        print_header "5. TABLE LOCKS"
        
        LOCKS_WAITED=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -B \
            -e "SHOW GLOBAL STATUS LIKE 'Table_locks_waited';" 2>/dev/null | awk '{print $2}')
        
        LOCKS_IMMEDIATE=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -B \
            -e "SHOW GLOBAL STATUS LIKE 'Table_locks_immediate';" 2>/dev/null | awk '{print $2}')
        
        echo "Locks Waited: ${LOCKS_WAITED}"
        echo "Locks Immediate: ${LOCKS_IMMEDIATE}"
        
        if [ "$LOCKS_WAITED" -gt 1000 ]; then
            log_warning "High table lock contention: ${LOCKS_WAITED} locks waited"
        else
            log_success "Table lock contention is low"
        fi
        
        # Section 6: Replication Status
        print_header "6. REPLICATION STATUS"
        
        if mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -q "Slave_IO_Running"; then
            SLAVE_IO=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running:" | awk '{print $2}')
            SLAVE_SQL=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_SQL_Running:" | awk '{print $2}')
            SECONDS_BEHIND=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master:" | awk '{print $2}')
            
            echo "Slave_IO_Running: ${SLAVE_IO}"
            echo "Slave_SQL_Running: ${SLAVE_SQL}"
            echo "Seconds_Behind_Master: ${SECONDS_BEHIND}"
            
            if [ "$SLAVE_IO" != "Yes" ] || [ "$SLAVE_SQL" != "Yes" ]; then
                log_error "Replication is not running"
            elif [ "$SECONDS_BEHIND" != "NULL" ] && [ "$SECONDS_BEHIND" -gt "$REPLICATION_LAG_THRESHOLD" ]; then
                log_warning "Replication lag is high: ${SECONDS_BEHIND}s"
            else
                log_success "Replication is healthy"
            fi
        else
            log_info "Not configured as a replica"
        fi
        
        # Section 7: Disk Space
        print_header "7. DISK SPACE"
        
        DATADIR=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -B \
            -e "SHOW VARIABLES LIKE 'datadir';" 2>/dev/null | awk '{print $2}')
        
        echo "Data Directory: ${DATADIR}"
        
        if [ "$DB_HOST" = "localhost" ] || [ "$DB_HOST" = "127.0.0.1" ]; then
            DISK_USAGE=$(df -h "$DATADIR" | awk 'NR==2 {print $5}' | sed 's/%//')
            DISK_AVAIL=$(df -h "$DATADIR" | awk 'NR==2 {print $4}')
            
            echo "Disk Usage: ${DISK_USAGE}%"
            echo "Available: ${DISK_AVAIL}"
            
            if [ "$DISK_USAGE" -gt "$DISK_THRESHOLD" ]; then
                log_warning "Disk usage is high: ${DISK_USAGE}%"
            else
                log_success "Disk space is sufficient: ${DISK_USAGE}% used"
            fi
        else
            log_info "Remote host - cannot check disk space"
        fi
        
        # Section 8: Binary Logs
        print_header "8. BINARY LOGS"
        
        BINLOG_COUNT=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "SHOW BINARY LOGS;" 2>/dev/null | wc -l)
        BINLOG_COUNT=$((BINLOG_COUNT - 1))
        
        echo "Binary Log Count: ${BINLOG_COUNT}"
        
        if [ "$BINLOG_COUNT" -gt 100 ]; then
            log_warning "High number of binary logs: ${BINLOG_COUNT} (consider purging old logs)"
        else
            log_success "Binary log count is reasonable"
        fi
        
    elif [ "$DB_TYPE" = "postgres" ] || [ "$DB_TYPE" = "postgresql" ]; then
        # PostgreSQL Health Checks
        
        # Section 1: Connection Test
        print_header "1. DATABASE CONNECTION"
        
        if psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "SELECT 1" &>/dev/null; then
            log_success "Database connection successful"
            
            VERSION=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t -c "SELECT version();" 2>/dev/null | xargs)
            echo "PostgreSQL Version: ${VERSION}"
            
            UPTIME=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t \
                -c "SELECT date_trunc('day', now() - pg_postmaster_start_time());" 2>/dev/null | xargs)
            echo "Uptime: ${UPTIME}"
        else
            log_error "Cannot connect to PostgreSQL database"
            exit 1
        fi
        
        # Section 2: Connection Usage
        print_header "2. CONNECTION USAGE"
        
        CURRENT_CONN=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t \
            -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | xargs)
        
        MAX_CONN=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t \
            -c "SHOW max_connections;" 2>/dev/null | xargs)
        
        CONN_PCT=$(echo "scale=2; ($CURRENT_CONN / $MAX_CONN) * 100" | bc)
        
        echo "Current Connections: ${CURRENT_CONN}"
        echo "Max Connections: ${MAX_CONN}"
        echo "Usage: ${CONN_PCT}%"
        
        if (( $(echo "$CONN_PCT > $CONNECTION_THRESHOLD" | bc -l) )); then
            log_warning "Connection usage is high: ${CONN_PCT}% (threshold: ${CONNECTION_THRESHOLD}%)"
        else
            log_success "Connection usage is healthy: ${CONN_PCT}%"
        fi
        
        # Section 3: Cache Hit Ratio
        print_header "3. CACHE HIT RATIO"
        
        CACHE_HIT=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t -c "
            SELECT ROUND((sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0)) * 100, 2) 
            FROM pg_statio_user_tables;" 2>/dev/null | xargs)
        
        echo "Cache Hit Ratio: ${CACHE_HIT}%"
        
        if (( $(echo "$CACHE_HIT < 95" | bc -l) )); then
            log_warning "Cache hit ratio is low: ${CACHE_HIT}% (target: >95%)"
        else
            log_success "Cache hit ratio is excellent: ${CACHE_HIT}%"
        fi
        
        # Section 4: Table Bloat
        print_header "4. TABLE BLOAT (DEAD ROWS)"
        
        BLOAT_TABLES=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t -c "
            SELECT COUNT(*) 
            FROM pg_stat_user_tables 
            WHERE n_dead_tup > 1000 
            AND (n_dead_tup::float / NULLIF(n_live_tup, 0)) > 0.1;" 2>/dev/null | xargs)
        
        echo "Tables with >10% dead rows: ${BLOAT_TABLES}"
        
        if [ "$BLOAT_TABLES" -gt 5 ]; then
            log_warning "Multiple tables need VACUUM: ${BLOAT_TABLES} tables"
        else
            log_success "Table bloat is under control"
        fi
        
        # Section 5: Long-Running Queries
        print_header "5. LONG-RUNNING QUERIES"
        
        LONG_QUERIES=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t -c "
            SELECT COUNT(*) 
            FROM pg_stat_activity 
            WHERE state != 'idle' 
            AND (now() - query_start) > interval '5 minutes';" 2>/dev/null | xargs)
        
        echo "Queries running >5 minutes: ${LONG_QUERIES}"
        
        if [ "$LONG_QUERIES" -gt 0 ]; then
            log_warning "Found ${LONG_QUERIES} long-running queries"
        else
            log_success "No long-running queries detected"
        fi
        
        # Section 6: Replication Status
        print_header "6. REPLICATION STATUS"
        
        IS_STANDBY=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t \
            -c "SELECT pg_is_in_recovery();" 2>/dev/null | xargs)
        
        if [ "$IS_STANDBY" = "t" ]; then
            LAG=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t -c "
                SELECT EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp());" 2>/dev/null | xargs)
            
            LAG_SEC=$(echo "$LAG" | awk '{print int($1)}')
            echo "Replication Lag: ${LAG_SEC} seconds"
            
            if [ "$LAG_SEC" -gt "$REPLICATION_LAG_THRESHOLD" ]; then
                log_warning "Replication lag is high: ${LAG_SEC}s"
            else
                log_success "Replication lag is acceptable: ${LAG_SEC}s"
            fi
        else
            log_info "Not in recovery mode (primary server or standalone)"
        fi
        
        # Section 7: Database Sizes
        print_header "7. DATABASE SIZES"
        
        psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "
            SELECT 
                datname,
                pg_size_pretty(pg_database_size(datname)) AS size
            FROM pg_database
            WHERE datname NOT IN ('template0', 'template1')
            ORDER BY pg_database_size(datname) DESC
            LIMIT 5;" 2>/dev/null
        
        log_success "Database sizes retrieved"
        
        # Section 8: WAL Files
        print_header "8. WAL FILES"
        
        WAL_COUNT=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t -c "
            SELECT COUNT(*) FROM pg_ls_waldir();" 2>/dev/null | xargs)
        
        echo "WAL Files: ${WAL_COUNT}"
        
        if [ "$WAL_COUNT" -gt 100 ]; then
            log_warning "High number of WAL files: ${WAL_COUNT}"
        else
            log_success "WAL file count is normal"
        fi
    fi
    
    # Final Summary
    print_header "HEALTH CHECK SUMMARY"
    
    echo "Overall Status: ${HEALTH_STATUS}"
    echo "Errors: ${ERRORS}"
    echo "Warnings: ${WARNINGS}"
    echo ""
    
    if [ "$HEALTH_STATUS" = "HEALTHY" ]; then
        echo -e "${GREEN}✓ Database is HEALTHY${NC}"
    elif [ "$HEALTH_STATUS" = "WARNING" ]; then
        echo -e "${YELLOW}⚠ Database has WARNINGS - review recommended${NC}"
    else
        echo -e "${RED}✗ Database is in CRITICAL state - immediate action required${NC}"
    fi
    
    print_header "END OF HEALTH CHECK"
    
} | tee "${REPORT_FILE}"

echo ""
echo "Health check report saved to: ${REPORT_FILE}"
echo ""

# Exit with appropriate code
if [ "$HEALTH_STATUS" = "CRITICAL" ]; then
    exit 2
elif [ "$HEALTH_STATUS" = "WARNING" ]; then
    exit 1
else
    exit 0
fi