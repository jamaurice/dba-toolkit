/*
================================================================================
Advanced Blocking Chain Analysis Tool
================================================================================
Description: Comprehensive blocking chain analysis for SQL Server production environments
Author: Jamauice Holt
Version: 2.0
Created: 2025-06-15
Last Modified: 2025-06-15

Features:
- Hierarchical blocking chain visualization
- Comprehensive session information
- Wait statistics integration
- Performance metrics
- Configurable output formats
- Error handling and logging
- Cross-version compatibility

Usage:
    EXEC sp_AdvancedBlockingAnalysis 
        @IncludeDetails = 1,
        @MinBlockingTimeSeconds = 5,
        @OutputFormat = 'TREE',
        @SaveToHistory = 1

Parameters:
    @IncludeDetails: Include detailed session information (default: 1)
    @MinBlockingTimeSeconds: Minimum blocking time to report (default: 0)
    @OutputFormat: 'TREE', 'FLAT', or 'JSON' (default: 'TREE')
    @SaveToHistory: Save results to history table (default: 0)
    @ShowOnlyActiveBlocking: Only show active blocking chains (default: 1)
================================================================================
*/

-- Create stored procedure for advanced blocking analysis
IF OBJECT_ID('sp_AdvancedBlockingAnalysis', 'P') IS NOT NULL
    DROP PROCEDURE sp_AdvancedBlockingAnalysis;
GO

CREATE PROCEDURE sp_AdvancedBlockingAnalysis
    @IncludeDetails BIT = 1,
    @MinBlockingTimeSeconds INT = 0,
    @OutputFormat VARCHAR(10) = 'TREE',
    @SaveToHistory BIT = 0,
    @ShowOnlyActiveBlocking BIT = 1,
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Error handling variables
    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @ErrorSeverity INT;
    DECLARE @ErrorState INT;
    DECLARE @StartTime DATETIME2 = GETDATE();
    
    BEGIN TRY
        -- Validate parameters
        IF @OutputFormat NOT IN ('TREE', 'FLAT', 'JSON')
        BEGIN
            RAISERROR('Invalid @OutputFormat. Must be TREE, FLAT, or JSON', 16, 1);
            RETURN;
        END;
        
        -- Create temporary tables for analysis
        CREATE TABLE #SessionInfo (
            spid INT NOT NULL,
            blocked INT NOT NULL,
            login_time DATETIME,
            host_name NVARCHAR(128),
            program_name NVARCHAR(128),
            login_name NVARCHAR(128),
            database_name NVARCHAR(128),
            status NVARCHAR(30),
            command NVARCHAR(32),
            cpu_time INT,
            memory_usage INT,
            physical_io BIGINT,
            wait_type NVARCHAR(60),
            wait_time INT,
            wait_resource NVARCHAR(256),
            open_tran INT,
            sql_text NVARCHAR(MAX),
            blocking_duration_seconds INT,
            is_user_process BIT
        );
        
        CREATE TABLE #BlockingHierarchy (
            spid INT,
            blocked INT,
            level_path VARCHAR(MAX),
            blocking_level INT,
            is_blocking_head BIT
        );
        
        IF @Debug = 1
            PRINT 'Step 1: Gathering session information...';
        
        -- Gather blocking information using sys.sysprocesses (more compatible)
        INSERT INTO #SessionInfo
        SELECT 
            sp.spid,
            sp.blocked,
            sp.login_time,
            sp.hostname,
            sp.program_name,
            sp.loginame,
            DB_NAME(sp.dbid) AS database_name,
            sp.status,
            sp.cmd,
            sp.cpu,
            sp.memusage,
            sp.physical_io,
            r.wait_type,
            ISNULL(r.wait_time, 0) AS wait_time,
            ISNULL(r.wait_resource, '') AS wait_resource,
            sp.open_tran,
            CASE 
                WHEN t.text IS NOT NULL THEN 
                    REPLACE(REPLACE(LTRIM(RTRIM(t.text)), CHAR(10), ' '), CHAR(13), ' ')
                ELSE NULL
            END AS sql_text,
            DATEDIFF(SECOND, sp.last_batch, GETDATE()) AS blocking_duration_seconds,
            CASE WHEN sp.spid > 50 THEN 1 ELSE 0 END AS is_user_process
        FROM sys.sysprocesses sp
        LEFT JOIN sys.dm_exec_requests r ON sp.spid = r.session_id
        OUTER APPLY sys.dm_exec_sql_text(sp.sql_handle) t
        WHERE sp.spid > 50 -- Exclude system sessions
            AND (
                sp.blocked > 0 
                OR EXISTS (
                    SELECT 1 FROM sys.sysprocesses sp2 
                    WHERE sp2.blocked = sp.spid AND sp2.blocked <> sp2.spid
                )
            )
            AND (@ShowOnlyActiveBlocking = 0 OR sp.status != 'sleeping' OR sp.blocked > 0)
            AND DATEDIFF(SECOND, sp.last_batch, GETDATE()) >= @MinBlockingTimeSeconds;
        
        IF @Debug = 1
            PRINT 'Step 2: Building blocking hierarchy...';
        
        -- Build blocking hierarchy using recursive CTE
        WITH BlockingChain AS (
            -- Anchor: Find blocking heads (sessions that block others but aren't blocked themselves)
            SELECT 
                spid,
                blocked,
                CAST(RIGHT('0000' + CAST(spid AS VARCHAR), 4) AS VARCHAR(MAX)) AS level_path,
                0 AS blocking_level,
                CAST(1 AS BIT) AS is_blocking_head
            FROM #SessionInfo
            WHERE (blocked = 0 OR blocked = spid)
                AND EXISTS (
                    SELECT 1 FROM #SessionInfo si2 
                    WHERE si2.blocked = #SessionInfo.spid AND si2.blocked <> si2.spid
                )
            
            UNION ALL
            
            -- Recursive: Find sessions blocked by the current level
            SELECT 
                si.spid,
                si.blocked,
                bc.level_path + '->' + RIGHT('0000' + CAST(si.spid AS VARCHAR), 4),
                bc.blocking_level + 1,
                CAST(0 AS BIT)
            FROM #SessionInfo si
            INNER JOIN BlockingChain bc ON si.blocked = bc.spid
            WHERE si.blocked > 0 AND si.blocked <> si.spid
        )
        INSERT INTO #BlockingHierarchy
        SELECT 
            spid,
            blocked,
            level_path,
            blocking_level,
            is_blocking_head
        FROM BlockingChain
        OPTION (MAXRECURSION 32767);
        
        IF @Debug = 1
            PRINT 'Step 3: Generating output...';
        
        -- Generate output based on format
        IF @OutputFormat = 'TREE'
        BEGIN
            -- Tree format output
            SELECT 
                REPLICATE('    ', ISNULL(bh.blocking_level, 0)) + 
                CASE 
                    WHEN ISNULL(bh.blocking_level, 0) = 0 THEN 'HEAD -> '
                    ELSE '|---> '
                END + 
                'SPID: ' + CAST(si.spid AS VARCHAR(10)) + 
                CASE 
                    WHEN si.blocked > 0 AND si.blocked <> si.spid THEN ' (Blocked by: ' + CAST(si.blocked AS VARCHAR(10)) + ')'
                    ELSE ' (Blocking Head)'
                END AS BlockingTree,
                si.spid,
                si.blocked,
                ISNULL(bh.blocking_level, 0) AS blocking_level,
                si.database_name,
                si.login_name,
                si.host_name,
                si.program_name,
                si.status,
                si.command,
                si.wait_type,
                si.wait_time,
                si.blocking_duration_seconds,
                si.cpu_time,
                si.physical_io,
                si.open_tran,
                CASE @IncludeDetails 
                    WHEN 1 THEN LEFT(ISNULL(si.sql_text, 'N/A'), 100) + 
                               CASE WHEN LEN(ISNULL(si.sql_text, '')) > 100 THEN '...' ELSE '' END
                    ELSE 'Details suppressed'
                END AS sql_text_preview
            FROM #SessionInfo si
            LEFT JOIN #BlockingHierarchy bh ON si.spid = bh.spid
            ORDER BY ISNULL(bh.level_path, RIGHT('0000' + CAST(si.spid AS VARCHAR), 4));
        END
        ELSE IF @OutputFormat = 'FLAT'
        BEGIN
            -- Flat format output
            SELECT 
                si.spid,
                si.blocked,
                ISNULL(bh.blocking_level, 0) AS blocking_level,
                si.database_name,
                si.login_name,
                si.host_name,
                si.program_name,
                si.status,
                si.command,
                si.wait_type,
                si.wait_time,
                si.blocking_duration_seconds,
                si.cpu_time,
                si.physical_io,
                si.memory_usage,
                si.open_tran,
                CASE @IncludeDetails 
                    WHEN 1 THEN si.sql_text
                    ELSE 'Details suppressed'
                END AS sql_text
            FROM #SessionInfo si
            LEFT JOIN #BlockingHierarchy bh ON si.spid = bh.spid
            ORDER BY ISNULL(bh.blocking_level, 0), si.blocking_duration_seconds DESC;
        END
        ELSE IF @OutputFormat = 'JSON'
        BEGIN
            -- JSON format output
            SELECT 
                (
                    SELECT 
                        si.spid,
                        si.blocked,
                        ISNULL(bh.blocking_level, 0) AS blocking_level,
                        si.database_name,
                        si.login_name,
                        si.host_name,
                        si.status,
                        si.wait_type,
                        si.blocking_duration_seconds,
                        CASE @IncludeDetails 
                            WHEN 1 THEN si.sql_text
                            ELSE 'Details suppressed'
                        END AS sql_text
                    FROM #SessionInfo si
                    LEFT JOIN #BlockingHierarchy bh ON si.spid = bh.spid
                    ORDER BY ISNULL(bh.blocking_level, 0)
                    FOR JSON PATH
                ) AS BlockingChainJSON;
        END;
        
        -- Summary statistics
        SELECT 
            COUNT(*) AS TotalBlockedSessions,
            COUNT(DISTINCT CASE WHEN si.blocked > 0 AND si.blocked <> si.spid THEN si.blocked END) AS UniqueBlockingHeads,
            MAX(ISNULL(bh.blocking_level, 0)) AS MaxBlockingDepth,
            AVG(CAST(si.blocking_duration_seconds AS FLOAT)) AS AvgBlockingDurationSeconds,
            MAX(si.blocking_duration_seconds) AS MaxBlockingDurationSeconds,
            COUNT(CASE WHEN ISNULL(si.wait_type, '') LIKE 'LCK%' THEN 1 END) AS LockWaits,
            COUNT(CASE WHEN ISNULL(si.wait_type, '') LIKE 'PAGEIOLATCH%' THEN 1 END) AS IOWaits
        FROM #SessionInfo si
        LEFT JOIN #BlockingHierarchy bh ON si.spid = bh.spid
        WHERE si.blocked > 0 AND si.blocked <> si.spid;
        
        -- Wait type analysis
        SELECT 
            ISNULL(si.wait_type, 'N/A') AS wait_type,
            COUNT(*) AS session_count,
            AVG(CAST(ISNULL(si.wait_time, 0) AS FLOAT)) AS avg_wait_time_ms,
            MAX(ISNULL(si.wait_time, 0)) AS max_wait_time_ms
        FROM #SessionInfo si
        WHERE si.wait_type IS NOT NULL
        GROUP BY si.wait_type
        ORDER BY session_count DESC;
        
        -- Database breakdown
        SELECT 
            si.database_name,
            COUNT(*) AS blocked_sessions,
            AVG(CAST(si.blocking_duration_seconds AS FLOAT)) AS avg_blocking_duration_seconds
        FROM #SessionInfo si
        WHERE si.blocked > 0 AND si.blocked <> si.spid
            AND si.database_name IS NOT NULL
        GROUP BY si.database_name
        ORDER BY blocked_sessions DESC;
        
        -- Save to history if requested
        IF @SaveToHistory = 1
        BEGIN
            -- Create history table if it doesn't exist
            IF OBJECT_ID('BlockingAnalysisHistory', 'U') IS NULL
            BEGIN
                CREATE TABLE BlockingAnalysisHistory (
                    HistoryID INT IDENTITY(1,1) PRIMARY KEY,
                    CaptureTime DATETIME2 DEFAULT GETDATE(),
                    TotalBlockedSessions INT,
                    MaxBlockingDepth INT,
                    AvgBlockingDurationSeconds FLOAT,
                    MaxBlockingDurationSeconds INT,
                    BlockingData NVARCHAR(MAX)
                );
            END;
            
            -- Insert summary into history
            INSERT INTO BlockingAnalysisHistory (
                TotalBlockedSessions,
                MaxBlockingDepth,
                AvgBlockingDurationSeconds,
                MaxBlockingDurationSeconds,
                BlockingData
            )
            SELECT 
                COUNT(*),
                MAX(ISNULL(bh.blocking_level, 0)),
                AVG(CAST(si.blocking_duration_seconds AS FLOAT)),
                MAX(si.blocking_duration_seconds),
                (SELECT si.*, bh.blocking_level FROM #SessionInfo si LEFT JOIN #BlockingHierarchy bh ON si.spid = bh.spid FOR JSON PATH)
            FROM #SessionInfo si
            LEFT JOIN #BlockingHierarchy bh ON si.spid = bh.spid
            WHERE si.blocked > 0 AND si.blocked <> si.spid;
        END;
        
        -- Performance metrics
        DECLARE @EndTime DATETIME2 = GETDATE();
        DECLARE @ExecutionTimeMs INT = DATEDIFF(MILLISECOND, @StartTime, @EndTime);
        
        SELECT 
            @ExecutionTimeMs AS ExecutionTimeMs,
            @@ROWCOUNT AS RowsProcessed,
            GETDATE() AS AnalysisCompletedAt;
        
        IF @Debug = 1
            PRINT 'Analysis completed successfully in ' + CAST(@ExecutionTimeMs AS VARCHAR) + ' ms';
        
    END TRY
    BEGIN CATCH
        SELECT @ErrorMessage = ERROR_MESSAGE(),
               @ErrorSeverity = ERROR_SEVERITY(),
               @ErrorState = ERROR_STATE();
        
        -- Log error (optional - requires error logging table)
        PRINT 'Error in sp_AdvancedBlockingAnalysis: ' + @ErrorMessage;
        
        -- Re-raise the error
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH;
    
    -- Cleanup
    IF OBJECT_ID('tempdb..#SessionInfo') IS NOT NULL
        DROP TABLE #SessionInfo;
    IF OBJECT_ID('tempdb..#BlockingHierarchy') IS NOT NULL
        DROP TABLE #BlockingHierarchy;
END;
GO

-- Grant execute permissions (adjust as needed)
-- GRANT EXECUTE ON sp_AdvancedBlockingAnalysis TO [YourDBARole];

/*
================================================================================
Usage Examples:
================================================================================

-- Basic usage with tree output
EXEC sp_AdvancedBlockingAnalysis;

-- Detailed analysis with minimum blocking time filter
EXEC sp_AdvancedBlockingAnalysis 
    @IncludeDetails = 1,
    @MinBlockingTimeSeconds = 10,
    @OutputFormat = 'TREE';

-- Flat output for export/analysis
EXEC sp_AdvancedBlockingAnalysis 
    @OutputFormat = 'FLAT',
    @SaveToHistory = 1;

-- JSON output for application integration
EXEC sp_AdvancedBlockingAnalysis 
    @OutputFormat = 'JSON',
    @IncludeDetails = 1;

-- Debug mode with all blocking sessions
EXEC sp_AdvancedBlockingAnalysis 
    @ShowOnlyActiveBlocking = 0,
    @Debug = 1;

================================================================================
*/
