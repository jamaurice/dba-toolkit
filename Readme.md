# SQL Wait Detective 🕵️‍♂️

**A robust SQL Server wait resource decoder for investigating blocking and locking issues**

SQL Wait Detective transforms cryptic SQL Server wait resource strings into human-readable information, helping DBAs and developers quickly identify the root cause of blocking situations.

## 🚀 Features

- **Comprehensive Wait Resource Support**: Decodes KEY, PAGE, RID, OBJECT, APPLICATION, DATABASE, FILE, HOBT, METADATA, and ALLOCATION_UNIT wait resources
- **Enhanced Error Handling**: Robust error handling with descriptive messages for troubleshooting
- **Security Hardened**: SQL injection prevention and input validation
- **Database State Validation**: Checks for database availability and accessibility
- **Rich Output**: Structured results with metadata including object types, partition IDs, and system context
- **Debug Mode**: Optional detailed diagnostic output for complex scenarios
- **Version Compatibility**: Works with SQL Server 2016+ with automatic feature detection
- **Performance Optimized**: Uses NOLOCK hints and efficient parsing algorithms

## 📋 Requirements

- SQL Server 2016 or later
- Appropriate permissions to:
  - Access system catalog views (`sys.databases`, `sys.objects`, `sys.partitions`, etc.)
  - Execute `DBCC PAGE` (for PAGE/RID analysis)
  - Access target databases referenced in wait resources

## 🛠️ Installation & Usage

### Basic Usage

1. Copy the script content
2. Replace `{wait_resource}` with your actual wait resource string
3. Execute the script

```sql
-- Example: Decode a KEY wait resource
DECLARE @WaitResource NVARCHAR(256) = 'KEY: 6:72057594038910976 (3c0b93e0e027)';
-- Paste the script here with the above declaration
```

### Debug Mode

Enable debug mode for additional diagnostic information:

```sql
DECLARE @Debug BIT = 1; -- Add this line after the @WaitResource declaration
```

## 📊 Wait Resource Types Supported

| Type | Format | Description |
|------|--------|-------------|
| **KEY** | `KEY: DatabaseID:HOBT_ID (hash)` | Row-level locks on indexes |
| **PAGE** | `PAGE: DatabaseID:FileID:PageID` | Page-level locks |
| **RID** | `RID: DatabaseID:FileID:PageID:Slot` | Row-level locks on heaps |
| **OBJECT** | `OBJECT: DatabaseID:ObjectID` | Table-level locks |
| **APPLICATION** | `APPLICATION: DatabaseID:resource` | Custom application locks |
| **DATABASE** | `DATABASE: DatabaseID` | Database-level locks |
| **FILE** | `FILE: DatabaseID:FileID` | File-level locks |
| **HOBT** | `HOBT: HOBT_ID` | Heap or B-tree locks |
| **METADATA** | `METADATA: resource` | System catalog locks |
| **ALLOCATION_UNIT** | `ALLOCATION_UNIT: ID` | Allocation unit locks |

## 🔍 Example Usage

### Scenario 1: Investigating a KEY Lock

```sql
-- Wait resource from sys.dm_exec_requests or blocking query
DECLARE @WaitResource NVARCHAR(256) = 'KEY: 5:72057594038910976 (b87435ffe120)';

-- Execute SQL Wait Detective script...
```

**Output:**
```
wait_resource: KEY: 5:72057594038910976 (b87435ffe120)
database_name: AdventureWorks2019
schema_name: Sales
object_name: SalesOrderHeader
index_name: PK_SalesOrderHeader_SalesOrderID
object_type: USER_TABLE
```

### Scenario 2: Analyzing a PAGE Lock

```sql
DECLARE @WaitResource NVARCHAR(256) = 'PAGE: 5:1:12345';
```

**Output:**
```
wait_resource: PAGE: 5:1:12345
database_name: AdventureWorks2019
page_type: 1 - Data
file_id: 1
page_id: 12345
schema_name: Sales
object_name: Customer
```

## 📋 Output Columns

| Column | Description |
|--------|-------------|
| `wait_resource` | Original wait resource string |
| `database_name` | Database name (if available) |
| `database_id` | Database ID |
| `schema_name` | Schema name of the object |
| `object_name` | Table, view, or object name |
| `index_name` | Index name (if applicable) |
| `page_type` | Page type description (for PAGE/RID waits) |
| `file_id` | Database file ID |
| `page_id` | Page ID within the file |
| `slot_id` | Row slot ID (for RID waits) |
| `hobt_id` | Heap or B-tree ID |
| `partition_id` | Partition ID |
| `object_type` | Object type (USER_TABLE, INDEX, etc.) |
| `info` | Additional information or help links |
| `error_message` | Error details (if any) |
| `decoded_at` | Timestamp of analysis |

## 🔧 Common Use Cases

### Blocking Investigation Workflow

1. **Identify blocking**: Query `sys.dm_exec_requests` or use sp_who2
2. **Extract wait resource**: Get the `wait_resource` from the blocked session
3. **Decode with SQL Wait Detective**: Run the script to identify the contested object
4. **Analyze the object**: Review table structure, indexes, and typical access patterns
5. **Resolve**: Optimize queries, add indexes, or adjust isolation levels

### Example Blocking Query

```sql
SELECT 
    blocking_session_id,
    session_id,
    wait_type,
    wait_resource,
    wait_time,
    blocking_these_sql_text = b.text,
    sql_text = t.text
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
LEFT JOIN sys.dm_exec_requests b ON r.blocking_session_id = b.session_id
CROSS APPLY sys.dm_exec_sql_text(b.sql_handle) b
WHERE blocking_session_id > 0;
```

## ⚠️ Troubleshooting

### Common Issues

**Database Not Found**
- Verify the database ID exists in `sys.databases`
- Check if you have access to the database

**Database Not Online**
- Ensure the database is in ONLINE state
- Wait resources from offline databases cannot be fully decoded

**DBCC PAGE Not Supported**
- Some SQL Server editions don't support DBCC PAGE
- The script will still provide basic information without page analysis

**Permission Denied**
- Ensure you have VIEW SERVER STATE permission
- For cross-database analysis, ensure appropriate database access

### Debug Mode

Enable debug mode to see additional diagnostic information:

```sql
DECLARE @Debug BIT = 1;
```

This will show DBCC PAGE output and intermediate parsing steps.

## 🔗 Related Resources

- [SQL Server Lock Compatibility Matrix](https://docs.microsoft.com/en-us/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide)
- [Understanding SQL Server Blocking](https://docs.microsoft.com/en-us/troubleshoot/sql/performance/understand-resolve-blocking)
- [SQL Server Wait Statistics](https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-wait-stats-transact-sql)

## 🤝 Contributing

Contributions are welcome! Please consider:

- **New wait resource types**: Add support for additional resource formats
- **Enhanced parsing**: Improve parsing logic for edge cases
- **Performance optimizations**: Optimize for large-scale environments
- **Documentation**: Improve examples and troubleshooting guidance

## 📄 License

This script is provided as-is for educational and professional use. Test thoroughly in development environments before production use.

## 🏷️ Version History

- **v2.0** - Enhanced version with comprehensive error handling, additional wait types, and security improvements
- **v1.0** - Original wait resource decoder

---

**Made with ❤️ for the SQL Server community**

*Happy debugging! 🐛🔍* 
