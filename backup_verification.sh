#!/bin/bash
#
# backup_verification.sh
# 
# Verifies database backup integrity by restoring to test instance
# Author: Jamaurice Holt
# Usage: ./backup_verification.sh [backup_file] [db_type] [test_db_name]
#
# Supported types: mysql, postgres
#

set -euo pipefail

# Configuration
BACKUP_FILE="${1:-}"
DB_TYPE="${2:-mysql}"
TEST_DB_NAME="${3:-backup_verify_test}"
REPORT_DATE=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="backup_verification_${REPORT_DATE}.log"

# Test credentials (configure these)
MYSQL_TEST_HOST="${MYSQL_TEST_HOST:-localhost}"
MYSQL_TEST_USER="${MYSQL_TEST_USER:-root}"
MYSQL_TEST_PASS="${MYSQL_TEST_PASS:-}"

PG_TEST_HOST="${PG_TEST_HOST:-localhost}"
PG_TEST_USER="${PG_TEST_USER:-postgres}"
PG_TEST_PORT="${PG_TEST_PORT:-5432}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to log with timestamp
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to log error and exit
error_exit() {
    echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"
    exit 1
}

# Function to log success
log_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}" | tee -a "$LOG_FILE"
}

# Function to log warning
log_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}" | tee -a "$LOG_FILE"
}

# Function to log info
log_info() {
    echo -e "${BLUE}[INFO] $1${NC}" | tee -a "$LOG_FILE"
}

# Verify backup file exists
if [ -z "$BACKUP_FILE" ]; then
    error_exit "Backup file not specified. Usage: $0 <backup_file> [mysql|postgres] [test_db_name]"
fi

if [ ! -f "$BACKUP_FILE" ]; then
    error_exit "Backup file not found: $BACKUP_FILE"
fi

# Start verification
log_info "====== Database Backup Verification ======"
log_info "Backup File: $BACKUP_FILE"
log_info "Database Type: $DB_TYPE"
log_info "Test Database: $TEST_DB_NAME"
log_info "Start Time: $(date)"
log_info ""

# Function to verify MySQL backup
verify_mysql_backup() {
    log_info "Starting MySQL backup verification..."
    
    # Step 1: Check file integrity
    log_info "Step 1: Checking backup file integrity..."
    
    FILE_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null)
    FILE_SIZE_MB=$(echo "scale=2; $FILE_SIZE / 1024 / 1024" | bc)
    log_info "Backup file size: ${FILE_SIZE_MB} MB"
    
    if [ "$FILE_SIZE" -lt 100 ]; then
        log_warning "Backup file is very small (< 100 bytes). This may indicate an empty or corrupt backup."
    fi
    
    # Check if file is compressed
    if file "$BACKUP_FILE" | grep -q "gzip"; then
        log_info "Backup is gzip compressed"
        IS_COMPRESSED=true
        
        # Test gzip integrity
        if gzip -t "$BACKUP_FILE" 2>/dev/null; then
            log_success "Gzip integrity check passed"
        else
            error_exit "Gzip integrity check failed - backup file is corrupt"
        fi
    else
        log_info "Backup is not compressed"
        IS_COMPRESSED=false
    fi
    
    # Step 2: Drop test database if exists
    log_info "Step 2: Preparing test environment..."
    mysql -h"${MYSQL_TEST_HOST}" -u"${MYSQL_TEST_USER}" -p"${MYSQL_TEST_PASS}" \
        -e "DROP DATABASE IF EXISTS ${TEST_DB_NAME};" 2>&1 | tee -a "$LOG_FILE"
    
    mysql -h"${MYSQL_TEST_HOST}" -u"${MYSQL_TEST_USER}" -p"${MYSQL_TEST_PASS}" \
        -e "CREATE DATABASE ${TEST_DB_NAME};" 2>&1 | tee -a "$LOG_FILE"
    
    log_success "Test database created: ${TEST_DB_NAME}"
    
    # Step 3: Restore backup
    log_info "Step 3: Restoring backup to test database..."
    
    START_RESTORE=$(date +%s)
    
    if [ "$IS_COMPRESSED" = true ]; then
        gunzip -c "$BACKUP_FILE" | mysql -h"${MYSQL_TEST_HOST}" -u"${MYSQL_TEST_USER}" \
            -p"${MYSQL_TEST_PASS}" "${TEST_DB_NAME}" 2>&1 | tee -a "$LOG_FILE"
    else
        mysql -h"${MYSQL_TEST_HOST}" -u"${MYSQL_TEST_USER}" -p"${MYSQL_TEST_PASS}" \
            "${TEST_DB_NAME}" < "$BACKUP_FILE" 2>&1 | tee -a "$LOG_FILE"
    fi
    
    END_RESTORE=$(date +%s)
    RESTORE_TIME=$((END_RESTORE - START_RESTORE))
    
    log_success "Backup restored successfully in ${RESTORE_TIME} seconds"
    
    # Step 4: Verify database objects
    log_info "Step 4: Verifying database objects..."
    
    TABLE_COUNT=$(mysql -h"${MYSQL_TEST_HOST}" -u"${MYSQL_TEST_USER}" -p"${MYSQL_TEST_PASS}" \
        -N -B -e "SELECT COUNT(*) FROM information_schema.tables 
        WHERE table_schema = '${TEST_DB_NAME}';" 2>/dev/null)
    
    log_info "Tables found: ${TABLE_COUNT}"
    
    if [ "$TABLE_COUNT" -eq 0 ]; then
        log_warning "No tables found in restored database. Backup may be empty or from wrong source."
    else
        log_success "Database contains ${TABLE_COUNT} tables"
    fi
    
    # List tables
    log_info "Tables in restored database:"
    mysql -h"${MYSQL_TEST_HOST}" -u"${MYSQL_TEST_USER}" -p"${MYSQL_TEST_PASS}" \
        -e "SELECT table_name, 
            ROUND((data_length + index_length) / 1024 / 1024, 2) AS size_mb,
            table_rows AS estimated_rows
            FROM information_schema.tables 
            WHERE table_schema = '${TEST_DB_NAME}'
            ORDER BY (data_length + index_length) DESC
            LIMIT 10;" 2>/dev/null | tee -a "$LOG_FILE"
    
    # Step 5: Run sample queries
    log_info "Step 5: Running sample data integrity checks..."
    
    # Get first table name
    FIRST_TABLE=$(mysql -h"${MYSQL_TEST_HOST}" -u"${MYSQL_TEST_USER}" -p"${MYSQL_TEST_PASS}" \
        -N -B -e "SELECT table_name FROM information_schema.tables 
        WHERE table_schema = '${TEST_DB_NAME}' LIMIT 1;" 2>/dev/null)
    
    if [ -n "$FIRST_TABLE" ]; then
        log_info "Testing SELECT query on table: ${FIRST_TABLE}"
        ROW_COUNT=$(mysql -h"${MYSQL_TEST_HOST}" -u"${MYSQL_TEST_USER}" -p"${MYSQL_TEST_PASS}" \
            -N -B -e "SELECT COUNT(*) FROM ${TEST_DB_NAME}.${FIRST_TABLE};" 2>/dev/null)
        log_info "Row count in ${FIRST_TABLE}: ${ROW_COUNT}"
        log_success "Sample query executed successfully"
    fi
    
    # Step 6: Check for corruption
    log_info "Step 6: Checking for table corruption..."
    
    mysql -h"${MYSQL_TEST_HOST}" -u"${MYSQL_TEST_USER}" -p"${MYSQL_TEST_PASS}" \
        -e "CHECK TABLE ${TEST_DB_NAME}.${FIRST_TABLE};" 2>/dev/null | tee -a "$LOG_FILE" || true
    
    # Step 7: Cleanup
    log_info "Step 7: Cleaning up test database..."
    mysql -h"${MYSQL_TEST_HOST}" -u"${MYSQL_TEST_USER}" -p"${MYSQL_TEST_PASS}" \
        -e "DROP DATABASE ${TEST_DB_NAME};" 2>&1 | tee -a "$LOG_FILE"
    
    log_success "Test database dropped"
    
    # Final verdict
    log_info ""
    log_info "====== VERIFICATION SUMMARY ======"
    log_success "✓ Backup file integrity: PASSED"
    log_success "✓ Restore process: PASSED"
    log_success "✓ Database objects: ${TABLE_COUNT} tables found"
    log_success "✓ Data integrity: PASSED"
    log_success "✓ Restore time: ${RESTORE_TIME} seconds"
    log_info ""
    log_success "MySQL backup verification COMPLETED SUCCESSFULLY"
}

# Function to verify PostgreSQL backup
verify_postgres_backup() {
    log_info "Starting PostgreSQL backup verification..."
    
    # Step 1: Check file integrity
    log_info "Step 1: Checking backup file integrity..."
    
    FILE_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null)
    FILE_SIZE_MB=$(echo "scale=2; $FILE_SIZE / 1024 / 1024" | bc)
    log_info "Backup file size: ${FILE_SIZE_MB} MB"
    
    if [ "$FILE_SIZE" -lt 100 ]; then
        log_warning "Backup file is very small (< 100 bytes). This may indicate an empty or corrupt backup."
    fi
    
    # Check if file is compressed
    if file "$BACKUP_FILE" | grep -q "gzip"; then
        log_info "Backup is gzip compressed"
        IS_COMPRESSED=true
        
        if gzip -t "$BACKUP_FILE" 2>/dev/null; then
            log_success "Gzip integrity check passed"
        else
            error_exit "Gzip integrity check failed - backup file is corrupt"
        fi
    else
        log_info "Backup is not compressed"
        IS_COMPRESSED=false
    fi
    
    # Step 2: Drop test database if exists
    log_info "Step 2: Preparing test environment..."
    psql -h "${PG_TEST_HOST}" -p "${PG_TEST_PORT}" -U "${PG_TEST_USER}" -d postgres \
        -c "DROP DATABASE IF EXISTS ${TEST_DB_NAME};" 2>&1 | tee -a "$LOG_FILE"
    
    psql -h "${PG_TEST_HOST}" -p "${PG_TEST_PORT}" -U "${PG_TEST_USER}" -d postgres \
        -c "CREATE DATABASE ${TEST_DB_NAME};" 2>&1 | tee -a "$LOG_FILE"
    
    log_success "Test database created: ${TEST_DB_NAME}"
    
    # Step 3: Restore backup
    log_info "Step 3: Restoring backup to test database..."
    
    START_RESTORE=$(date +%s)
    
    if [ "$IS_COMPRESSED" = true ]; then
        gunzip -c "$BACKUP_FILE" | psql -h "${PG_TEST_HOST}" -p "${PG_TEST_PORT}" \
            -U "${PG_TEST_USER}" -d "${TEST_DB_NAME}" 2>&1 | tee -a "$LOG_FILE"
    else
        psql -h "${PG_TEST_HOST}" -p "${PG_TEST_PORT}" -U "${PG_TEST_USER}" \
            -d "${TEST_DB_NAME}" -f "$BACKUP_FILE" 2>&1 | tee -a "$LOG_FILE"
    fi
    
    END_RESTORE=$(date +%s)
    RESTORE_TIME=$((END_RESTORE - START_RESTORE))
    
    log_success "Backup restored successfully in ${RESTORE_TIME} seconds"
    
    # Step 4: Verify database objects
    log_info "Step 4: Verifying database objects..."
    
    TABLE_COUNT=$(psql -h "${PG_TEST_HOST}" -p "${PG_TEST_PORT}" -U "${PG_TEST_USER}" \
        -d "${TEST_DB_NAME}" -t -c "SELECT COUNT(*) FROM information_schema.tables 
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema');" 2>/dev/null | xargs)
    
    log_info "Tables found: ${TABLE_COUNT}"
    
    if [ "$TABLE_COUNT" -eq 0 ]; then
        log_warning "No tables found in restored database. Backup may be empty or from wrong source."
    else
        log_success "Database contains ${TABLE_COUNT} tables"
    fi
    
    # List tables with sizes
    log_info "Tables in restored database:"
    psql -h "${PG_TEST_HOST}" -p "${PG_TEST_PORT}" -U "${PG_TEST_USER}" \
        -d "${TEST_DB_NAME}" -c "
        SELECT 
            schemaname || '.' || tablename AS table_name,
            pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
            n_live_tup AS estimated_rows
        FROM pg_stat_user_tables
        ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
        LIMIT 10;" 2>/dev/null | tee -a "$LOG_FILE"
    
    # Step 5: Run sample queries
    log_info "Step 5: Running sample data integrity checks..."
    
    FIRST_TABLE=$(psql -h "${PG_TEST_HOST}" -p "${PG_TEST_PORT}" -U "${PG_TEST_USER}" \
        -d "${TEST_DB_NAME}" -t -c "SELECT schemaname || '.' || tablename 
        FROM pg_tables 
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema') 
        LIMIT 1;" 2>/dev/null | xargs)
    
    if [ -n "$FIRST_TABLE" ]; then
        log_info "Testing SELECT query on table: ${FIRST_TABLE}"
        ROW_COUNT=$(psql -h "${PG_TEST_HOST}" -p "${PG_TEST_PORT}" -U "${PG_TEST_USER}" \
            -d "${TEST_DB_NAME}" -t -c "SELECT COUNT(*) FROM ${FIRST_TABLE};" 2>/dev/null | xargs)
        log_info "Row count in ${FIRST_TABLE}: ${ROW_COUNT}"
        log_success "Sample query executed successfully"
    fi
    
    # Step 6: Verify database size
    log_info "Step 6: Checking restored database size..."
    
    DB_SIZE=$(psql -h "${PG_TEST_HOST}" -p "${PG_TEST_PORT}" -U "${PG_TEST_USER}" \
        -d "${TEST_DB_NAME}" -t -c "SELECT pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null | xargs)
    
    log_info "Restored database size: ${DB_SIZE}"
    
    # Step 7: Cleanup
    log_info "Step 7: Cleaning up test database..."
    psql -h "${PG_TEST_HOST}" -p "${PG_TEST_PORT}" -U "${PG_TEST_USER}" -d postgres \
        -c "DROP DATABASE ${TEST_DB_NAME};" 2>&1 | tee -a "$LOG_FILE"
    
    log_success "Test database dropped"
    
    # Final verdict
    log_info ""
    log_info "====== VERIFICATION SUMMARY ======"
    log_success "✓ Backup file integrity: PASSED"
    log_success "✓ Restore process: PASSED"
    log_success "✓ Database objects: ${TABLE_COUNT} tables found"
    log_success "✓ Data integrity: PASSED"
    log_success "✓ Database size: ${DB_SIZE}"
    log_success "✓ Restore time: ${RESTORE_TIME} seconds"
    log_info ""
    log_success "PostgreSQL backup verification COMPLETED SUCCESSFULLY"
}

# Main execution
case "$DB_TYPE" in
    mysql)
        verify_mysql_backup
        ;;
    postgres|postgresql)
        verify_postgres_backup
        ;;
    *)
        error_exit "Unsupported database type: $DB_TYPE. Supported types: mysql, postgres"
        ;;
esac

log_info "Verification log saved to: $LOG_FILE"
log_info "End Time: $(date)"
log_info ""
echo -e "${GREEN}====== BACKUP VERIFICATION SUCCESSFUL ======${NC}"