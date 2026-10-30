/*
Stored procedure: silver.load_silver
Purpose: Truncates the six silver tables and reloads them from the bronze tables,
         applying the cleaning and transformation rules.
Usage:   EXEC silver.load_silver;

Before running:
- Create the silver tables first (ddl_silver.sql).
- Load the bronze tables first (EXEC bronze.load_bronze;).
- Requires SQL Server 2017 or later (TRIM).
*/

CREATE OR ALTER PROCEDURE silver.load_silver AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start_time       DATETIME,
            @end_time         DATETIME,
            @batch_start_time DATETIME,
            @batch_end_time   DATETIME,
            @row_count        INT;

    BEGIN TRY
        SET @batch_start_time = GETDATE();

        PRINT '================================================';
        PRINT 'Loading silver layer';
        PRINT '================================================';

        ------------------------------------------------------
        PRINT '------------------------------------------------';
        PRINT 'Loading CRM tables';
        PRINT '------------------------------------------------';

        -- 1. CRM: customer info
        SET @start_time = GETDATE();
        PRINT '>> Truncating table: silver.crm_cust_info';
        TRUNCATE TABLE silver.crm_cust_info;
        PRINT '>> Inserting data into: silver.crm_cust_info';
        INSERT INTO silver.crm_cust_info (
            cst_id,
            cst_key,
            cst_firstname,
            cst_lastname,
            cst_marital_status,
            cst_gndr,
            cst_create_date
        )
        SELECT
            cst_id,
            cst_key,
            TRIM(cst_firstname) AS cst_firstname,
            TRIM(cst_lastname)  AS cst_lastname,
            CASE WHEN UPPER(TRIM(cst_marital_status)) = 'S' THEN 'Single'
                 WHEN UPPER(TRIM(cst_marital_status)) = 'M' THEN 'Married'
                 ELSE 'n/a'
            END AS cst_marital_status,  -- Normalize marital status values
            CASE WHEN UPPER(TRIM(cst_gndr)) = 'F' THEN 'Female'
                 WHEN UPPER(TRIM(cst_gndr)) = 'M' THEN 'Male'
                 ELSE 'n/a'
            END AS cst_gndr,            -- Normalize gender values
            cst_create_date
        FROM (
            SELECT
                *,
                ROW_NUMBER() OVER (
                    PARTITION BY cst_id
                    ORDER BY cst_create_date DESC
                ) AS flag_last
            FROM bronze.crm_cust_info
            WHERE cst_id IS NOT NULL
        ) t
        WHERE flag_last = 1;            -- Keep the most recent record per customer
        SET @end_time = GETDATE();
        SELECT @row_count = COUNT(*) FROM silver.crm_cust_info;
        PRINT '>> Rows loaded: ' + CAST(@row_count AS NVARCHAR);
        PRINT '>> Load duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';

        -- 2. CRM: product info
        SET @start_time = GETDATE();
        PRINT '>> Truncating table: silver.crm_prd_info';
        TRUNCATE TABLE silver.crm_prd_info;
        PRINT '>> Inserting data into: silver.crm_prd_info';
        INSERT INTO silver.crm_prd_info (
            prd_id,
            cat_id,
            prd_key,
            prd_nm,
            prd_cost,
            prd_line,
            prd_start_dt,
            prd_end_dt
        )
        SELECT
            prd_id,
            REPLACE(SUBSTRING(prd_key, 1, 5), '-', '_') AS cat_id,   -- Extract category ID
            SUBSTRING(prd_key, 7, LEN(prd_key))         AS prd_key,  -- Extract product key
            prd_nm,
            ISNULL(prd_cost, 0)                         AS prd_cost,
            CASE WHEN UPPER(TRIM(prd_line)) = 'M' THEN 'Mountain'
                 WHEN UPPER(TRIM(prd_line)) = 'R' THEN 'Road'
                 WHEN UPPER(TRIM(prd_line)) = 'S' THEN 'Other Sales'
                 WHEN UPPER(TRIM(prd_line)) = 'T' THEN 'Touring'
                 ELSE 'n/a'
            END                                         AS prd_line, -- Map product line codes
            CAST(prd_start_dt AS DATE)                  AS prd_start_dt,
            CAST(
                LEAD(prd_start_dt) OVER (PARTITION BY prd_key ORDER BY prd_start_dt) - 1
                AS DATE
            )                                           AS prd_end_dt -- One day before the next start date
        FROM bronze.crm_prd_info;
        SET @end_time = GETDATE();
        SELECT @row_count = COUNT(*) FROM silver.crm_prd_info;
        PRINT '>> Rows loaded: ' + CAST(@row_count AS NVARCHAR);
        PRINT '>> Load duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';

        -- 3. CRM: sales details
        SET @start_time = GETDATE();
        PRINT '>> Truncating table: silver.crm_sales_details';
        TRUNCATE TABLE silver.crm_sales_details;
        PRINT '>> Inserting data into: silver.crm_sales_details';
        INSERT INTO silver.crm_sales_details (
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            sls_order_dt,
            sls_ship_dt,
            sls_due_dt,
            sls_sales,
            sls_quantity,
            sls_price
        )
        SELECT
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            CASE WHEN sls_order_dt = 0 OR LEN(sls_order_dt) != 8 THEN NULL
                 ELSE CAST(CAST(sls_order_dt AS VARCHAR) AS DATE)
            END AS sls_order_dt,
            CASE WHEN sls_ship_dt = 0 OR LEN(sls_ship_dt) != 8 THEN NULL
                 ELSE CAST(CAST(sls_ship_dt AS VARCHAR) AS DATE)
            END AS sls_ship_dt,
            CASE WHEN sls_due_dt = 0 OR LEN(sls_due_dt) != 8 THEN NULL
                 ELSE CAST(CAST(sls_due_dt AS VARCHAR) AS DATE)
            END AS sls_due_dt,
            CASE WHEN sls_sales IS NULL OR sls_sales <= 0 OR sls_sales != sls_quantity * ABS(sls_price)
                      THEN sls_quantity * ABS(sls_price)
                 ELSE sls_sales
            END AS sls_sales,           -- Recalculate sales if the original value is missing or wrong
            sls_quantity,
            CASE WHEN sls_price IS NULL OR sls_price <= 0
                      THEN sls_sales / NULLIF(sls_quantity, 0)
                 ELSE sls_price
            END AS sls_price            -- Derive price if the original value is invalid
        FROM bronze.crm_sales_details;
        SET @end_time = GETDATE();
        SELECT @row_count = COUNT(*) FROM silver.crm_sales_details;
        PRINT '>> Rows loaded: ' + CAST(@row_count AS NVARCHAR);
        PRINT '>> Load duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';

        ------------------------------------------------------
        PRINT '------------------------------------------------';
        PRINT 'Loading ERP tables';
        PRINT '------------------------------------------------';

        -- 4. ERP: customer birthdate and gender
        SET @start_time = GETDATE();
        PRINT '>> Truncating table: silver.erp_cust_az12';
        TRUNCATE TABLE silver.erp_cust_az12;
        PRINT '>> Inserting data into: silver.erp_cust_az12';
        INSERT INTO silver.erp_cust_az12 (
            cid,
            bdate,
            gen
        )
        SELECT
            CASE WHEN cid LIKE 'NAS%' THEN SUBSTRING(cid, 4, LEN(cid))
                 ELSE cid
            END AS cid,                 -- Remove the 'NAS' prefix if present
            CASE WHEN bdate > GETDATE() THEN NULL
                 ELSE bdate
            END AS bdate,               -- Set future birthdates to NULL
            CASE WHEN UPPER(TRIM(REPLACE(gen, CHAR(13), ''))) IN ('F', 'FEMALE') THEN 'Female'
                 WHEN UPPER(TRIM(REPLACE(gen, CHAR(13), ''))) IN ('M', 'MALE')   THEN 'Male'
                 ELSE 'n/a'
            END AS gen                  -- Normalize gender values
        FROM bronze.erp_cust_az12;
        SET @end_time = GETDATE();
        SELECT @row_count = COUNT(*) FROM silver.erp_cust_az12;
        PRINT '>> Rows loaded: ' + CAST(@row_count AS NVARCHAR);
        PRINT '>> Load duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';

        -- 5. ERP: customer location
        SET @start_time = GETDATE();
        PRINT '>> Truncating table: silver.erp_loc_a101';
        TRUNCATE TABLE silver.erp_loc_a101;
        PRINT '>> Inserting data into: silver.erp_loc_a101';
        INSERT INTO silver.erp_loc_a101 (
            cid,
            cntry
        )
        SELECT DISTINCT
            REPLACE(cid, '-', '') AS cid,
            CASE WHEN UPPER(TRIM(REPLACE(cntry, CHAR(13), ''))) = 'DE' THEN 'Germany'
                 WHEN UPPER(TRIM(REPLACE(cntry, CHAR(13), ''))) IN ('US', 'USA') THEN 'United States'
                 WHEN TRIM(REPLACE(cntry, CHAR(13), '')) = '' OR cntry IS NULL THEN 'n/a'
                 ELSE TRIM(REPLACE(cntry, CHAR(13), ''))
            END AS cntry                -- Normalize country codes and handle blanks
        FROM bronze.erp_loc_a101;
        SET @end_time = GETDATE();
        SELECT @row_count = COUNT(*) FROM silver.erp_loc_a101;
        PRINT '>> Rows loaded: ' + CAST(@row_count AS NVARCHAR);
        PRINT '>> Load duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';

        -- 6. ERP: product categories
        SET @start_time = GETDATE();
        PRINT '>> Truncating table: silver.erp_px_cat_g1v2';
        TRUNCATE TABLE silver.erp_px_cat_g1v2;
        PRINT '>> Inserting data into: silver.erp_px_cat_g1v2';
        INSERT INTO silver.erp_px_cat_g1v2 (
            id,
            cat,
            subcat,
            maintenance
        )
        SELECT DISTINCT
            id,
            cat,
            subcat,
            TRIM(REPLACE(REPLACE(maintenance, CHAR(13), ''), CHAR(10), '')) AS maintenance
        FROM bronze.erp_px_cat_g1v2;
        SET @end_time = GETDATE();
        SELECT @row_count = COUNT(*) FROM silver.erp_px_cat_g1v2;
        PRINT '>> Rows loaded: ' + CAST(@row_count AS NVARCHAR);
        PRINT '>> Load duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';

        ------------------------------------------------------
        SET @batch_end_time = GETDATE();
        PRINT '================================================';
        PRINT 'Silver layer load completed';
        PRINT '>> Total duration: ' + CAST(DATEDIFF(SECOND, @batch_start_time, @batch_end_time) AS NVARCHAR) + ' seconds';
        PRINT '================================================';
    END TRY
    BEGIN CATCH
        PRINT '================================================';
        PRINT 'Error while loading the silver layer';
        PRINT 'Error message: ' + ERROR_MESSAGE();
        PRINT 'Error number:  ' + CAST(ERROR_NUMBER() AS NVARCHAR);
        PRINT 'Error state:   ' + CAST(ERROR_STATE() AS NVARCHAR);
        PRINT '================================================';
        THROW;
    END CATCH
END;
GO

-- Run it, then compare the printed row counts to the bronze tables
-- EXEC silver.load_silver;
