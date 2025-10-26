#!/bin/bash
#
# replication_lag_monitor.sh
# 
# Monitors database replication lag and sends alerts if threshold exceeded
# Author: Jamaurice Holt
# Usage: ./replication_lag_monitor.sh [db_type] [host] [threshold_seconds]
#
# Supported: mysql, postgres
#

set -euo pipefail

# Configuration
DB_TYPE="${1:-mysql}"
DB_HOST="${2:-localhost}"
LAG_THRESHOLD="${3:-10}"  # Alert if lag exceeds this many seconds
LOG_FILE="replication_lag_$(date +%Y%m%d).log"

# MySQL credentials
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-}"

# PostgreSQL credentials
PG_USER="${PG_USER:-postgres}"
PG_PORT="${PG_PORT:-5432}"

# Alert settings (configure as needed)
SEND_EMAIL_ALERTS="${SEND_EMAIL_ALERTS:-false}"
ALERT_EMAIL="${ALERT_EMAIL:-dba@example.com}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

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

# Function to send Slack alert
send_slack_alert() {
    local message=$1
    
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"$message\"}" \
            "$SLACK_WEBHOOK_URL" 2>/dev/null
    fi
}

# Function to send email alert
send_email_alert() {
    local subject=$1
    local message=$2
    
    if [ "$SEND_EMAIL_ALERTS" = "true" ]; then
        echo "$message" | mail -s "$subject" "$ALERT_EMAIL"
    fi
}

# Function to check MySQL replication lag
check_mysql_replication() {
    log "Checking MySQL replication status on ${DB_HOST}..."
    
    # Get replication status
    REPL_STATUS=$(mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" \
        -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    
    if [ -z "$REPL_STATUS" ]; then
        log "ERROR: Not configured as MySQL replica or cannot connect"
        exit 1
    fi
    
    # Extract key metrics
    SLAVE_IO_RUNNING=$(echo "$REPL_STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
    SLAVE_SQL_RUNNING=$(echo "$REPL_STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')
    SECONDS_BEHIND=$(echo "$REPL_STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}')
    MASTER_HOST=$(echo "$REPL_STATUS" | grep "Master_Host:" | awk '{print $2}')
    LAST_ERROR=$(echo "$REPL_STATUS" | grep "Last_Error:" | cut -d: -f2- | xargs)
    
    # Display current status
    echo ""
    echo "====== MySQL Replication Status ======"
    echo "Replica Host: ${DB_HOST}"
    echo "Master Host: ${MASTER_HOST}"
    echo "Slave_IO_Running: ${SLAVE_IO_RUNNING}"
    echo "Slave_SQL_Running: ${SLAVE_SQL_RUNNING}"
    echo "Seconds_Behind_Master: ${SECONDS_BEHIND:-NULL}"
    echo "Last_Error: ${LAST_ERROR:-None}"
    echo "======================================"
    echo ""
    
    # Check if replication is running
    if [ "$SLAVE_IO_RUNNING" != "Yes" ] || [ "$SLAVE_SQL_RUNNING" != "Yes" ]; then
        ALERT_MSG="CRITICAL: MySQL replication stopped on ${DB_HOST}"
        log "$ALERT_MSG"
        log "Slave_IO_Running: ${SLAVE_IO_RUNNING}"
        log "Slave_SQL_Running: ${SLAVE_SQL_RUNNING}"
        log "Last_Error: ${LAST_ERROR}"
        
        send_slack_alert "$ALERT_MSG | Master: ${MASTER_HOST} | Error: ${LAST_ERROR}"
        send_email_alert "MySQL Replication STOPPED" "$ALERT_MSG\n\nMaster: ${MASTER_HOST}\nError: ${LAST_ERROR}"
        
        exit 1
    fi
    
    # Check replication lag
    if [ "$SECONDS_BEHIND" = "NULL" ] || [ -z "$SECONDS_BEHIND" ]; then
        log "WARNING: Cannot determine replication lag (Seconds_Behind_Master is NULL)"
        SECONDS_BEHIND=0
    fi
    
    log "Current replication lag: ${SECONDS_BEHIND} seconds (threshold: ${LAG_THRESHOLD}s)"
    
    if [ "$SECONDS_BEHIND" -gt "$LAG_THRESHOLD" ]; then
        ALERT_MSG="WARNING: MySQL replication lag is ${SECONDS_BEHIND}s on ${DB_HOST} (threshold: ${LAG_THRESHOLD}s)"
        log "$ALERT_MSG"
        
        send_slack_alert "$ALERT_MSG | Master: ${MASTER_HOST}"
        send_email_alert "MySQL Replication Lag Warning" "$ALERT_MSG\n\nMaster: ${MASTER_HOST}"
        
        echo -e "${YELLOW}⚠ Replication lag exceeds threshold!${NC}"
    else
        echo -e "${GREEN}✓ Replication lag is within acceptable range${NC}"
        log "Replication is healthy"
    fi
    
    # Additional metrics
    echo ""
    echo "Additional Replication Metrics:"
    mysql -h"${DB_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "
        SELECT 
            'Read_Master_Log_Pos' AS Metric,
            Read_Master_Log_Pos AS Value
        FROM SHOW SLAVE STATUS
        UNION ALL
        SELECT 
            'Exec_Master_Log_Pos' AS Metric,
            Exec_Master_Log_Pos AS Value
        FROM SHOW SLAVE STATUS
        UNION ALL
        SELECT 
            'Relay_Log_Space' AS Metric,
            Relay_Log_Space AS Value
        FROM SHOW SLAVE STATUS;
    " 2>/dev/null || true
}

# Function to check PostgreSQL replication lag
check_postgres_replication() {
    log "Checking PostgreSQL replication status on ${DB_HOST}:${PG_PORT}..."
    
    # Check if this is a standby server
    IS_STANDBY=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t \
        -c "SELECT pg_is_in_recovery();" 2>/dev/null | xargs)
    
    if [ "$IS_STANDBY" != "t" ]; then
        log "ERROR: ${DB_HOST} is not a standby server (pg_is_in_recovery = false)"
        exit 1
    fi
    
    # Get replication lag in bytes
    LAG_BYTES=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t -c "
        SELECT CASE 
            WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() 
            THEN 0
            ELSE EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp())
        END AS lag_seconds;
    " 2>/dev/null | xargs)
    
    # Get additional metrics
    RECEIVE_LSN=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t \
        -c "SELECT pg_last_wal_receive_lsn();" 2>/dev/null | xargs)
    
    REPLAY_LSN=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t \
        -c "SELECT pg_last_wal_replay_lsn();" 2>/dev/null | xargs)
    
    REPLAY_TIMESTAMP=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t \
        -c "SELECT pg_last_xact_replay_timestamp();" 2>/dev/null | xargs)
    
    # Calculate byte lag
    BYTE_LAG=$(psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t -c "
        SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());
    " 2>/dev/null | xargs)
    
    # Display current status
    echo ""
    echo "====== PostgreSQL Replication Status ======"
    echo "Standby Host: ${DB_HOST}:${PG_PORT}"
    echo "In Recovery: Yes"
    echo "Last WAL Received: ${RECEIVE_LSN}"
    echo "Last WAL Replayed: ${REPLAY_LSN}"
    echo "Last Replay Timestamp: ${REPLAY_TIMESTAMP}"
    echo "Byte Lag: ${BYTE_LAG} bytes"
    echo "Time Lag: ${LAG_BYTES} seconds"
    echo "==========================================="
    echo ""
    
    # Check replication lag
    LAG_SECONDS=$(echo "$LAG_BYTES" | awk '{print int($1)}')
    
    log "Current replication lag: ${LAG_SECONDS} seconds (threshold: ${LAG_THRESHOLD}s)"
    
    if [ "$LAG_SECONDS" -gt "$LAG_THRESHOLD" ]; then
        ALERT_MSG="WARNING: PostgreSQL replication lag is ${LAG_SECONDS}s on ${DB_HOST} (threshold: ${LAG_THRESHOLD}s)"
        log "$ALERT_MSG"
        
        send_slack_alert "$ALERT_MSG | Byte Lag: ${BYTE_LAG}"
        send_email_alert "PostgreSQL Replication Lag Warning" "$ALERT_MSG\n\nByte Lag: ${BYTE_LAG}\nLast Replay: ${REPLAY_TIMESTAMP}"
        
        echo -e "${YELLOW}⚠ Replication lag exceeds threshold!${NC}"
    else
        echo -e "${GREEN}✓ Replication lag is within acceptable range${NC}"
        log "Replication is healthy"
    fi
    
    # Check for conflicts
    echo ""
    echo "Replication Conflicts:"
    psql -h "${DB_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "
        SELECT * FROM pg_stat_database_conflicts 
        WHERE datname NOT IN ('template0', 'template1');
    " 2>/dev/null || true
}

# Main execution
echo "====== Database Replication Lag Monitor ======"
echo "Database Type: ${DB_TYPE}"
echo "Host: ${DB_HOST}"
echo "Lag Threshold: ${LAG_THRESHOLD} seconds"
echo "Check Time: $(date)"
echo ""

case "$DB_TYPE" in
    mysql)
        check_mysql_replication
        ;;
    postgres|postgresql)
        check_postgres_replication
        ;;
    *)
        echo "ERROR: Unsupported database type: $DB_TYPE"
        echo "Supported types: mysql, postgres"
        exit 1
        ;;
esac

echo ""
echo "Log file: $LOG_FILE"
echo ""

# If running in cron, this will be silent if no alerts
exit 0