#!/bin/bash
#
# aws_rds_monitor.sh
# 
# Monitors AWS RDS instances and retrieves CloudWatch metrics
# Author: Jamaurice Holt
# Usage: ./aws_rds_monitor.sh [instance-identifier] [region]
#
# Requirements: AWS CLI installed and configured with appropriate permissions
#

set -euo pipefail

# Configuration
RDS_INSTANCE="${1:-}"
AWS_REGION="${2:-us-east-1}"
REPORT_DATE=$(date +"%Y-%m-%d_%H-%M-%S")
REPORT_FILE="rds_monitor_${RDS_INSTANCE}_${REPORT_DATE}.txt"

# Time period for metrics (last 1 hour)
START_TIME=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S')
END_TIME=$(date -u '+%Y-%m-%dT%H:%M:%S')

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print section header
print_header() {
    echo "================================================================"
    echo "$1"
    echo "================================================================"
    echo ""
}

# Function to get CloudWatch metric statistics
get_metric_stats() {
    local metric_name=$1
    local statistic=$2
    local unit=${3:-""}
    
    local unit_param=""
    if [ -n "$unit" ]; then
        unit_param="--unit $unit"
    fi
    
    aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS \
        --metric-name "$metric_name" \
        --dimensions Name=DBInstanceIdentifier,Value="$RDS_INSTANCE" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --period 300 \
        --statistics "$statistic" \
        $unit_param \
        --region "$AWS_REGION" \
        --output json 2>/dev/null | \
        jq -r '.Datapoints | sort_by(.Timestamp) | .[] | "\(.Timestamp) | \(.'$statistic')"'
}

# Function to get current metric value (latest)
get_current_metric() {
    local metric_name=$1
    local unit=${2:-""}
    
    local unit_param=""
    if [ -n "$unit" ]; then
        unit_param="--unit $unit"
    fi
    
    aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS \
        --metric-name "$metric_name" \
        --dimensions Name=DBInstanceIdentifier,Value="$RDS_INSTANCE" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --period 300 \
        --statistics Average \
        $unit_param \
        --region "$AWS_REGION" \
        --output json 2>/dev/null | \
        jq -r '.Datapoints | sort_by(.Timestamp) | .[-1].Average // "N/A"'
}

# Check if instance identifier is provided
if [ -z "$RDS_INSTANCE" ]; then
    echo -e "${RED}ERROR: RDS instance identifier is required${NC}"
    echo "Usage: $0 <instance-identifier> [region]"
    echo ""
    echo "Available RDS instances in region $AWS_REGION:"
    aws rds describe-db-instances \
        --region "$AWS_REGION" \
        --query 'DBInstances[*].[DBInstanceIdentifier,Engine,DBInstanceStatus]' \
        --output table
    exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}ERROR: AWS CLI is not installed${NC}"
    echo "Please install AWS CLI: https://aws.amazon.com/cli/"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is not installed${NC}"
    echo "Please install jq: sudo apt-get install jq"
    exit 1
fi

# Start report
{
    print_header "AWS RDS Instance Monitor - $(date)"
    
    echo "Instance: ${RDS_INSTANCE}"
    echo "Region: ${AWS_REGION}"
    echo "Monitoring Period: Last 1 hour"
    echo "Report Generated: ${REPORT_DATE}"
    echo ""
    
    # Section 1: Instance Information
    print_header "1. RDS INSTANCE INFORMATION"
    
    echo "Retrieving instance details..."
    aws rds describe-db-instances \
        --db-instance-identifier "$RDS_INSTANCE" \
        --region "$AWS_REGION" \
        --query 'DBInstances[0].[
            DBInstanceIdentifier,
            Engine,
            EngineVersion,
            DBInstanceClass,
            DBInstanceStatus,
            MultiAZ,
            StorageType,
            AllocatedStorage,
            AvailabilityZone,
            PreferredBackupWindow,
            PreferredMaintenanceWindow,
            BackupRetentionPeriod,
            Endpoint.Address,
            Endpoint.Port
        ]' \
        --output table
    
    # Section 2: Current Performance Metrics
    print_header "2. CURRENT PERFORMANCE METRICS (LATEST)"
    
    echo "CPU Utilization:"
    CPU_CURRENT=$(get_current_metric "CPUUtilization" "Percent")
    echo "  Current: ${CPU_CURRENT}%"
    if (( $(echo "$CPU_CURRENT > 80" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "  ${RED}WARNING: High CPU utilization${NC}"
    fi
    
    echo ""
    echo "Database Connections:"
    CONN_CURRENT=$(get_current_metric "DatabaseConnections" "Count")
    echo "  Current: ${CONN_CURRENT}"
    
    echo ""
    echo "Freeable Memory:"
    MEM_CURRENT=$(get_current_metric "FreeableMemory" "Bytes")
    MEM_CURRENT_MB=$(echo "$MEM_CURRENT / 1024 / 1024" | bc)
    echo "  Current: ${MEM_CURRENT_MB} MB"
    if (( $(echo "$MEM_CURRENT_MB < 500" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "  ${RED}WARNING: Low available memory${NC}"
    fi
    
    echo ""
    echo "Free Storage Space:"
    STORAGE_CURRENT=$(get_current_metric "FreeStorageSpace" "Bytes")
    STORAGE_CURRENT_GB=$(echo "$STORAGE_CURRENT / 1024 / 1024 / 1024" | bc)
    echo "  Current: ${STORAGE_CURRENT_GB} GB"
    if (( $(echo "$STORAGE_CURRENT_GB < 10" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "  ${RED}WARNING: Low storage space${NC}"
    fi
    
    echo ""
    echo "Read/Write Latency:"
    READ_LAT=$(get_current_metric "ReadLatency" "Seconds")
    WRITE_LAT=$(get_current_metric "WriteLatency" "Seconds")
    READ_LAT_MS=$(echo "$READ_LAT * 1000" | bc 2>/dev/null || echo "N/A")
    WRITE_LAT_MS=$(echo "$WRITE_LAT * 1000" | bc 2>/dev/null || echo "N/A")
    echo "  Read Latency: ${READ_LAT_MS} ms"
    echo "  Write Latency: ${WRITE_LAT_MS} ms"
    
    echo ""
    echo "IOPS:"
    READ_IOPS=$(get_current_metric "ReadIOPS" "Count/Second")
    WRITE_IOPS=$(get_current_metric "WriteIOPS" "Count/Second")
    echo "  Read IOPS: ${READ_IOPS}"
    echo "  Write IOPS: ${WRITE_IOPS}"
    
    # Section 3: CPU Utilization Over Time
    print_header "3. CPU UTILIZATION (LAST 1 HOUR)"
    echo "Timestamp                    | CPU %"
    echo "-----------------------------+--------"
    get_metric_stats "CPUUtilization" "Average" "Percent"
    
    # Section 4: Database Connections Over Time
    print_header "4. DATABASE CONNECTIONS (LAST 1 HOUR)"
    echo "Timestamp                    | Connections"
    echo "-----------------------------+-------------"
    get_metric_stats "DatabaseConnections" "Average" "Count"
    
    # Section 5: Memory Usage Over Time
    print_header "5. FREEABLE MEMORY (LAST 1 HOUR)"
    echo "Timestamp                    | Memory (Bytes)"
    echo "-----------------------------+----------------"
    get_metric_stats "FreeableMemory" "Average" "Bytes"
    
    # Section 6: Storage Space Over Time
    print_header "6. FREE STORAGE SPACE (LAST 1 HOUR)"
    echo "Timestamp                    | Storage (Bytes)"
    echo "-----------------------------+-----------------"
    get_metric_stats "FreeStorageSpace" "Average" "Bytes"
    
    # Section 7: Read/Write Latency
    print_header "7. READ/WRITE LATENCY (LAST 1 HOUR)"
    echo "Read Latency:"
    echo "Timestamp                    | Latency (Seconds)"
    echo "-----------------------------+-------------------"
    get_metric_stats "ReadLatency" "Average" "Seconds"
    
    echo ""
    echo "Write Latency:"
    echo "Timestamp                    | Latency (Seconds)"
    echo "-----------------------------+-------------------"
    get_metric_stats "WriteLatency" "Average" "Seconds"
    
    # Section 8: IOPS
    print_header "8. READ/WRITE IOPS (LAST 1 HOUR)"
    echo "Read IOPS:"
    echo "Timestamp                    | IOPS"
    echo "-----------------------------+-------"
    get_metric_stats "ReadIOPS" "Average" "Count/Second"
    
    echo ""
    echo "Write IOPS:"
    echo "Timestamp                    | IOPS"
    echo "-----------------------------+-------"
    get_metric_stats "WriteIOPS" "Average" "Count/Second"
    
    # Section 9: Throughput
    print_header "9. READ/WRITE THROUGHPUT (LAST 1 HOUR)"
    echo "Read Throughput:"
    echo "Timestamp                    | Throughput (Bytes/Sec)"
    echo "-----------------------------+-------------------------"
    get_metric_stats "ReadThroughput" "Average" "Bytes/Second"
    
    echo ""
    echo "Write Throughput:"
    echo "Timestamp                    | Throughput (Bytes/Sec)"
    echo "-----------------------------+-------------------------"
    get_metric_stats "WriteThroughput" "Average" "Bytes/Second"
    
    # Section 10: Replication Lag (for Read Replicas)
    print_header "10. REPLICATION LAG (IF APPLICABLE)"
    echo "Checking if instance is a read replica..."
    
    IS_REPLICA=$(aws rds describe-db-instances \
        --db-instance-identifier "$RDS_INSTANCE" \
        --region "$AWS_REGION" \
        --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier' \
        --output text 2>/dev/null)
    
    if [ "$IS_REPLICA" != "None" ] && [ -n "$IS_REPLICA" ]; then
        echo "Instance is a read replica of: $IS_REPLICA"
        echo ""
        echo "Timestamp                    | Lag (Seconds)"
        echo "-----------------------------+---------------"
        get_metric_stats "ReplicaLag" "Average" "Seconds"
    else
        echo "Instance is not a read replica."
    fi
    
    # Section 11: Recent Events
    print_header "11. RECENT RDS EVENTS (LAST 24 HOURS)"
    
    EVENTS_START=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S')
    
    aws rds describe-events \
        --source-identifier "$RDS_INSTANCE" \
        --source-type db-instance \
        --start-time "$EVENTS_START" \
        --region "$AWS_REGION" \
        --query 'Events[*].[Date,Message]' \
        --output table
    
    # Section 12: Automated Backups
    print_header "12. AUTOMATED BACKUPS"
    
    aws rds describe-db-snapshots \
        --db-instance-identifier "$RDS_INSTANCE" \
        --snapshot-type automated \
        --region "$AWS_REGION" \
        --query 'DBSnapshots[*].[
            DBSnapshotIdentifier,
            SnapshotCreateTime,
            Status,
            AllocatedStorage
        ]' \
        --output table | head -20
    
    # Section 13: Parameter Groups
    print_header "13. PARAMETER GROUP SETTINGS"
    
    PARAM_GROUP=$(aws rds describe-db-instances \
        --db-instance-identifier "$RDS_INSTANCE" \
        --region "$AWS_REGION" \
        --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' \
        --output text)
    
    echo "Parameter Group: $PARAM_GROUP"
    echo ""
    echo "Modified Parameters:"
    aws rds describe-db-parameters \
        --db-parameter-group-name "$PARAM_GROUP" \
        --region "$AWS_REGION" \
        --query 'Parameters[?Source==`user`].[ParameterName,ParameterValue,Description]' \
        --output table
    
    # Section 14: CloudWatch Alarms
    print_header "14. CLOUDWATCH ALARMS FOR THIS INSTANCE"
    
    aws cloudwatch describe-alarms \
        --alarm-name-prefix "$RDS_INSTANCE" \
        --region "$AWS_REGION" \
        --query 'MetricAlarms[*].[
            AlarmName,
            StateValue,
            MetricName,
            Threshold,
            ComparisonOperator
        ]' \
        --output table
    
    # Section 15: Performance Insights (if enabled)
    print_header "15. PERFORMANCE INSIGHTS STATUS"
    
    PI_ENABLED=$(aws rds describe-db-instances \
        --db-instance-identifier "$RDS_INSTANCE" \
        --region "$AWS_REGION" \
        --query 'DBInstances[0].PerformanceInsightsEnabled' \
        --output text 2>/dev/null)
    
    if [ "$PI_ENABLED" == "True" ]; then
        echo -e "${GREEN}Performance Insights: ENABLED${NC}"
        
        PI_RETENTION=$(aws rds describe-db-instances \
            --db-instance-identifier "$RDS_INSTANCE" \
            --region "$AWS_REGION" \
            --query 'DBInstances[0].PerformanceInsightsRetentionPeriod' \
            --output text 2>/dev/null)
        
        echo "Retention Period: $PI_RETENTION days"
        echo ""
        echo "Access Performance Insights in AWS Console:"
        echo "https://console.aws.amazon.com/rds/home?region=${AWS_REGION}#performance-insights-v20206:/resourceId/${RDS_INSTANCE}"
    else
        echo -e "${YELLOW}Performance Insights: DISABLED${NC}"
        echo "Consider enabling Performance Insights for detailed query performance analysis."
    fi
    
    # Section 16: Recommendations
    print_header "16. RECOMMENDATIONS"
    
    echo "Based on current metrics:"
    echo ""
    
    # CPU recommendation
    if (( $(echo "$CPU_CURRENT > 80" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "${RED}⚠ CPU Utilization is HIGH (${CPU_CURRENT}%)${NC}"
        echo "  - Consider scaling up to a larger instance class"
        echo "  - Review slow query log for optimization opportunities"
        echo ""
    fi
    
    # Memory recommendation
    if (( $(echo "$MEM_CURRENT_MB < 500" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "${RED}⚠ Freeable Memory is LOW (${MEM_CURRENT_MB} MB)${NC}"
        echo "  - Consider scaling up to instance with more memory"
        echo "  - Review buffer pool/cache settings"
        echo ""
    fi
    
    # Storage recommendation
    if (( $(echo "$STORAGE_CURRENT_GB < 10" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "${RED}⚠ Free Storage Space is LOW (${STORAGE_CURRENT_GB} GB)${NC}"
        echo "  - Consider increasing allocated storage"
        echo "  - Enable storage auto-scaling"
        echo "  - Review and purge old logs/backups"
        echo ""
    fi
    
    # General recommendations
    echo "General recommendations:"
    echo "  ✓ Monitor CPU: Keep under 80% sustained"
    echo "  ✓ Monitor Memory: Maintain >500MB free"
    echo "  ✓ Monitor Storage: Keep >20% free (or >10GB minimum)"
    echo "  ✓ Read Latency: Target <20ms"
    echo "  ✓ Write Latency: Target <50ms"
    echo "  ✓ Enable Enhanced Monitoring for OS-level metrics"
    echo "  ✓ Enable Performance Insights for query analysis"
    echo ""
    
    print_header "END OF REPORT"
    
} | tee "${REPORT_FILE}"

echo ""
echo -e "${GREEN}Report saved to: ${REPORT_FILE}${NC}"
echo ""
echo -e "${YELLOW}Quick Actions:${NC}"
echo "View Performance Insights:"
echo "  https://console.aws.amazon.com/rds/home?region=${AWS_REGION}#performance-insights-v20206:/resourceId/${RDS_INSTANCE}"
echo ""
echo "View CloudWatch Metrics:"
echo "  https://console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#metricsV2:graph=~();namespace=AWS/RDS;dimensions=DBInstanceIdentifier"
echo ""