/*
Enhanced SQL Server Wait Resource Decoder
Robust version with improved error handling, security, and functionality
Compatible with SQL Server 2016+ (adjust compatibility level as needed)
*/

SET NOCOUNT ON;

DECLARE @WaitResource NVARCHAR(256) = '{wait_resource}'; -- Input parameter
DECLARE @Debug BIT = 0; -- Set to 1 for debug output

-- Variables
DECLARE @DBID INT, @DBName SYSNAME, @SQL NVARCHAR(MAX), @HOBTID BIGINT;
DECLARE @ObjectID INT, @FileID INT, @PageID INT, @IndexID INT, @PartitionID BIGINT;
DECLARE @idx1 INT, @idx2 INT, @m_type INT, @SlotID INT;
DECLARE @PageType VARCHAR(100), @NormalizedWaitResource NVARCHAR(256);
DECLARE @ErrorMessage NVARCHAR(4000), @DBState INT, @DBCollation SYSNAME;
DECLARE @SQLVersion INT = CAST(SERVERPROPERTY('ProductMajorVersion') AS INT);

-- Results table for consistent output
DECLARE @Results TABLE (
    wait_resource NVARCHAR(256),
    database_name SYSNAME NULL,
    database_id INT NULL,
    schema_name SYSNAME NULL,
    object_name SYSNAME NULL,
    index_name SYSNAME NULL,
    page_type VARCHAR(100) NULL,
    file_id INT NULL,
    page_id BIGINT NULL,
    slot_id INT NULL,
    hobt_id BIGINT NULL,
    partition_id BIGINT NULL,
    object_type VARCHAR(50) NULL,
    info NVARCHAR(MAX) NULL,
    error_message NVARCHAR(4000) NULL
);

-- Input validation
IF @WaitResource IS NULL OR LTRIM(RTRIM(@WaitResource)) = ''
BEGIN
    INSERT INTO @Results (wait_resource, error_message)
    VALUES ('', 'Wait resource parameter is null or empty');
    GOTO OutputResults;
END

SET @WaitResource = LTRIM(RTRIM(@WaitResource));

-- Special case: 0:0:0 wait resource
IF @WaitResource = '0:0:0'
BEGIN
    INSERT INTO @Results (wait_resource, info)
    VALUES (@WaitResource, 'Special case - see https://www.sqlskills.com/blogs/paul/the-curious-case-of-what-is-the-wait-resource-000/');
    GOTO OutputResults;
END

-- Handle KEY wait resources
IF @WaitResource LIKE 'KEY: %'
BEGIN
    BEGIN TRY
        -- Parse KEY: DatabaseID:Hobt_id (hash_value)
        DECLARE @KeyStart INT = 6; -- Length of 'KEY: ' + 1
        DECLARE @FirstColon INT = CHARINDEX(':', @WaitResource, @KeyStart);
        DECLARE @SpacePos INT = CHARINDEX(' ', @WaitResource, @FirstColon);
        
        IF @FirstColon = 0
        BEGIN
            INSERT INTO @Results (wait_resource, error_message)
            VALUES (@WaitResource, 'Invalid KEY wait resource format');
            GOTO OutputResults;
        END
        
        SET @DBID = TRY_CAST(SUBSTRING(@WaitResource, @KeyStart, @FirstColon - @KeyStart) AS INT);
        SET @HOBTID = TRY_CAST(SUBSTRING(@WaitResource, @FirstColon + 1, 
            CASE WHEN @SpacePos > 0 THEN @SpacePos - @FirstColon - 1 
                 ELSE LEN(@WaitResource) - @FirstColon END) AS BIGINT);
        
        IF @DBID IS NULL OR @HOBTID IS NULL
        BEGIN
            INSERT INTO @Results (wait_resource, error_message)
            VALUES (@WaitResource, 'Unable to parse database ID or HOBT ID from KEY wait resource');
            GOTO OutputResults;
        END
        
        -- Validate database exists and is accessible
        SELECT @DBName = name, @DBState = state, @DBCollation = collation_name
        FROM sys.databases 
        WHERE database_id = @DBID;
        
        IF @DBName IS NULL
        BEGIN
            INSERT INTO @Results (wait_resource, database_id, error_message)
            VALUES (@WaitResource, @DBID, 'Database ID not found');
            GOTO OutputResults;
        END
        
        IF @DBState <> 0 -- ONLINE
        BEGIN
            INSERT INTO @Results (wait_resource, database_name, database_id, error_message)
            VALUES (@WaitResource, @DBName, @DBID, 'Database is not online (state: ' + CAST(@DBState AS VARCHAR(10)) + ')');
            GOTO OutputResults;
        END
        
        -- Build dynamic SQL with proper escaping
        SET @SQL = N'USE ' + QUOTENAME(@DBName) + N';
        SELECT TOP 1
            p.object_id,
            p.index_id,
            p.partition_id,
            o.type_desc as object_type
        FROM sys.partitions p WITH (NOLOCK)
        LEFT JOIN sys.objects o WITH (NOLOCK) ON p.object_id = o.object_id
        WHERE p.hobt_id = @HOBTID';
        
        -- Temporary table for dynamic SQL results
        CREATE TABLE #TempKeyResults (
            object_id INT,
            index_id INT,
            partition_id BIGINT,
            object_type VARCHAR(50)
        );
        
        INSERT INTO #TempKeyResults
        EXEC sp_executesql @SQL, N'@HOBTID BIGINT', @HOBTID;
        
        SELECT @ObjectID = object_id, @IndexID = index_id, 
               @PartitionID = partition_id
        FROM #TempKeyResults;
        
        DROP TABLE #TempKeyResults;
        
        IF @ObjectID IS NULL
        BEGIN
            INSERT INTO @Results (wait_resource, database_name, database_id, hobt_id, error_message)
            VALUES (@WaitResource, @DBName, @DBID, @HOBTID, 'HOBT ID not found in database');
            GOTO OutputResults;
        END
        
        -- Get object details
        SET @SQL = N'USE ' + QUOTENAME(@DBName) + N';
        SELECT 
            ISNULL(s.name, ''<system>'') as schema_name,
            ISNULL(o.name, ''<unknown>'') as object_name,
            ISNULL(i.name, CASE 
                WHEN i.index_id = 0 THEN ''<heap>''
                WHEN i.index_id = 1 THEN ''<clustered>''
                ELSE ''<index_id_'' + CAST(i.index_id AS VARCHAR(10)) + ''>''
            END) as index_name,
            o.type_desc as object_type
        FROM (SELECT @ObjectID as object_id, @IndexID as index_id) t
        LEFT JOIN sys.objects o WITH (NOLOCK) ON t.object_id = o.object_id
        LEFT JOIN sys.schemas s WITH (NOLOCK) ON o.schema_id = s.schema_id
        LEFT JOIN sys.indexes i WITH (NOLOCK) ON t.object_id = i.object_id AND t.index_id = i.index_id';
        
        -- Temporary table for results
        CREATE TABLE #TempKeyDetails (
            schema_name SYSNAME,
            object_name SYSNAME,
            index_name SYSNAME,
            object_type VARCHAR(50)
        );
        
        INSERT INTO #TempKeyDetails
        EXEC sp_executesql @SQL, N'@ObjectID INT, @IndexID INT', @ObjectID, @IndexID;
        
        INSERT INTO @Results (wait_resource, database_name, database_id, schema_name, object_name, 
                             index_name, hobt_id, partition_id, object_type)
        SELECT @WaitResource, @DBName, @DBID, schema_name, object_name, 
               index_name, @HOBTID, @PartitionID, object_type
        FROM #TempKeyDetails;
        
        DROP TABLE #TempKeyDetails;
        
    END TRY
    BEGIN CATCH
        INSERT INTO @Results (wait_resource, database_name, database_id, error_message)
        VALUES (@WaitResource, @DBName, @DBID, 'Error processing KEY wait: ' + ERROR_MESSAGE());
    END CATCH
END

-- Handle PAGE, RID, and numeric wait resources
ELSE IF @WaitResource LIKE 'PAGE: %' OR @WaitResource LIKE 'RID: %' OR @WaitResource LIKE '[0-9]%:%:%'
BEGIN
    BEGIN TRY
        SET @NormalizedWaitResource = @WaitResource;
        
        -- Parse different formats
        IF @WaitResource LIKE 'RID: %'
        BEGIN
            -- Format: RID: DatabaseID:FileID:PageID:Slot
            SET @NormalizedWaitResource = SUBSTRING(@WaitResource, 6, LEN(@WaitResource));
            SET @idx1 = LEN(@NormalizedWaitResource) - CHARINDEX(':', REVERSE(@NormalizedWaitResource)) + 1;
            SET @SlotID = TRY_CAST(SUBSTRING(@NormalizedWaitResource, @idx1 + 1, LEN(@NormalizedWaitResource)) AS INT);
            SET @NormalizedWaitResource = SUBSTRING(@NormalizedWaitResource, 1, @idx1 - 1);
        END
        ELSE IF @WaitResource LIKE 'PAGE: %'
        BEGIN
            -- Format: PAGE: DatabaseID:FileID:PageID
            SET @NormalizedWaitResource = SUBSTRING(@WaitResource, 7, LEN(@WaitResource));
        END
        ELSE IF @WaitResource LIKE '[0-9]%:%:%(%)'
        BEGIN
            -- Format: DatabaseID:FileID:PageID (Additional Info)
            SET @NormalizedWaitResource = SUBSTRING(@WaitResource, 1, CHARINDEX('(', @WaitResource) - 1);
            SET @NormalizedWaitResource = LTRIM(RTRIM(@NormalizedWaitResource));
        END
        
        -- Parse DatabaseID:FileID:PageID
        SET @idx1 = CHARINDEX(':', @NormalizedWaitResource);
        SET @idx2 = CHARINDEX(':', @NormalizedWaitResource, @idx1 + 1);
        
        IF @idx1 = 0 OR @idx2 = 0
        BEGIN
            INSERT INTO @Results (wait_resource, error_message)
            VALUES (@WaitResource, 'Invalid page/RID wait resource format');
            GOTO OutputResults;
        END
        
        SET @DBID = TRY_CAST(SUBSTRING(@NormalizedWaitResource, 1, @idx1 - 1) AS INT);
        SET @FileID = TRY_CAST(SUBSTRING(@NormalizedWaitResource, @idx1 + 1, @idx2 - @idx1 - 1) AS INT);
        SET @PageID = TRY_CAST(SUBSTRING(@NormalizedWaitResource, @idx2 + 1, LEN(@NormalizedWaitResource)) AS BIGINT);
        
        IF @DBID IS NULL OR @FileID IS NULL OR @PageID IS NULL
        BEGIN
            INSERT INTO @Results (wait_resource, error_message)
            VALUES (@WaitResource, 'Unable to parse database ID, file ID, or page ID');
            GOTO OutputResults;
        END
        
        -- Validate database
        SELECT @DBName = name, @DBState = state
        FROM sys.databases 
        WHERE database_id = @DBID;
        
        IF @DBName IS NULL
        BEGIN
            INSERT INTO @Results (wait_resource, database_id, error_message)
            VALUES (@WaitResource, @DBID, 'Database ID not found');
            GOTO OutputResults;
        END
        
        IF @DBState <> 0
        BEGIN
            INSERT INTO @Results (wait_resource, database_name, database_id, error_message)
            VALUES (@WaitResource, @DBName, @DBID, 'Database is not online');
            GOTO OutputResults;
        END
        
        -- Check if DBCC PAGE is supported
        IF SERVERPROPERTY('EngineEdition') NOT IN (1,2,3,4) OR @SQLVersion < 10
        BEGIN
            INSERT INTO @Results (wait_resource, database_name, database_id, file_id, page_id, slot_id, error_message)
            VALUES (@WaitResource, @DBName, @DBID, @FileID, @PageID, @SlotID, 'DBCC PAGE not supported on this SQL Server edition/version');
            GOTO OutputResults;
        END
        
        -- Create table for DBCC PAGE results
        DECLARE @DBCCPAGE TABLE (
            ParentObject NVARCHAR(255),
            [Object] NVARCHAR(255),
            Field NVARCHAR(255),
            Value NVARCHAR(255)
        );
        
        -- Execute DBCC PAGE
        SET @SQL = N'DBCC PAGE(' + CAST(@DBID AS NVARCHAR(10)) + N',' + 
                   CAST(@FileID AS NVARCHAR(10)) + N',' + 
                   CAST(@PageID AS NVARCHAR(20)) + N') WITH TABLERESULTS';
        
        BEGIN TRY
            INSERT INTO @DBCCPAGE
            EXEC sp_executesql @SQL;
        END TRY
        BEGIN CATCH
            INSERT INTO @Results (wait_resource, database_name, database_id, file_id, page_id, error_message)
            VALUES (@WaitResource, @DBName, @DBID, @FileID, @PageID, 'DBCC PAGE failed: ' + ERROR_MESSAGE());
            GOTO OutputResults;
        END CATCH
        
        -- Extract metadata
        SELECT @IndexID = TRY_CAST(Value AS INT)
        FROM @DBCCPAGE 
        WHERE Field = 'Metadata: IndexId';
        
        SELECT @ObjectID = TRY_CAST(Value AS INT)
        FROM @DBCCPAGE 
        WHERE Field = 'Metadata: ObjectId';
        
        SELECT @m_type = TRY_CAST(Value AS INT)
        FROM @DBCCPAGE 
        WHERE Field = 'm_type';
        
        -- Get page type description
        SET @PageType = ISNULL(CAST(@m_type AS VARCHAR(10)), 'Unknown') + ' - ' + 
            CASE @m_type
                WHEN 1 THEN 'Data'
                WHEN 2 THEN 'Index'
                WHEN 3 THEN 'Text mix'
                WHEN 4 THEN 'Text tree'
                WHEN 7 THEN 'Sort'
                WHEN 8 THEN 'GAM'
                WHEN 9 THEN 'SGAM'
                WHEN 10 THEN 'IAM'
                WHEN 11 THEN 'PFS'
                WHEN 13 THEN 'Boot'
                WHEN 15 THEN 'File header'
                WHEN 16 THEN 'Diff map'
                WHEN 17 THEN 'ML map'
                WHEN 18 THEN 'Deallocated DBCC CHECKDB'
                WHEN 19 THEN 'Index reorg temp page'
                WHEN 20 THEN 'Bulk Load pre-allocation'
                ELSE 'Other'
            END;
        
        -- Get object details if available
        IF @ObjectID IS NOT NULL AND @ObjectID > 0
        BEGIN
            SET @SQL = N'USE ' + QUOTENAME(@DBName) + N';
            SELECT 
                ISNULL(s.name, ''<system>'') as schema_name,
                ISNULL(o.name, ''<unknown>'') as object_name,
                ISNULL(i.name, CASE 
                    WHEN @IndexID = 0 THEN ''<heap>''
                    WHEN @IndexID = 1 THEN ''<clustered>''
                    ELSE ''<index_id_'' + CAST(@IndexID AS VARCHAR(10)) + ''>''
                END) as index_name,
                o.type_desc as object_type
            FROM (SELECT @ObjectID as object_id) t
            LEFT JOIN sys.objects o WITH (NOLOCK) ON t.object_id = o.object_id
            LEFT JOIN sys.schemas s WITH (NOLOCK) ON o.schema_id = s.schema_id
            LEFT JOIN sys.indexes i WITH (NOLOCK) ON t.object_id = i.object_id AND i.index_id = @IndexID';
            
            CREATE TABLE #TempPageDetails (
                schema_name SYSNAME,
                object_name SYSNAME,
                index_name SYSNAME,
                object_type VARCHAR(50)
            );
            
            INSERT INTO #TempPageDetails
            EXEC sp_executesql @SQL, N'@ObjectID INT, @IndexID INT', @ObjectID, @IndexID;
            
            INSERT INTO @Results (wait_resource, database_name, database_id, schema_name, object_name, 
                                 index_name, page_type, file_id, page_id, slot_id, object_type)
            SELECT @WaitResource, @DBName, @DBID, schema_name, object_name, 
                   index_name, @PageType, @FileID, @PageID, @SlotID, object_type
            FROM #TempPageDetails;
            
            DROP TABLE #TempPageDetails;
        END
        ELSE
        BEGIN
            INSERT INTO @Results (wait_resource, database_name, database_id, page_type, file_id, page_id, slot_id)
            VALUES (@WaitResource, @DBName, @DBID, @PageType, @FileID, @PageID, @SlotID);
        END
        
        -- Store DBCC PAGE output for debugging
        IF @Debug = 1
        BEGIN
            SELECT 'DBCC PAGE Output' as DebugInfo, * FROM @DBCCPAGE;
        END
        
    END TRY
    BEGIN CATCH
        INSERT INTO @Results (wait_resource, database_name, database_id, error_message)
        VALUES (@WaitResource, @DBName, @DBID, 'Error processing PAGE/RID wait: ' + ERROR_MESSAGE());
    END CATCH
END

-- Handle OBJECT wait resources
ELSE IF @WaitResource LIKE 'OBJECT: %'
BEGIN
    BEGIN TRY
        -- Format: OBJECT: DatabaseID:ObjectID
        SET @idx1 = CHARINDEX(':', @WaitResource, 9); -- After 'OBJECT: '
        SET @idx2 = CHARINDEX(':', @WaitResource, @idx1 + 1);
        
        IF @idx1 = 0
        BEGIN
            INSERT INTO @Results (wait_resource, error_message)
            VALUES (@WaitResource, 'Invalid OBJECT wait resource format');
            GOTO OutputResults;
        END
        
        SET @DBID = TRY_CAST(SUBSTRING(@WaitResource, 9, @idx1 - 9) AS INT);
        SET @ObjectID = TRY_CAST(SUBSTRING(@WaitResource, @idx1 + 1, 
            CASE WHEN @idx2 > 0 THEN @idx2 - @idx1 - 1 
                 ELSE LEN(@WaitResource) - @idx1 END) AS INT);
        
        IF @DBID IS NULL OR @ObjectID IS NULL
        BEGIN
            INSERT INTO @Results (wait_resource, error_message)
            VALUES (@WaitResource, 'Unable to parse database ID or object ID from OBJECT wait resource');
            GOTO OutputResults;
        END
        
        -- Validate database
        SELECT @DBName = name, @DBState = state
        FROM sys.databases 
        WHERE database_id = @DBID;
        
        IF @DBName IS NULL
        BEGIN
            INSERT INTO @Results (wait_resource, database_id, error_message)
            VALUES (@WaitResource, @DBID, 'Database ID not found');
            GOTO OutputResults;
        END
        
        IF @DBState <> 0
        BEGIN
            INSERT INTO @Results (wait_resource, database_name, database_id, error_message)
            VALUES (@WaitResource, @DBName, @DBID, 'Database is not online');
            GOTO OutputResults;
        END
        
        -- Get object details
        SET @SQL = N'USE ' + QUOTENAME(@DBName) + N';
        SELECT 
            ISNULL(s.name, ''<system>'') as schema_name,
            ISNULL(o.name, ''<unknown>'') as object_name,
            o.type_desc as object_type
        FROM (SELECT @ObjectID as object_id) t
        LEFT JOIN sys.objects o WITH (NOLOCK) ON t.object_id = o.object_id
        LEFT JOIN sys.schemas s WITH (NOLOCK) ON o.schema_id = s.schema_id';
        
        CREATE TABLE #TempObjectDetails (
            schema_name SYSNAME,
            object_name SYSNAME,
            object_type VARCHAR(50)
        );
        
        INSERT INTO #TempObjectDetails
        EXEC sp_executesql @SQL, N'@ObjectID INT', @ObjectID;
        
        INSERT INTO @Results (wait_resource, database_name, database_id, schema_name, object_name, object_type)
        SELECT @WaitResource, @DBName, @DBID, schema_name, object_name, object_type
        FROM #TempObjectDetails;
        
        DROP TABLE #TempObjectDetails;
        
    END TRY
    BEGIN CATCH
        INSERT INTO @Results (wait_resource, database_name, database_id, error_message)
        VALUES (@WaitResource, @DBName, @DBID, 'Error processing OBJECT wait: ' + ERROR_MESSAGE());
    END CATCH
END

-- Handle additional wait resource types
ELSE IF @WaitResource LIKE 'APPLICATION: %'
BEGIN
    INSERT INTO @Results (wait_resource, info)
    VALUES (@WaitResource, 'Application lock - custom application-defined resource');
END

ELSE IF @WaitResource LIKE 'DATABASE: %'
BEGIN
    SET @DBID = TRY_CAST(SUBSTRING(@WaitResource, 11, LEN(@WaitResource)) AS INT);
    SELECT @DBName = name FROM sys.databases WHERE database_id = @DBID;
    
    INSERT INTO @Results (wait_resource, database_name, database_id, info)
    VALUES (@WaitResource, @DBName, @DBID, 'Database-level lock');
END

ELSE IF @WaitResource LIKE 'FILE: %'
BEGIN
    -- Format: FILE: DatabaseID:FileID
    SET @idx1 = CHARINDEX(':', @WaitResource, 7);
    IF @idx1 > 0
    BEGIN
        SET @DBID = TRY_CAST(SUBSTRING(@WaitResource, 7, @idx1 - 7) AS INT);
        SET @FileID = TRY_CAST(SUBSTRING(@WaitResource, @idx1 + 1, LEN(@WaitResource)) AS INT);
        SELECT @DBName = name FROM sys.databases WHERE database_id = @DBID;
        
        INSERT INTO @Results (wait_resource, database_name, database_id, file_id, info)
        VALUES (@WaitResource, @DBName, @DBID, @FileID, 'File-level lock');
    END
    ELSE
    BEGIN
        INSERT INTO @Results (wait_resource, info)
        VALUES (@WaitResource, 'File-level lock (unable to parse details)');
    END
END

ELSE IF @WaitResource LIKE 'HOBT: %'
BEGIN
    SET @HOBTID = TRY_CAST(SUBSTRING(@WaitResource, 7, LEN(@WaitResource)) AS BIGINT);
    INSERT INTO @Results (wait_resource, hobt_id, info)
    VALUES (@WaitResource, @HOBTID, 'Heap or B-tree lock');
END

ELSE IF @WaitResource LIKE 'METADATA: %'
BEGIN
    INSERT INTO @Results (wait_resource, info)
    VALUES (@WaitResource, 'Metadata lock - system catalog access');
END

ELSE IF @WaitResource LIKE 'ALLOCATION_UNIT: %'
BEGIN
    INSERT INTO @Results (wait_resource, info)
    VALUES (@WaitResource, 'Allocation unit lock');
END

-- Unsupported wait resource type
ELSE
BEGIN
    INSERT INTO @Results (wait_resource, info)
    VALUES (@WaitResource, 'Wait resource type not yet supported for decoding. Please check for newer version of this script.');
END

OutputResults:
-- Return results
SELECT 
    wait_resource,
    database_name,
    database_id,
    schema_name,
    object_name,
    index_name,
    page_type,
    file_id,
    page_id,
    slot_id,
    hobt_id,
    partition_id,
    object_type,
    info,
    error_message,
    GETDATE() as decoded_at
FROM @Results
ORDER BY wait_resource;

-- Additional system information
IF EXISTS (SELECT 1 FROM @Results WHERE error_message IS NULL)
BEGIN
    SELECT 
        'System Information' as info_type,
        @@SERVERNAME as server_name,
        SERVERPROPERTY('ProductVersion') as sql_version,
        SERVERPROPERTY('ProductLevel') as service_pack,
        SERVERPROPERTY('Edition') as edition,
        SERVERPROPERTY('EngineEdition') as engine_edition
END

SET NOCOUNT OFF;
