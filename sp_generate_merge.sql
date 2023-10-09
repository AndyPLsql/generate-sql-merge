SET NOCOUNT ON
SET QUOTED_IDENTIFIER ON

IF 'sp_generate_merge' LIKE '#%'
BEGIN
  -- Instal as a temp stored proc on any SQL edition
  PRINT 'Installing sp_generate_merge as a temp stored procedure'
END
ELSE IF OBJECT_ID('sp_MS_marksystemobject', 'P') IS NOT NULL
BEGIN
  -- Install the proc on SQL Server Standard/Developer/Express/Enterprise
  PRINT 'Installing sp_generate_merge as a system stored procedure in [master] database'
  IF DB_NAME() != 'master'
  BEGIN
    RAISERROR ('Wrong database context. Please USE [master] to allow sp_generate_merge to be installed as a system stored procedure. See "INSTALLATION" for more information.', 16, 1)
    SET NOEXEC ON
  END
END
ELSE
BEGIN
  -- Install the proc on Azure SQL/Managed Instance
  IF DB_NAME() = 'master'
  BEGIN
    RAISERROR ('Cannot install sp_generate_merge in master DB as system stored procedures cannot be created on this edition of SQL Server (i.e. Azure SQL or Managed Instance). Please install this proc in a user database or create it as a temporary proc instead. See "INSTALLATION" for more information.', 16, 1)
    SET NOEXEC ON
  END
  ELSE
  BEGIN
    PRINT 'Warning: As this edition of SQL Server (i.e. Azure SQL or Managed Instance) does not allow system stored procedures to be created, sp_generate_merge will be installed within the current database context only: ' + QUOTENAME(DB_NAME()) + '. See "INSTALLATION" for more information.'
  END
END
-- Drop the proc if it already exists
IF OBJECT_ID('sp_generate_merge', 'P') IS NOT NULL OR ('sp_generate_merge' LIKE '#%' AND OBJECT_ID('tempdb..sp_generate_merge', 'P') IS NOT NULL)
BEGIN
  PRINT '(dropping the existing procedure to allow it to be re-created)'
  DROP PROC [sp_generate_merge]
END
GO

CREATE PROC [sp_generate_merge]
(
 @table_name nvarchar(776), -- The table/view for which the MERGE statement will be generated using the existing data. This parameter accepts unquoted single-part identifiers only (e.g. MyTable)
 @target_table nvarchar(776) = NULL, -- Use this parameter to specify a different table name into which the data will be inserted/updated/deleted. This parameter accepts unquoted single-part identifiers (e.g. MyTable) or quoted multi-part identifiers (e.g. [OtherDb].[dbo].[MyTable])
 @from nvarchar(max) = NULL, -- Use this parameter to filter the rows based on a filter condition (using WHERE). Note: To avoid inconsistent ordering of results, including an ORDER BY clause is highly recommended
 @include_values bit = 1, -- When 1, a VALUES clause containing data from @table_name is generated. When 0, data will be sourced directly from @table_name when the MERGE is executed (see example 15 for use case)
 @include_timestamp bit = 0, -- [DEPRECATED] Sql Server does not allow modification of TIMESTAMP datatype
 @debug_mode bit = 0, -- If @debug_mode is set to 1, the SQL statements constructed by this procedure will be printed for later examination
 @schema nvarchar(64) = NULL, -- Use this parameter if you are not the owner of the table
 @ommit_images bit = 0, -- As the image data type is currently unsupported, leaving @ommit_images=0 will cause an error to be raised by sp_generate_merge if an image column is found in the specified table. Proactively specify @ommit_images=1 to exclude image columns and avoid this error.
 @ommit_identity bit = 0, -- Use this parameter to omit the identity columns
 @top int = NULL, -- Use this parameter to generate a MERGE statement only for the TOP n rows
 @cols_to_include nvarchar(max) = NULL, -- List of columns to be included in the MERGE statement
 @cols_to_exclude nvarchar(max) = NULL, -- List of columns to be excluded from the MERGE statement
 @cols_to_join_on nvarchar(max) = NULL, -- List of columns needed to JOIN the source table to the target table (useful when @table_name is missing a primary key) 
 @update_only_if_changed bit = 1, -- When 1, only performs an UPDATE operation if an included column in a matched row has changed.
 @hash_compare_column nvarchar(128) = NULL, -- When specified, change detection will be based on a SHA2_256 hash of the source data (the hash value will be stored in this @target_table column for later comparison; see Example 16)
 @delete_if_not_matched bit = 1, -- When 1, performs a DELETE when the target includes extra rows. When 0, the MERGE statement will only include the INSERT and, if @update_existing=1, UPDATE operations.
 @disable_constraints bit = 0, -- When 1, disables foreign key constraints and enables them after the MERGE statement
 @ommit_computed_cols bit = 1, -- When 1, computed columns will not be included in the MERGE statement
 @ommit_generated_always_cols bit = 1, -- When 1, GENERATED ALWAYS columns will not be included in the MERGE statement
 @include_use_db bit = 1, -- When 1, includes a USE [DatabaseName] statement at the beginning of the generated batch
 @results_to_text bit = 0, -- When 1, outputs results to grid/messages window. When 0, outputs MERGE statement in an XML fragment. When NULL, only the @output OUTPUT parameter is returned.
 @include_rowsaffected bit = 1, -- When 1, a section is added to the end of the batch which outputs rows affected by the MERGE
 @nologo bit = 0, -- When 1, the "About" comment is suppressed from output
 @batch_separator nvarchar(50) = 'GO', -- Batch separator to use. Specify NULL to output all statements within a single batch
 @output nvarchar(max) = null output, -- Use this output parameter to return the generated T-SQL batches to the caller (Hint: specify @batch_separator=NULL to output all statements within a single batch)
 @update_existing bit = 1, -- When 1, performs an UPDATE operation on existing rows. When 0, the MERGE statement will only include the INSERT and, if @delete_if_not_matched=1, DELETE operations.
 @max_rows_per_batch int = NULL, -- When not NULL, splits the MERGE command into multiple batches, each batch merges X rows as specified
 @quiet bit = 0 -- When 1, this proc will not print informational messages and warnings
)
AS
BEGIN

/***********************************************************************************************************
PROCEDURE: sp_generate_merge

GITHUB PROJECT: https://github.com/dnlnln/generate-sql-merge

DESCRIPTION: Generates a MERGE statement from a table which will INSERT/UPDATE/DELETE data 
             based on matching primary key values in the source/target table. The generated statements 
             can be executed to replicate the data in some other location.

INSTALLATION:
  Simply execute this script to install. For details, including alternative install methods, see README.md.

ACKNOWLEDGEMENTS:
  Daniel Nolan -- Creator/maintainer of sp_generate_merge
  https://danielnolan.io

  Narayana Vyas Kondreddi -- Author of sp_generate_inserts, from which this proc was originally forked
  (sp_generate_inserts: Copyright © 2002 Narayana Vyas Kondreddi. All rights reserved.)
  http://vyaskn.tripod.com/code

  Bill Gibson -- Blog that detailed the static data table use case; the inspiration for this proc
  http://blogs.msdn.com/b/ssdt/archive/2012/02/02/including-data-in-an-sql-server-database-project.aspx

  Bill Graziano -- Blog that provided the groundwork for MERGE statement generation
  http://weblogs.sqlteam.com/billg/archive/2011/02/15/generate-merge-statements-from-a-table.aspx 

  Christian Lorber -- Contributed hashvalue-based change detection that enables efficient ETL implementations
  https://twitter.com/chlorber

  Nathan Skerl -- StackOverflow answer that provided a workaround for the output truncation problem
  http://stackoverflow.com/a/10489767/266882

  Eitan Blumin -- Added the ability to divide merges into multiple batches of x rows
  https://www.eitanblumin.com/

LICENSE: See LICENSE file

FURTHER INFO: See README.md

USAGE:
  1. Install the proc by executing this script (see README.md for details)
  2. If using SSMS, ensure that it is configured to send results to grid rather than text.
  3. Execute the proc e.g. EXEC [sp_generate_merge] 'MyTable'
  4. Open the result set (eg. in SSMS/ADO/VSCode, click the hyperlink in the grid)
  5. Copy the SQL portion of the text and paste into a new query window to execute.

EXAMPLES:
Example 1: To generate a MERGE statement for table 'titles':
 
  EXEC sp_generate_merge 'titles'

Example 2: To generate a MERGE statement for 'titlesCopy' table from 'titles' table:

  EXEC sp_generate_merge 'titles', 'titlesCopy'

Example 3: To generate a MERGE statement for table 'titles' that will unconditionally UPDATE matching rows 
 (ie. not perform a "has data changed?" check prior to going ahead with an UPDATE):
 
  EXEC sp_generate_merge 'titles', @update_only_if_changed = 0

Example 4: To generate a MERGE statement for 'titles' table for only those titles which contain the word 'Computer' in them:
 Note: Do not complicate the FROM or WHERE clause here. It's assumed that you are good with T-SQL if you are using this parameter

  EXEC sp_generate_merge 'titles', @from = "from titles where title like '%Computer%' order by title_id"

Example 5: To print diagnostic info during execution of this proc:

  EXEC sp_generate_merge 'titles', @debug_mode = 1

Example 6: If the table is in a different schema to the default eg. `Contact.AddressType`:

  EXEC sp_generate_merge 'AddressType', @schema = 'Contact'

Example 7: To generate a MERGE statement for the rest of the columns excluding those of the `image` data type:

  EXEC sp_generate_merge 'imgtable', @ommit_images = 1

Example 8: To generate a MERGE statement excluding (omitting) IDENTITY columns:
 (By default IDENTITY columns are included in the MERGE statement)

  EXEC sp_generate_merge 'mytable', @ommit_identity = 1

Example 9: To generate a MERGE statement for the TOP 10 rows in the table:
 
  EXEC sp_generate_merge 'mytable', @top = 10

Example 10: To generate a MERGE statement with only those columns you want:
 
  EXEC sp_generate_merge 'titles', @cols_to_include = "'title','title_id','au_id'"

Example 11: To generate a MERGE statement by omitting certain columns:
 
  EXEC sp_generate_merge 'titles', @cols_to_exclude = "'title','title_id','au_id'"

Example 12: To avoid checking the foreign key constraints while loading data with a MERGE statement:
 
  EXEC sp_generate_merge 'titles', @disable_constraints = 1

Example 13: To exclude computed columns from the MERGE statement:

  EXEC sp_generate_merge 'MyTable', @ommit_computed_cols = 1

Example 14: To generate a MERGE statement for a table that lacks a primary key:
 
  EXEC sp_generate_merge 'StateProvince', @schema = 'Person', @cols_to_join_on = "'StateProvinceCode'"

Example 15: To generate a statement that MERGEs data directly from the source table to a table in another database:

  EXEC sp_generate_merge 'StateProvince', @schema = 'Person', @include_values = 0, @target_table = '[OtherDb].[Person].[StateProvince]'

Example 16: To generate a MERGE statement that will update the target table if the calculated hash value of the source does not match the [Hashvalue] column in the target:

  EXEC sp_generate_merge
    @schema = 'Person', 
    @target_table = '[Person].[StateProvince]', 
    @table_name = 'v_StateProvince',
    @include_values = 0,   
    @hash_compare_column = 'Hashvalue',
    @include_rowsaffected = 0,
    @nologo = 1,
    @cols_to_join_on = "'ID'"

Example 17: To generate and immediately execute a MERGE statement that performs an ETL from a table in one database to another:

  DECLARE @sql NVARCHAR(MAX)
  EXEC [AdventureWorks]..sp_generate_merge @output = @sql output, @results_to_text = null, @schema = 'Person', @table_name = 'AddressType', @include_values = 0, @include_use_db = 0, @batch_separator = null, @target_table = '[AdventureWorks_Target].[Person].[AddressType]'
  EXEC [AdventureWorks]..sp_executesql @sql

Example 18: To generate a MERGE that works with a subset of data from the source table only (e.g. will only INSERT/UPDATE rows that meet certain criteria, and not delete unmatched rows):

  SELECT * INTO #CurrencyRateFiltered FROM AdventureWorks.Sales.CurrencyRate WHERE ToCurrencyCode = 'AUD';
  ALTER TABLE #CurrencyRateFiltered ADD CONSTRAINT PK_Sales_CurrencyRate PRIMARY KEY CLUSTERED ( CurrencyRateID )
  EXEC tempdb..sp_generate_merge @table_name='#CurrencyRateFiltered', @target_table='[AdventureWorks].[Sales].[CurrencyRate]', @delete_if_not_matched = 0, @include_use_db = 0;

Example 19: To generate a MERGE split into batches based on a max rowcount per batch:
  Note: @delete_if_not_matched must be 0, and @include_values must be 1

  EXEC [AdventureWorks]..[sp_generate_merge] @table_name = 'MyTable', @schema = 'dbo', @delete_if_not_matched = 0, @max_rows_per_batch = 100
 
***********************************************************************************************************/

SET NOCOUNT ON

--Making sure user only uses either @cols_to_include or @cols_to_exclude
IF ((@cols_to_include IS NOT NULL) AND (@cols_to_exclude IS NOT NULL))
 BEGIN
 RAISERROR('Use either @cols_to_include or @cols_to_exclude. Do not use both the parameters at once',16,1)
 RETURN -1 --Failure. Reason: Both @cols_to_include and @cols_to_exclude parameters are specified
 END


--Making sure the @cols_to_include, @cols_to_exclude and @cols_to_join_on parameters are receiving values in proper format
IF ((@cols_to_include IS NOT NULL) AND (PATINDEX('''%''',@cols_to_include COLLATE DATABASE_DEFAULT) = 0))
 BEGIN
 RAISERROR('Invalid use of @cols_to_include property',16,1)
 PRINT 'Specify column names surrounded by single quotes and separated by commas'
 PRINT 'Eg: EXEC sp_generate_merge "titles", @cols_to_include = "''title_id'',''title''"'
 RETURN -1 --Failure. Reason: Invalid use of @cols_to_include property
 END

IF ((@cols_to_exclude IS NOT NULL) AND (PATINDEX('''%''',@cols_to_exclude COLLATE DATABASE_DEFAULT) = 0))
 BEGIN
 RAISERROR('Invalid use of @cols_to_exclude property',16,1)
 PRINT 'Specify column names surrounded by single quotes and separated by commas'
 PRINT 'Eg: EXEC sp_generate_merge "titles", @cols_to_exclude = "''title_id'',''title''"'
 RETURN -1 --Failure. Reason: Invalid use of @cols_to_exclude property
 END

IF ((@cols_to_join_on IS NOT NULL) AND (PATINDEX('''%''',@cols_to_join_on COLLATE DATABASE_DEFAULT) = 0))
 BEGIN
 RAISERROR('Invalid use of @cols_to_join_on property',16,1)
 PRINT 'Specify column names surrounded by single quotes and separated by commas'
 PRINT 'Eg: EXEC sp_generate_merge "StateProvince", @schema = "Person", @cols_to_join_on = "''StateProvinceCode''"'
 RETURN -1 --Failure. Reason: Invalid use of @cols_to_join_on property
 END

 IF @hash_compare_column IS NOT NULL AND @update_only_if_changed = 0
 BEGIN
	RAISERROR('Invalid use of @update_only_if_changed property',16,1)
	PRINT 'The @hash_compare_column param is set, however @update_only_if_changed is set to 0. To utilize hash-based change detection, please ensure @update_only_if_changed is set to 1.'
	RETURN -1 --Failure. Reason: Invalid use of @update_only_if_changed property
 END	

 IF @hash_compare_column IS NOT NULL AND @include_values = 1
 BEGIN
	RAISERROR('Invalid use of @include_values',16,1)
	PRINT 'Using @hash_compare_column together with @include_values is currenty unsupported. Our intention is to support this in the future, however for now @hash_compare_column can only be specified when @include_values=0'
	RETURN -1 --Failure. Reason: Invalid use of @include_values property
 END

--Checking to see if the database name is specified along wih the table name
--Your database context should be local to the table for which you want to generate a MERGE statement
--specifying the database name is not allowed
IF (PARSENAME(@table_name,3)) IS NOT NULL
 BEGIN
 RAISERROR('Do not specify the database name. Be in the required database and just specify the table name.',16,1)
 RETURN -1 --Failure. Reason: Database name is specified along with the table name, which is not allowed
 END

IF @max_rows_per_batch IS NOT NULL AND @delete_if_not_matched = 1
BEGIN
	RAISERROR('Invalid use of @max_rows_per_batch property in combination with @delete_if_not_matched',16,1)
	PRINT 'The @max_rows_per_batch param is set, however @delete_if_not_matched is set to 1. To utilize batch-based merge, please ensure @delete_if_not_matched is set to 0.'
	RETURN -1 --Failure. Reason: Invalid use of @max_rows_per_batch and @delete_if_not_matched properties
END

IF @max_rows_per_batch IS NOT NULL AND @include_values = 0
BEGIN
	RAISERROR('Invalid use of @max_rows_per_batch property in combination with @include_values',16,1)
	PRINT 'The @max_rows_per_batch param is set, however @include_values is set to 0. To utilize batch-based merge, please ensure @include_values is set to 1.'
	RETURN -1 --Failure. Reason: Invalid use of @max_rows_per_batch and @include_values properties
END

IF @max_rows_per_batch <= 0
BEGIN
	RAISERROR('Invalid use of @max_rows_per_batch',16,1)
	PRINT 'The @max_rows_per_batch param must be set to 1 or higher.'
	RETURN -1 --Failure. Reason: Invalid use of @max_rows_per_batch
END

DECLARE @Internal_Table_Name NVARCHAR(128)
IF PARSENAME(@table_name,1) LIKE '#%' COLLATE DATABASE_DEFAULT
BEGIN
	IF DB_NAME() <> 'tempdb'
	BEGIN
		RAISERROR('Incorrect database context. The proc must be executed against [tempdb] when a temporary table is specified.',16,1)
		PRINT 'To resolve, execute the proc in the context of [tempdb], e.g. EXEC tempdb..sp_generate_merge @table_name=''' + @table_name COLLATE DATABASE_DEFAULT + ''''
		RETURN -1 --Failure. Reason: Temporary tables cannot be referenced in a user db
	END
	SET @Internal_Table_Name = (SELECT [name] FROM sys.objects WHERE [object_id] = OBJECT_ID(@table_name COLLATE DATABASE_DEFAULT))
END
ELSE
BEGIN
	SET @Internal_Table_Name = @table_name COLLATE DATABASE_DEFAULT
END

--Checking for the existence of 'user table' or 'view'
--This procedure is not written to work on system tables
--To script the data in system tables, just create a view on the system tables and script the view instead
IF @schema IS NULL
 BEGIN
 IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = @Internal_Table_Name COLLATE DATABASE_DEFAULT AND (TABLE_TYPE = 'BASE TABLE' OR TABLE_TYPE = 'VIEW') AND TABLE_SCHEMA = SCHEMA_NAME())
 BEGIN
 RAISERROR('User table or view not found.',16,1)
 PRINT 'You may see this error if the specified table is not in your default schema (' + SCHEMA_NAME() + '). In that case use @schema parameter to specify the schema name.'
 PRINT 'Make sure you have SELECT permission on that table or view.'
 RETURN -1 --Failure. Reason: There is no user table or view with this name
 END
 END
ELSE
 BEGIN
 IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = @Internal_Table_Name COLLATE DATABASE_DEFAULT AND (TABLE_TYPE = 'BASE TABLE' OR TABLE_TYPE = 'VIEW') AND TABLE_SCHEMA = @schema COLLATE DATABASE_DEFAULT)
 BEGIN
 RAISERROR('User table or view not found.',16,1)
 PRINT 'Make sure you have SELECT permission on that table or view.'
 RETURN -1 --Failure. Reason: There is no user table or view with this name 
 END
 END


--Variable declarations
DECLARE @Column_ID int, 
 @Column_List nvarchar(max), 
 @Column_List_Insert_Values nvarchar(max),
 @Column_List_For_Update nvarchar(max), 
 @Column_List_For_Check nvarchar(max), 
 @Column_Name nvarchar(128), 
 @Column_Name_Unquoted nvarchar(128), 
 @Data_Type nvarchar(128), 
 @Actual_Values nvarchar(max), --This is the string that will be finally executed to generate a MERGE statement
 @IDN nvarchar(128), --Will contain the IDENTITY column's name in the table
 @Target_Table_For_Output nvarchar(776),
 @Source_Table_Object_Id int,
 @Source_Table_Qualified nvarchar(776),
 @Source_Table_For_Output nvarchar(776),
 @sql nvarchar(max),  --SQL statement that will be executed to check existence of [Hashvalue] column in case @hash_compare_column is used
 @checkhashcolumn nvarchar(128),
 @SourceHashColumn bit = 0,
 @b char(1) = char(13)

 IF @hash_compare_column IS NOT NULL  --Check existence of column [Hashvalue] in target table and raise error in case of missing
 BEGIN
 IF @target_table IS NULL
 BEGIN
	SET @target_table = @table_name COLLATE DATABASE_DEFAULT
 END		
 SET @SQL =
	'SELECT @columnname = column_name
	FROM ' + COALESCE(PARSENAME(@target_table COLLATE DATABASE_DEFAULT,3),QUOTENAME(DB_NAME())) + '.INFORMATION_SCHEMA.COLUMNS (NOLOCK)
	WHERE TABLE_NAME = ''' + PARSENAME(@target_table COLLATE DATABASE_DEFAULT,1) + '''' +
	' AND TABLE_SCHEMA = ' + '''' + COALESCE(@schema COLLATE DATABASE_DEFAULT, SCHEMA_NAME()) + '''' + ' AND [COLUMN_NAME] = ''' + @hash_compare_column COLLATE DATABASE_DEFAULT + ''''

	EXECUTE sp_executesql @sql, N'@columnname nvarchar(128) OUTPUT', @columnname = @checkhashcolumn OUTPUT
	IF @checkhashcolumn IS NULL
	BEGIN
	  RAISERROR('Column %s not found ',16,1, @hash_compare_column)
	  PRINT 'The specified @hash_compare_column ' + QUOTENAME(@hash_compare_column COLLATE DATABASE_DEFAULT) +  ' does not exist in ' + QUOTENAME(@target_table COLLATE DATABASE_DEFAULT) + '. Please make sure that ' + QUOTENAME(@hash_compare_column COLLATE DATABASE_DEFAULT) + ' VARBINARY (8000) exits in the target table'
	  RETURN -1 --Failure. Reason: There is no column that can be used as the basis of Hashcompare
	END	

 END
 

--Variable Initialization
SET @IDN = ''
SET @Column_ID = 0
SET @Column_Name = ''
SET @Column_Name_Unquoted = ''
SET @Column_List = ''
SET @Column_List_Insert_Values = ''
SET @Column_List_For_Update = ''
SET @Column_List_For_Check = ''
SET @Actual_Values = ''

--Variable Defaults
IF @target_table IS NOT NULL AND (@target_table LIKE '%.%' COLLATE DATABASE_DEFAULT OR @target_table LIKE '\[%\]' COLLATE DATABASE_DEFAULT ESCAPE '\')
BEGIN
 IF NOT @target_table LIKE '\[%\]' COLLATE DATABASE_DEFAULT ESCAPE '\'
 BEGIN
  RAISERROR('Ambiguous value for @target_table specified. Use QUOTENAME() to ensure the identifer is fully qualified (e.g. [dbo].[Titles] or [OtherDb].[dbo].[Titles]).',16,1)
  RETURN -1 --Failure. Reason: The value could be a multi-part object identifier or it could be a single-part object identifier that just happens to include a period character
 END

 -- If the user has specified the @schema param, but the qualified @target_table they've specified does not include the target schema, then fail validation to avoid any ambiguity
 IF @schema IS NOT NULL AND @target_table NOT LIKE '%.%' COLLATE DATABASE_DEFAULT
 BEGIN
  RAISERROR('The specified @target_table is missing a schema name (e.g. [dbo].[Titles]).',16,1)
  RETURN -1 --Failure. Reason: Omitting the schema in this scenario is likely a mistake
 END

  SET @Target_Table_For_Output = @target_table COLLATE DATABASE_DEFAULT
 END
 ELSE
 BEGIN
 IF @schema IS NULL
 BEGIN
  SET @Target_Table_For_Output = QUOTENAME(COALESCE(@target_table COLLATE DATABASE_DEFAULT, @table_name COLLATE DATABASE_DEFAULT))
 END
 ELSE
 BEGIN
  SET @Target_Table_For_Output = QUOTENAME(@schema COLLATE DATABASE_DEFAULT) + '.' + QUOTENAME(COALESCE(@target_table COLLATE DATABASE_DEFAULT, @table_name COLLATE DATABASE_DEFAULT))
 END
END

SET @Source_Table_Qualified = QUOTENAME(COALESCE(@schema COLLATE DATABASE_DEFAULT,SCHEMA_NAME())) + '.' + QUOTENAME(@Internal_Table_Name COLLATE DATABASE_DEFAULT)
SET @Source_Table_For_Output = QUOTENAME(COALESCE(@schema COLLATE DATABASE_DEFAULT,SCHEMA_NAME())) + '.' + QUOTENAME(@table_name COLLATE DATABASE_DEFAULT)
SELECT @Source_Table_Object_Id = OBJECT_ID(@Source_Table_Qualified)

--To get the first column's ID
SELECT @Column_ID = MIN(ORDINAL_POSITION) 
FROM INFORMATION_SCHEMA.COLUMNS (NOLOCK) 
WHERE TABLE_NAME = @Internal_Table_Name
AND TABLE_SCHEMA = COALESCE(@schema COLLATE DATABASE_DEFAULT, SCHEMA_NAME())


--Loop through all the columns of the table, decide whether to include/exclude each one, and put together the value serialisation SQL
WHILE @Column_ID IS NOT NULL
BEGIN
  SELECT @Column_Name = QUOTENAME(COLUMN_NAME), 
         @Column_Name_Unquoted = COLUMN_NAME,
         @Data_Type = DATA_TYPE 
  FROM INFORMATION_SCHEMA.COLUMNS (NOLOCK) 
  WHERE ORDINAL_POSITION = @Column_ID
  AND TABLE_NAME = @Internal_Table_Name COLLATE DATABASE_DEFAULT
  AND TABLE_SCHEMA = COALESCE(@schema COLLATE DATABASE_DEFAULT, SCHEMA_NAME())

  --Timestamp/Rowversion columns can't be inserted/updated due to SQL Server limitations, so exclude them
  IF @Data_Type COLLATE DATABASE_DEFAULT IN ('timestamp','rowversion')
    GOTO SKIP_LOOP

  --Only include the specified columns, if @cols_to_include has been provided
  IF @cols_to_include IS NOT NULL AND CHARINDEX( '''' + SUBSTRING(@Column_Name COLLATE DATABASE_DEFAULT,2,LEN(@Column_Name COLLATE DATABASE_DEFAULT)-2) + '''',@cols_to_include COLLATE DATABASE_DEFAULT) = 0
    GOTO SKIP_LOOP

  --Exclude any specified columns in @cols_to_exclude
  IF @cols_to_exclude IS NOT NULL AND CHARINDEX( '''' + SUBSTRING(@Column_Name COLLATE DATABASE_DEFAULT,2,LEN(@Column_Name COLLATE DATABASE_DEFAULT)-2) + '''',@cols_to_exclude COLLATE DATABASE_DEFAULT) <> 0 
    GOTO SKIP_LOOP

  --Include identity columns, unless the user has decided not to
  IF @ommit_identity = 1 AND COLUMNPROPERTY( @Source_Table_Object_Id,@Column_Name_Unquoted,'IsIdentity') = 1
    GOTO SKIP_LOOP

  --Identity column? Capture the name
  IF COLUMNPROPERTY( @Source_Table_Object_Id,@Column_Name_Unquoted,'IsIdentity') = 1 
    SET @IDN = @Column_Name COLLATE DATABASE_DEFAULT

  --Computed columns can't be inserted/updated, so exclude them unless directed otherwise
  IF @ommit_computed_cols = 1 AND COLUMNPROPERTY( @Source_Table_Object_Id,@Column_Name_Unquoted,'IsComputed') = 1
  BEGIN
    IF @quiet = 0
      PRINT 'Warning: The ' + @Column_Name + ' computed column will be excluded from the MERGE statement. Specify @ommit_computed_cols = 0 to include computed columns.'
    GOTO SKIP_LOOP 
  END

  --GENERATED ALWAYS type columns can't be inserted/updated, so exclude them unless directed otherwise
  IF @ommit_generated_always_cols = 1 AND ISNULL(COLUMNPROPERTY( @Source_Table_Object_Id,@Column_Name_Unquoted,'GeneratedAlwaysType'), 0) <> 0
  BEGIN
    IF @quiet = 0
      PRINT 'Warning: The ' + @Column_Name + ' GENERATED ALWAYS column will be excluded from the MERGE statement. Specify @ommit_generated_always_cols = 0 to include GENERATED ALWAYS columns.'
    GOTO SKIP_LOOP 
  END

  --Hash comparisons only: If the source table contains the @hash_compare_column, ensure that it is only included in the UPDATE clause once
  IF @hash_compare_column IS NOT NULL AND @Column_Name = QUOTENAME(@hash_compare_column COLLATE DATABASE_DEFAULT)
    SET @SourceHashColumn = 1
 
  --Image columns are not currently supported. Throw an error if this is an image column and the user hasn't specified @ommit_images=1 yet
  IF @Data_Type COLLATE DATABASE_DEFAULT = 'image'
  BEGIN
    IF (@ommit_images = 0)
    BEGIN
      RAISERROR('Tables with image columns are not supported.',16,1)
      PRINT 'Use @ommit_images = 1 parameter to generate a MERGE for the rest of the columns.'
      RETURN -1 --Failure. Reason: There is a column with image data type
    END
    ELSE
    BEGIN
      GOTO SKIP_LOOP
    END
  END

  --Serialise the data in the appropriate way for the given column's data type, while preserving column precision and accommodating for NULL values.
  SET @Actual_Values +=
    CASE 
      WHEN @Data_Type COLLATE DATABASE_DEFAULT IN ('char','nchar')                                                          THEN 'COALESCE(''N'''''' + REPLACE(RTRIM(' + @Column_Name + '),'''''''','''''''''''')+'''''''',''NULL'')'
      WHEN @Data_Type COLLATE DATABASE_DEFAULT IN ('varchar','nvarchar')                                                    THEN 'COALESCE(''N'''''' + REPLACE(' + @Column_Name + ','''''''','''''''''''')+'''''''',''NULL'')'
      WHEN @Data_Type COLLATE DATABASE_DEFAULT IN ('datetime','smalldatetime','datetime2','date', 'datetimeoffset', 'time') THEN 'COALESCE(''''''''  + RTRIM(CONVERT(char,' + @Column_Name + ',127))+'''''''',''NULL'')'
      WHEN @Data_Type COLLATE DATABASE_DEFAULT IN ('uniqueidentifier')                                                      THEN 'COALESCE(''N'''''' + REPLACE(CONVERT(char(36),RTRIM(' + @Column_Name + ')),'''''''','''''''''''')+'''''''',''NULL'')'
      WHEN @Data_Type COLLATE DATABASE_DEFAULT IN ('text')                                                                  THEN 'COALESCE(''N'''''' + REPLACE(CONVERT(varchar(max),' + @Column_Name + '),'''''''','''''''''''')+'''''''',''NULL'')'
      WHEN @Data_Type COLLATE DATABASE_DEFAULT IN ('ntext')                                                                 THEN 'COALESCE(''''''''  + REPLACE(CONVERT(nvarchar(max),' + @Column_Name + '),'''''''','''''''''''')+'''''''',''NULL'')'
      WHEN @Data_Type COLLATE DATABASE_DEFAULT IN ('xml')                                                                   THEN 'COALESCE(''''''''  + REPLACE(CONVERT(nvarchar(max),' + @Column_Name + '),'''''''','''''''''''')+'''''''',''NULL'')'
      WHEN @Data_Type COLLATE DATABASE_DEFAULT IN ('binary','varbinary')                                                    THEN 'COALESCE(RTRIM(CONVERT(varchar(max),' + @Column_Name + ', 1)),''NULL'')'
      WHEN @Data_Type COLLATE DATABASE_DEFAULT IN ('float','real','money','smallmoney')                                     THEN 'COALESCE(LTRIM(RTRIM(' + 'CONVERT(char, ' + @Column_Name + ',2)' + ')),''NULL'')'
      WHEN @Data_Type COLLATE DATABASE_DEFAULT IN ('hierarchyid')                                                           THEN 'COALESCE(''hierarchyid::Parse(''+'''''''' + LTRIM(RTRIM(' + 'CONVERT(char, ' + @Column_Name + ')' + '))+''''''''+'')'',''NULL'')'
      WHEN @Data_Type COLLATE DATABASE_DEFAULT IN ('geography')                                                             THEN 'COALESCE(''geography::STGeomFromText(''+'''''''' + LTRIM(RTRIM(' + 'CONVERT(nvarchar(max),' + @Column_Name + ')' + '))+''''''''+'', 4326)'',''NULL'')'
      WHEN @Data_Type COLLATE DATABASE_DEFAULT IN ('geometry')                                                              THEN 'COALESCE(''geometry::Parse(''+'''''''' + LTRIM(RTRIM(' + 'CONVERT(nvarchar(max),' + @Column_Name + ')' + '))+''''''''+'')'',''NULL'')'
      ELSE                                                                                              'COALESCE(LTRIM(RTRIM(' + 'CONVERT(char, ' + @Column_Name + ')' + ')),''NULL'')' 
    END + '+' + ''',''' + ' + '
  
  --Add the column to the list to be serialised, unless it is the @hash_compare_column
  IF @hash_compare_column IS NULL OR @Column_Name <> QUOTENAME(@hash_compare_column COLLATE DATABASE_DEFAULT)
  BEGIN
    SET @Column_List += @Column_Name + ','
    DECLARE @Insert_Column_Spec NVARCHAR(128) = CASE WHEN @Data_Type COLLATE DATABASE_DEFAULT = 'xml' THEN N'CONVERT(xml, ' + @Column_Name + ')' ELSE @Column_Name END
    SET @Column_List_Insert_Values += @Insert_Column_Spec + ','
  END

  --Add the column to the list of columns to be updated, unless it is a primary key or identity column
  IF NOT EXISTS
  (
    SELECT 1
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS pk,
         INFORMATION_SCHEMA.KEY_COLUMN_USAGE c
    WHERE pk.TABLE_NAME = @Internal_Table_Name COLLATE DATABASE_DEFAULT
    AND pk.TABLE_SCHEMA = COALESCE(@schema COLLATE DATABASE_DEFAULT, SCHEMA_NAME())
    AND CONSTRAINT_TYPE = 'PRIMARY KEY'
    AND c.TABLE_NAME = pk.TABLE_NAME
    AND c.TABLE_SCHEMA = pk.TABLE_SCHEMA
    AND c.CONSTRAINT_NAME = pk.CONSTRAINT_NAME
    AND c.COLUMN_NAME = @Column_Name_Unquoted COLLATE DATABASE_DEFAULT
  UNION
    SELECT 1
    FROM sys.identity_columns
    WHERE OBJECT_SCHEMA_NAME(object_id) = COALESCE(@schema COLLATE DATABASE_DEFAULT, SCHEMA_NAME())
    AND OBJECT_NAME(object_id) = @Internal_Table_Name COLLATE DATABASE_DEFAULT
    AND name = @Column_Name_Unquoted COLLATE DATABASE_DEFAULT
  )
  BEGIN
    DECLARE @Source_Column_Spec NVARCHAR(128) = CASE @Data_Type COLLATE DATABASE_DEFAULT WHEN 'xml' THEN N'CONVERT(xml, [Source].' + @Column_Name + ')' ELSE '[Source].' + @Column_Name END
    SET @Column_List_For_Update += '[Target].' + @Column_Name + ' = ' + @Source_Column_Spec + ', ' + @b COLLATE DATABASE_DEFAULT + '  '
    SET @Column_List_For_Check += @b COLLATE DATABASE_DEFAULT + CHAR(9) + 
      CASE @Data_Type COLLATE DATABASE_DEFAULT
        WHEN 'text'      THEN 'NULLIF(CAST([Source].' + @Column_Name + ' AS VARCHAR(MAX)), CAST([Target].' + @Column_Name + ' AS VARCHAR(MAX))) IS NOT NULL OR NULLIF(CAST([Target].' + @Column_Name + ' AS VARCHAR(MAX)), CAST([Source].' + @Column_Name + ' AS VARCHAR(MAX))) IS NOT NULL'
        WHEN 'ntext'     THEN 'NULLIF(CAST([Source].' + @Column_Name + ' AS NVARCHAR(MAX)), CAST([Target].' + @Column_Name + ' AS NVARCHAR(MAX))) IS NOT NULL OR NULLIF(CAST([Target].' + @Column_Name + ' AS NVARCHAR(MAX)), CAST([Source].' + @Column_Name + ' AS NVARCHAR(MAX))) IS NOT NULL' 
        WHEN 'xml'       THEN 'NULLIF(CAST([Source].' + @Column_Name + ' AS NVARCHAR(MAX)), CAST([Target].' + @Column_Name + ' AS NVARCHAR(MAX))) IS NOT NULL OR NULLIF(CAST([Target].' + @Column_Name + ' AS NVARCHAR(MAX)), CAST([Source].' + @Column_Name + ' AS NVARCHAR(MAX))) IS NOT NULL' 
        WHEN 'geography' THEN '((NOT ([Source].' + @Column_Name + ' IS NULL AND [Target].' + @Column_Name + ' IS NULL)) AND ISNULL(ISNULL([Source].' + @Column_Name + ', geography::[Null]).STEquals([Target].' + @Column_Name + '), 0) = 0)'
        WHEN 'geometry'  THEN '((NOT ([Source].' + @Column_Name + ' IS NULL AND [Target].' + @Column_Name + ' IS NULL)) AND ISNULL(ISNULL([Source].' + @Column_Name + ', geometry::[Null]).STEquals([Target].' + @Column_Name + '), 0) = 0)'
        ELSE                  'NULLIF([Source].' + @Column_Name + ', [Target].' + @Column_Name + ') IS NOT NULL OR NULLIF([Target].' + @Column_Name + ', [Source].' + @Column_Name + ') IS NOT NULL'
      END + ' OR '
  END

  SKIP_LOOP: --The label used in GOTO

  SET @Column_ID = (SELECT MIN(ORDINAL_POSITION) 
                    FROM INFORMATION_SCHEMA.COLUMNS (NOLOCK) 
                    WHERE TABLE_NAME = @Internal_Table_Name COLLATE DATABASE_DEFAULT
                    AND TABLE_SCHEMA = COALESCE(@schema COLLATE DATABASE_DEFAULT, SCHEMA_NAME())
                    AND ORDINAL_POSITION > @Column_ID)

END --WHILE LOOP END


--Get rid of the extra characters that got concatenated during the last run through the loop
IF LEN(@Column_List_For_Update) <> 0
 BEGIN
 SET @Column_List_For_Update = ' ' + LEFT(@Column_List_For_Update,len(@Column_List_For_Update) - 2 - LEN(@b))
 END

IF LEN(@Column_List_For_Check) <> 0
 BEGIN
 SET @Column_List_For_Check = LEFT(@Column_List_For_Check,len(@Column_List_For_Check) - 2 - LEN(@b))
 END

SET @Actual_Values = LEFT(@Actual_Values,len(@Actual_Values) - 6)

SET @Column_List = LEFT(@Column_List,len(@Column_List) - 1)
IF LEN(LTRIM(@Column_List)) = 0
 BEGIN
 RAISERROR('No columns to select. There should at least be one column to generate the output',16,1)
 RETURN -1 --Failure. Reason: Looks like all the columns are ommitted using the @cols_to_exclude parameter
 END

SET @Column_List_Insert_Values = LEFT(@Column_List_Insert_Values,len(@Column_List_Insert_Values) - 1)

--Get the join columns ----------------------------------------------------------
DECLARE @PK_column_list NVARCHAR(max)
DECLARE @PK_column_joins NVARCHAR(max)
SET @PK_column_list = ''
SET @PK_column_joins = ''

IF ISNULL(@cols_to_join_on COLLATE DATABASE_DEFAULT, '') = '' -- Use primary key of the source table as the basis of MERGE joins, if no join list is specified
BEGIN
	SELECT @PK_column_list = @PK_column_list + '[' + c.COLUMN_NAME + '], '
	, @PK_column_joins = @PK_column_joins + '[Target].[' + c.COLUMN_NAME + '] = [Source].[' + c.COLUMN_NAME + '] AND '
	FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS pk ,
	INFORMATION_SCHEMA.KEY_COLUMN_USAGE c
	WHERE pk.TABLE_NAME = @Internal_Table_Name COLLATE DATABASE_DEFAULT
	AND pk.TABLE_SCHEMA = COALESCE(@schema COLLATE DATABASE_DEFAULT, SCHEMA_NAME())
	AND CONSTRAINT_TYPE = 'PRIMARY KEY'
	AND c.TABLE_NAME = pk.TABLE_NAME
	AND c.TABLE_SCHEMA = pk.TABLE_SCHEMA
	AND c.CONSTRAINT_NAME = pk.CONSTRAINT_NAME
	ORDER BY c.ORDINAL_POSITION
END
ELSE
BEGIN
	SELECT @PK_column_list = @PK_column_list + '[' + c.COLUMN_NAME + '], '
	, @PK_column_joins = @PK_column_joins + '([Target].[' + c.COLUMN_NAME + '] = [Source].[' + c.COLUMN_NAME + ']' + CASE WHEN c.IS_NULLABLE='YES' THEN ' OR ([Target].[' + c.COLUMN_NAME + '] IS NULL AND [Source].[' + c.COLUMN_NAME + '] IS NULL)' ELSE '' END + ') AND '
	FROM INFORMATION_SCHEMA.COLUMNS AS c
	WHERE @cols_to_join_on LIKE '%''' + c.COLUMN_NAME + '''%' COLLATE DATABASE_DEFAULT
	AND c.TABLE_NAME = @Internal_Table_Name COLLATE DATABASE_DEFAULT
	AND c.TABLE_SCHEMA = COALESCE(@schema COLLATE DATABASE_DEFAULT, SCHEMA_NAME())
END

IF ISNULL(@PK_column_list COLLATE DATABASE_DEFAULT, '') = '' 
BEGIN
	RAISERROR('Table does not have a primary key from which to generate the join clause(s) and/or a valid @cols_to_join_on has not been specified. Either add a primary key/composite key to the table or specify the @cols_to_join_on parameter.',16,1)
	RETURN -1 --Failure. Reason: looks like table doesn't have any primary keys
END

SET @PK_column_list = LEFT(@PK_column_list, LEN(@PK_column_list) -1)
SET @PK_column_joins = LEFT(@PK_column_joins, LEN(@PK_column_joins) -4)


--Forming the final string that will be executed, to output the a MERGE statement
SET @Actual_Values = 
 'SELECT ' + 
 CASE WHEN @top IS NULL OR @top < 0 THEN '' ELSE ' TOP ' + LTRIM(STR(@top)) + ' ' END + 
 '''''+''(''+' + @Actual_Values COLLATE DATABASE_DEFAULT + '+'')''' + 
 COALESCE(@from,' FROM ' + @Source_Table_Qualified COLLATE DATABASE_DEFAULT + ' (NOLOCK) ORDER BY ' + @PK_column_list COLLATE DATABASE_DEFAULT)

 SET @output = CASE WHEN ISNULL(@results_to_text, 1) = 1 THEN '' ELSE '---' END


--Determining whether to ouput any debug information
IF @debug_mode = 1 AND @quiet = 0
 BEGIN
 SET @output += @b COLLATE DATABASE_DEFAULT + '/*****START OF DEBUG INFORMATION*****'
 SET @output += @b COLLATE DATABASE_DEFAULT + ''
 SET @output += @b COLLATE DATABASE_DEFAULT + 'The primary key column list:'
 SET @output += @b COLLATE DATABASE_DEFAULT + @PK_column_list
 SET @output += @b COLLATE DATABASE_DEFAULT + ''
 SET @output += @b COLLATE DATABASE_DEFAULT + 'The INSERT column list:'
 SET @output += @b COLLATE DATABASE_DEFAULT + @Column_List
 SET @output += @b COLLATE DATABASE_DEFAULT + ''
 SET @output += @b COLLATE DATABASE_DEFAULT + 'The UPDATE column list:'
 SET @output += @b COLLATE DATABASE_DEFAULT + @Column_List_For_Update
 SET @output += @b COLLATE DATABASE_DEFAULT + ''
 SET @output += @b COLLATE DATABASE_DEFAULT + 'The SELECT statement executed to generate the MERGE:'
 SET @output += @b COLLATE DATABASE_DEFAULT + @Actual_Values
 SET @output += @b COLLATE DATABASE_DEFAULT + ''
 SET @output += @b COLLATE DATABASE_DEFAULT + '*****END OF DEBUG INFORMATION*****/'
 SET @output += @b COLLATE DATABASE_DEFAULT + ''
 END
 
IF @include_use_db = 1
 BEGIN
	SET @output += @b 
	SET @output += @b COLLATE DATABASE_DEFAULT + 'USE ' + QUOTENAME(DB_NAME())
	SET @output += @b COLLATE DATABASE_DEFAULT + ISNULL(@batch_separator, '')
	SET @output += @b 
 END

IF @nologo = 0 AND @quiet = 0
 BEGIN
 SET @output += @b COLLATE DATABASE_DEFAULT + '--MERGE generated by sp_generate_merge proc tool maintained by Daniel Nolan (https://danielnolan.io)'
 SET @output += @b COLLATE DATABASE_DEFAULT + '--Originally forked from Vyas'' sp_generate_inserts (http://vyaskn.tripod.com/code)'
 SET @output += @b COLLATE DATABASE_DEFAULT + ''
 END

IF @include_rowsaffected = 1 -- If the caller has elected not to include the "rows affected" section, let MERGE output the row count as it is executed.
 SET @output += @b COLLATE DATABASE_DEFAULT + 'SET NOCOUNT ON'
 SET @output += @b COLLATE DATABASE_DEFAULT + ''


--Determining whether to print IDENTITY_INSERT or not
IF LEN(@IDN) <> 0
 BEGIN
 SET @output += @b COLLATE DATABASE_DEFAULT + 'SET IDENTITY_INSERT ' + @Target_Table_For_Output + ' ON'
 SET @output += @b COLLATE DATABASE_DEFAULT + ''
 END


--Temporarily disable constraints on the target table
DECLARE @output_enable_constraints NVARCHAR(MAX) = ''
DECLARE @ignore_disable_constraints BIT = IIF((OBJECT_ID(@Source_Table_Qualified COLLATE DATABASE_DEFAULT, 'U') IS NULL), 1, 0)
IF @disable_constraints = 1 AND @ignore_disable_constraints = 1
BEGIN
	IF @quiet = 0
		PRINT 'Warning: @disable_constraints=1 will be ignored as the source table does not exist'
END
ELSE IF @disable_constraints = 1
BEGIN
	DECLARE @Source_Table_Constraints TABLE ([name] SYSNAME PRIMARY KEY, [is_not_trusted] bit, [is_disabled] bit)
	INSERT INTO @Source_Table_Constraints ([name], [is_not_trusted], [is_disabled])
	SELECT [name], [is_not_trusted], [is_disabled] FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(@Source_Table_Qualified COLLATE DATABASE_DEFAULT, 'U')
	UNION
	SELECT [name], [is_not_trusted], [is_disabled] FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(@Source_Table_Qualified COLLATE DATABASE_DEFAULT, 'U')

	DECLARE @Constraint_Ct INT = (SELECT COUNT(1) FROM @Source_Table_Constraints)
	IF @Constraint_Ct = 0
	BEGIN
		IF @quiet = 0
			PRINT 'Warning: @disable_constraints=1 will be ignored as there are no foreign key or check constraints on the source table'
		SET @ignore_disable_constraints = 1
	END
	ELSE IF ((SELECT COUNT(1) FROM @Source_Table_Constraints WHERE [is_disabled] = 1) = (SELECT COUNT(1) FROM @Source_Table_Constraints))
	BEGIN
		IF @quiet = 0
			PRINT 'Warning: @disable_constraints=1 will be ignored as all foreign key and/or check constraints on the source table are currently disabled'
		SET @ignore_disable_constraints = 1
	END
	ELSE
	BEGIN
		DECLARE @All_Constraints_Enabled BIT = IIF((SELECT COUNT(1) FROM @Source_Table_Constraints WHERE [is_disabled] = 0) = @Constraint_Ct, 1, 0)
		DECLARE @All_Constraints_Trusted BIT = IIF((SELECT COUNT(1) FROM @Source_Table_Constraints WHERE [is_not_trusted] = 0) = @Constraint_Ct, 1, 0)
		DECLARE @All_Constraints_NotTrusted BIT = IIF((SELECT COUNT(1) FROM @Source_Table_Constraints WHERE [is_not_trusted] = 1) = @Constraint_Ct, 1, 0)

		IF @All_Constraints_Enabled = 1 AND @All_Constraints_Trusted = 1
		BEGIN
			SET @output += @b COLLATE DATABASE_DEFAULT + 'ALTER TABLE ' + @Target_Table_For_Output + ' NOCHECK CONSTRAINT ALL' -- Disable constraints temporarily
			SET @output_enable_constraints += @b COLLATE DATABASE_DEFAULT + 'ALTER TABLE ' + @Target_Table_For_Output + ' WITH CHECK CHECK CONSTRAINT ALL' -- Enable the previously disabled constraints and re-check all data
		END
		ELSE IF @All_Constraints_Enabled = 1 AND @All_Constraints_NotTrusted = 1
		BEGIN
			SET @output += @b COLLATE DATABASE_DEFAULT + 'ALTER TABLE ' + @Target_Table_For_Output + ' NOCHECK CONSTRAINT ALL' -- Disable constraints temporarily
			SET @output_enable_constraints += @b COLLATE DATABASE_DEFAULT + 'ALTER TABLE ' + @Target_Table_For_Output + ' CHECK CONSTRAINT ALL' -- Enable the previously disabled constraints, but don't re-check data 
		END
		ELSE
		BEGIN
			-- Selectively enable/disable constraints, with/without WITH CHECK, on a case-by-case basis
			WHILE ((SELECT COUNT(1) FROM @Source_Table_Constraints) != 0)
			BEGIN
				DECLARE @Constraint_Item_Name SYSNAME = (SELECT TOP 1 [name] FROM @Source_Table_Constraints)
				DECLARE @Constraint_Item_IsDisabled BIT = (SELECT TOP 1 [is_disabled] FROM @Source_Table_Constraints)
				DECLARE @Constraint_Item_IsNotTrusted BIT = (SELECT TOP 1 [is_not_trusted] FROM @Source_Table_Constraints)

				IF (@Constraint_Item_IsDisabled = 1)
				BEGIN
					DELETE FROM @Source_Table_Constraints WHERE [name] = @Constraint_Item_Name COLLATE DATABASE_DEFAULT -- Don't enable this previously-disabled constraint
					CONTINUE;
				END

				SET @output += @b COLLATE DATABASE_DEFAULT + 'ALTER TABLE ' + @Target_Table_For_Output COLLATE DATABASE_DEFAULT + ' NOCHECK CONSTRAINT ' + QUOTENAME(@Constraint_Item_Name COLLATE DATABASE_DEFAULT)
				IF (@Constraint_Item_IsNotTrusted = 1)
				BEGIN
					SET @output_enable_constraints += @b COLLATE DATABASE_DEFAULT + 'ALTER TABLE ' + @Target_Table_For_Output COLLATE DATABASE_DEFAULT + ' CHECK CONSTRAINT ' + QUOTENAME(@Constraint_Item_Name COLLATE DATABASE_DEFAULT) -- Enable the previously disabled constraint, but don't re-check data 
				END
				ELSE
				BEGIN
					SET @output_enable_constraints += @b COLLATE DATABASE_DEFAULT + 'ALTER TABLE ' + @Target_Table_For_Output COLLATE DATABASE_DEFAULT + ' WITH CHECK CHECK CONSTRAINT ' + QUOTENAME(@Constraint_Item_Name COLLATE DATABASE_DEFAULT) -- Enable the previously disabled constraint and re-check all data
				END

				DELETE FROM @Source_Table_Constraints WHERE [name] = @Constraint_Item_Name COLLATE DATABASE_DEFAULT
			END
		END
	END
END

DECLARE @Output_Var_Suffix AS NVARCHAR(128) = CASE WHEN @batch_separator IS NULL THEN REPLACE(CAST(@Source_Table_Object_Id AS NVARCHAR(128)), '-', '') ELSE '' END
DECLARE @Merge_Output_Var_Name AS NVARCHAR(128) = N'@mergeOutput' + @Output_Var_Suffix COLLATE DATABASE_DEFAULT
IF @include_rowsaffected = 1 AND @quiet = 0
BEGIN
 SET @output += @b COLLATE DATABASE_DEFAULT + 'DECLARE ' + @Merge_Output_Var_Name COLLATE DATABASE_DEFAULT + ' TABLE ( [DMLAction] VARCHAR(6) );'
END

DECLARE @outputMergeBatch nvarchar(max), @ValuesListTotalCount int;

--Output the start of the MERGE statement, qualifying with the schema name only if the caller explicitly specified it
SET @outputMergeBatch = @b COLLATE DATABASE_DEFAULT + 'MERGE INTO ' + @Target_Table_For_Output COLLATE DATABASE_DEFAULT + ' AS [Target]'
DECLARE @tab TABLE (ID INT NOT NULL PRIMARY KEY IDENTITY(1,1), val NVARCHAR(max));

IF @include_values = 1
BEGIN
 SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + 'USING ('
 --All the hard work pays off here!!! You'll get your MERGE statement, when the next line executes!
 INSERT INTO @tab (val)
 EXEC (@Actual_Values)

 SET @ValuesListTotalCount = @@ROWCOUNT;

 IF @ValuesListTotalCount <> 0 -- Ensure that rows were returned, otherwise the MERGE statement will get nullified.
 BEGIN
  SET @outputMergeBatch += 'VALUES{{ValuesList}}';
 END
 ELSE
 BEGIN
  -- Mimic an empty result set by returning zero rows from the target table
  SET @outputMergeBatch += 'SELECT ' + @Column_List COLLATE DATABASE_DEFAULT + ' FROM ' + @Target_Table_For_Output COLLATE DATABASE_DEFAULT + ' WHERE 1 = 0 -- Empty dataset (source table contained no rows at time of MERGE generation) '
 END

 --output the columns to correspond with each of the values above--------------------
 SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + ') AS [Source] (' + @Column_List COLLATE DATABASE_DEFAULT + ')'
END
ELSE
 IF @hash_compare_column IS NULL
 BEGIN
  SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + 'USING ' + @Source_Table_For_Output COLLATE DATABASE_DEFAULT + ' AS [Source]';
 END
 ELSE
 BEGIN
  SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + 'USING (SELECT ' + @Column_List COLLATE DATABASE_DEFAULT + ', HASHBYTES(''SHA2_256'', CONCAT(' + REPLACE(@Column_List COLLATE DATABASE_DEFAULT,'],[','],''|'',[') +')) AS [' + @hash_compare_column COLLATE DATABASE_DEFAULT  + '] FROM ' + @Source_Table_For_Output COLLATE DATABASE_DEFAULT + ') AS [Source]'
 END

--Output the join columns ----------------------------------------------------------
SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + 'ON (' + @PK_column_joins COLLATE DATABASE_DEFAULT + ')'


--When matched, perform an UPDATE on any metadata columns only (ie. not on PK)------
IF LEN(@Column_List_For_Update) <> 0 AND @update_existing = 1
BEGIN
 --Adding column @hash_compare_column to @ColumnList and @Column_List_For_Update if @hash_compare_column is not null
 IF @update_only_if_changed = 1 AND @hash_compare_column IS NOT NULL AND @SourceHashColumn = 0
 BEGIN
  SET @Column_List_Insert_Values += ',' + QUOTENAME(@hash_compare_column COLLATE DATABASE_DEFAULT)
	SET @Column_List_For_Update += ',' + @b COLLATE DATABASE_DEFAULT + '  [Target].' + QUOTENAME(@hash_compare_column COLLATE DATABASE_DEFAULT) +' = [Source].' + QUOTENAME(@hash_compare_column COLLATE DATABASE_DEFAULT)
	SET @Column_List += ',' + QUOTENAME(@hash_compare_column COLLATE DATABASE_DEFAULT)
 END
 SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + 'WHEN MATCHED ' +
	 CASE WHEN @update_only_if_changed = 1 AND @hash_compare_column IS NOT NULL
	 THEN 'AND ([Target].' + QUOTENAME(@hash_compare_column) +' <> [Source].' + QUOTENAME(@hash_compare_column) + ' OR [Target].' + QUOTENAME(@hash_compare_column) + ' IS NULL) '
	 ELSE CASE WHEN @update_only_if_changed = 1 AND @hash_compare_column IS NULL THEN
	 'AND (' + @Column_List_For_Check + ') ' ELSE '' END END + 'THEN'
 SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + ' UPDATE SET'
 SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + '  ' + LTRIM(@Column_List_For_Update COLLATE DATABASE_DEFAULT)
END


--When NOT matched by target, perform an INSERT------------------------------------
SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + 'WHEN NOT MATCHED BY TARGET THEN';
SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + ' INSERT(' + @Column_List COLLATE DATABASE_DEFAULT + ')'
SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + ' VALUES(' + REPLACE(@Column_List_Insert_Values COLLATE DATABASE_DEFAULT, '[', '[Source].[') + ')'


--When NOT matched by source, DELETE the row as required
IF @delete_if_not_matched=1 
BEGIN
 SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + 'WHEN NOT MATCHED BY SOURCE THEN '
 SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + ' DELETE'
END
IF @include_rowsaffected = 1 AND @quiet = 0
BEGIN
 SET @outputMergeBatch += @b COLLATE DATABASE_DEFAULT + 'OUTPUT $action INTO ' + @Merge_Output_Var_Name
END
SET @outputMergeBatch += ';' + @b COLLATE DATABASE_DEFAULT


IF @include_values = 1 AND @ValuesListTotalCount <> 0 -- Ensure that rows were returned, otherwise the MERGE statement will get nullified.
BEGIN
	DECLARE @CurrentValuesList nvarchar(max), @ValuesListIDFrom int, @ValuesListIDTo int;
	IF @max_rows_per_batch IS NULL SET @max_rows_per_batch = @ValuesListTotalCount;

	SET @ValuesListIDFrom = 1;

	WHILE @ValuesListIDFrom <= @ValuesListTotalCount
	BEGIN
		SET @ValuesListIDTo = @ValuesListIDFrom + @max_rows_per_batch - 1
		SET @CurrentValuesList = ''

		SET @CurrentValuesList += CAST((SELECT @b COLLATE DATABASE_DEFAULT + CASE WHEN ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) = 1 THEN '  ' ELSE ' ,' END + val
						FROM @tab
						WHERE ID BETWEEN @ValuesListIDFrom AND @ValuesListIDTo
						ORDER BY ID FOR XML PATH('')) AS XML).value('.', 'NVARCHAR(MAX)');
		
		SET @output += REPLACE(@outputMergeBatch COLLATE DATABASE_DEFAULT, '{{ValuesList}}', @CurrentValuesList);

		SET @ValuesListIDFrom = @ValuesListIDTo + 1;
	END
END
ELSE
BEGIN
	SET @output += @outputMergeBatch;
END


--Display the number of affected rows to the user, or report if an error occurred---
IF @include_rowsaffected = 1 AND @quiet = 0
BEGIN
 DECLARE @Merge_Error_Var_Name AS NVARCHAR(128) = N'@mergeError' + @Output_Var_Suffix COLLATE DATABASE_DEFAULT
 DECLARE @Merge_Count_Var_Name AS NVARCHAR(128) = N'@mergeCount' + @Output_Var_Suffix COLLATE DATABASE_DEFAULT
 DECLARE @Merge_CountIns_Var_Name AS NVARCHAR(128) = N'@mergeCountIns' + @Output_Var_Suffix COLLATE DATABASE_DEFAULT
 DECLARE @Merge_CountUpd_Var_Name AS NVARCHAR(128) = N'@mergeCountUpd' + @Output_Var_Suffix COLLATE DATABASE_DEFAULT
 DECLARE @Merge_CountDel_Var_Name AS NVARCHAR(128) = N'@mergeCountDel' + @Output_Var_Suffix COLLATE DATABASE_DEFAULT


 SET @output += @b COLLATE DATABASE_DEFAULT + 'DECLARE ' + @Merge_Error_Var_Name COLLATE DATABASE_DEFAULT + ' int,'
 SET @output += @b COLLATE DATABASE_DEFAULT + @Merge_Count_Var_Name COLLATE DATABASE_DEFAULT + ' int,'
 SET @output += @b COLLATE DATABASE_DEFAULT + @Merge_CountIns_Var_Name COLLATE DATABASE_DEFAULT + ' int,'
 SET @output += @b COLLATE DATABASE_DEFAULT + @Merge_CountUpd_Var_Name COLLATE DATABASE_DEFAULT + ' int,'
 SET @output += @b COLLATE DATABASE_DEFAULT + @Merge_CountDel_Var_Name COLLATE DATABASE_DEFAULT + ' int'
 SET @output += @b COLLATE DATABASE_DEFAULT + 'SELECT ' + @Merge_Error_Var_Name COLLATE DATABASE_DEFAULT + ' = @@ERROR'
 SET @output += @b COLLATE DATABASE_DEFAULT + 'SELECT ' + @Merge_Count_Var_Name COLLATE DATABASE_DEFAULT + ' = COUNT(1), ' + @Merge_CountIns_Var_Name COLLATE DATABASE_DEFAULT + ' = SUM(IIF([DMLAction] = ''INSERT'', 1, 0)), ' + @Merge_CountUpd_Var_Name COLLATE DATABASE_DEFAULT + ' = SUM(IIF([DMLAction] = ''UPDATE'', 1, 0)), ' + @Merge_CountDel_Var_Name COLLATE DATABASE_DEFAULT + ' = SUM (IIF([DMLAction] = ''DELETE'', 1, 0)) FROM ' + @Merge_Output_Var_Name COLLATE DATABASE_DEFAULT
 SET @output += @b COLLATE DATABASE_DEFAULT + 'IF ' + @Merge_Error_Var_Name COLLATE DATABASE_DEFAULT + ' != 0'
 SET @output += @b COLLATE DATABASE_DEFAULT + ' BEGIN' 
 SET @output += @b COLLATE DATABASE_DEFAULT + ' PRINT ''ERROR OCCURRED IN MERGE FOR ' + @Target_Table_For_Output COLLATE DATABASE_DEFAULT + '. Rows affected: '' + CAST('+ @Merge_Count_Var_Name COLLATE DATABASE_DEFAULT + ' AS VARCHAR(100)); -- SQL should always return zero rows affected';
 SET @output += @b COLLATE DATABASE_DEFAULT + ' END'
 SET @output += @b COLLATE DATABASE_DEFAULT + 'ELSE'
 SET @output += @b COLLATE DATABASE_DEFAULT + ' BEGIN'
 SET @output += @b COLLATE DATABASE_DEFAULT + ' PRINT ''' + @Target_Table_For_Output COLLATE DATABASE_DEFAULT + ' rows affected by MERGE: '' + CAST(COALESCE(' + @Merge_Count_Var_Name COLLATE DATABASE_DEFAULT + ',0) AS VARCHAR(100)) + '' (Inserted: '' + CAST(COALESCE(' + @Merge_CountIns_Var_Name COLLATE DATABASE_DEFAULT + ',0) AS VARCHAR(100)) + ''; Updated: '' + CAST(COALESCE(' + @Merge_CountUpd_Var_Name COLLATE DATABASE_DEFAULT + ',0) AS VARCHAR(100)) + ''; Deleted: '' + CAST(COALESCE(' + @Merge_CountDel_Var_Name COLLATE DATABASE_DEFAULT + ',0) AS VARCHAR(100)) + '')'' ;'
 SET @output += @b COLLATE DATABASE_DEFAULT + ' END'
 SET @output += @b COLLATE DATABASE_DEFAULT + ISNULL(@batch_separator COLLATE DATABASE_DEFAULT, '')
 SET @output += @b COLLATE DATABASE_DEFAULT + @b
END

--Re-enable the temporarily disabled constraints-------------------------------------
IF @disable_constraints = 1 AND @ignore_disable_constraints = 0
BEGIN
	SET @output += @output_enable_constraints
	SET @output += @b COLLATE DATABASE_DEFAULT + ISNULL(@batch_separator COLLATE DATABASE_DEFAULT, '')
	SET @output += @b
END


--Switch-off identity inserting------------------------------------------------------
IF (LEN(@IDN) <> 0)
 BEGIN
 SET @output += @b
 SET @output += @b COLLATE DATABASE_DEFAULT +'SET IDENTITY_INSERT ' + @Target_Table_For_Output COLLATE DATABASE_DEFAULT + ' OFF'
 	
 END

IF (@include_rowsaffected = 1)
BEGIN
 SET @output += @b
 SET @output +=      'SET NOCOUNT OFF'
 SET @output += @b COLLATE DATABASE_DEFAULT + ISNULL(@batch_separator COLLATE DATABASE_DEFAULT, '')
 SET @output += @b
END

SET @output += @b COLLATE DATABASE_DEFAULT + ''
SET @output += @b COLLATE DATABASE_DEFAULT + ''

IF @results_to_text = 1
BEGIN
	--output the statement to the Grid/Messages tab
	SELECT @output;
END
ELSE IF @results_to_text = 0
BEGIN
	--output the statement as xml (to overcome SSMS 4000/8000 char limitation)
	SELECT [processing-instruction(x)]=@output FOR XML PATH(''),TYPE;
	IF @quiet = 0
	BEGIN
		PRINT 'MERGE statement has been wrapped in an XML fragment and output successfully.'
		PRINT 'Ensure you have Results to Grid enabled and then click the hyperlink to copy the statement within the fragment.'
		PRINT ''
		PRINT 'If you would prefer to have results output directly (without XML) specify @results_to_text = 1, however please'
		PRINT 'note that the results may be truncated by your SQL client to 4000 nchars.'
	END
END
ELSE IF @quiet = 0
BEGIN
	PRINT 'MERGE statement generated successfully (refer to @output OUTPUT parameter for generated T-SQL).'
END

SET NOCOUNT OFF
RETURN 0
END
GO

IF 'sp_generate_merge' NOT LIKE '#%'
BEGIN
  IF OBJECT_ID('sp_MS_marksystemobject', 'P') IS NOT NULL AND DB_NAME() = 'master'
  BEGIN
    PRINT 'Adding system object flag to allow procedure to be used within all databases'
    EXEC sp_MS_marksystemobject 'sp_generate_merge'
  END
  PRINT 'Granting EXECUTE permission on stored procedure to all users'
  GRANT EXEC ON [sp_generate_merge] TO [public]
END
PRINT 'Done'
SET NOCOUNT OFF
SET NOEXEC OFF
GO