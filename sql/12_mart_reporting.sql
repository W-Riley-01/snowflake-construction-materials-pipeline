-- =========================================================
-- Concrete & Cement Materials Market Pipeline
-- Stage 6: BI layer -- annual reporting view + read-only BI role
-- =========================================================
-- What this does, in two sentences: builds one reporting view that
-- lines up all three sources at the only grain they share (calendar
-- year), and a read-only role that can SELECT from MART and nothing
-- else -- the role a BI tool connects with.
--
-- Decision log: docs/data_sources.md, Stage 6 Decisions 1-2.
-- Depends on:   sql/06 (dimensions) and sql/07, sql/09, sql/11 (fact views)
--
-- Drill-across, not a join of facts: each fact is aggregated to year
-- on its own FIRST, and only the yearly results are joined, on year.
-- Joining fact_price (monthly) to fact_production (annual) row to row
-- would repeat each annual figure twelve times -- the fan-out the two
-- separate time dimensions exist to prevent (Stage 3 Decision 1).
-- =========================================================

USE DATABASE CONCRETE_PIPELINE;
USE SCHEMA MART;

-- ---------------------------------------------------------
-- 1. Reporting view (Stage 6 Decision 1)
-- ---------------------------------------------------------
-- Spine: every year in dim_time_monthly (2016-2026), so price and
-- spend history is kept even where USGS has no figure. Production
-- columns are NULL outside 2021-2025 -- missing, not zero.
--
-- Unknown-member rows (time_key -1) are excluded: a row with no known
-- period cannot be placed in a year. Verification for fact_price and
-- fact_spend found zero such rows.
CREATE OR REPLACE VIEW MART.rpt_annual_cement_market (
    year                      COMMENT 'Calendar year. One row per year, 2016 onward.',
    cement_ppi_avg            COMMENT 'Mean of monthly BLS PPI for cement (WPU1322). An index: non-additive. Includes preliminary months.',
    ready_mix_ppi_avg         COMMENT 'Mean of monthly BLS PPI for ready-mixed concrete (WPU1333).',
    concrete_products_ppi_avg COMMENT 'Mean of monthly BLS PPI for concrete products (WPU133, parent series).',
    price_months              COMMENT 'Months of cement PPI behind cement_ppi_avg. Under 12 means a partial year.',
    preliminary_months        COMMENT 'Of those months, how many BLS still marks preliminary.',
    spend_commercial_musd     COMMENT 'Census VIP Commercial, sum of monthly not-seasonally-adjusted values. Millions of USD.',
    spend_manufacturing_musd  COMMENT 'Census VIP Manufacturing, as above.',
    spend_power_musd          COMMENT 'Census VIP Power, as above.',
    spend_3cat_musd           COMMENT 'Sum of the three landed categories. NOT total construction spending: Highway and Street is not landed.',
    spend_months              COMMENT 'Months of Census data behind the spend columns. Under 12 means a partial year.',
    cement_production_kt      COMMENT 'USGS U.S. cement production, thousand metric tons. NULL outside the MCS release years.',
    imports_cement_kt         COMMENT 'USGS cement imports, thousand metric tons.',
    apparent_consumption_kt   COMMENT 'USGS apparent consumption, thousand metric tons.',
    avg_mill_price_usd_per_t  COMMENT 'USGS average mill price, USD per metric ton. Non-additive.',
    net_import_reliance_pct   COMMENT 'USGS net import reliance, percent of apparent consumption. Non-additive.',
    is_complete_year          COMMENT 'TRUE when both price_months and spend_months are 12. Filter on this before comparing years.'
)
COMMENT = 'Annual drill-across of BLS PPI, Census VIP and USGS MCS for BI. Each fact aggregated to year before joining. Built over MART fact views.'
AS
WITH years AS (
    SELECT DISTINCT year
      FROM MART.dim_time_monthly
     WHERE time_key > 0
),
price AS (
    SELECT t.year,
           AVG(IFF(m.series_id = 'WPU1322', f.price_index, NULL)) AS cement_ppi_avg,
           AVG(IFF(m.series_id = 'WPU1333', f.price_index, NULL)) AS ready_mix_ppi_avg,
           AVG(IFF(m.series_id = 'WPU133',  f.price_index, NULL)) AS concrete_products_ppi_avg,
           COUNT(IFF(m.series_id = 'WPU1322', f.time_key, NULL))  AS price_months,
           COUNT_IF(m.series_id = 'WPU1322' AND f.is_preliminary) AS preliminary_months
      FROM MART.fact_price f
      JOIN MART.dim_time_monthly t ON t.time_key = f.time_key
      JOIN MART.dim_material     m ON m.material_key = f.material_key
     WHERE f.time_key > 0
     GROUP BY t.year
),
spend AS (
    SELECT t.year,
           SUM(IFF(f.construction_category = 'Commercial',    f.spend_amount, NULL)) AS spend_commercial_musd,
           SUM(IFF(f.construction_category = 'Manufacturing', f.spend_amount, NULL)) AS spend_manufacturing_musd,
           SUM(IFF(f.construction_category = 'Power',         f.spend_amount, NULL)) AS spend_power_musd,
           SUM(f.spend_amount)        AS spend_3cat_musd,
           COUNT(DISTINCT f.time_key) AS spend_months
      FROM MART.fact_spend f
      JOIN MART.dim_time_monthly t ON t.time_key = f.time_key
     WHERE f.time_key > 0
     GROUP BY t.year
),
production AS (
    SELECT a.year,
           p.cement_production    AS cement_production_kt,
           p.imports_cement       AS imports_cement_kt,
           p.apparent_consumption AS apparent_consumption_kt,
           p.avg_mill_price_usd_per_t,
           p.net_import_reliance_pct
      FROM MART.fact_production p
      JOIN MART.dim_time_annual a ON a.time_key = p.time_key
      JOIN MART.dim_material    m ON m.material_key = p.material_key
     WHERE p.time_key > 0
       AND m.material_name = 'Cement'
)
SELECT y.year,
       p.cement_ppi_avg,
       p.ready_mix_ppi_avg,
       p.concrete_products_ppi_avg,
       p.price_months,
       p.preliminary_months,
       s.spend_commercial_musd,
       s.spend_manufacturing_musd,
       s.spend_power_musd,
       s.spend_3cat_musd,
       s.spend_months,
       pr.cement_production_kt,
       pr.imports_cement_kt,
       pr.apparent_consumption_kt,
       pr.avg_mill_price_usd_per_t,
       pr.net_import_reliance_pct,
       (COALESCE(p.price_months, 0) = 12 AND COALESCE(s.spend_months, 0) = 12) AS is_complete_year
  FROM years y
  LEFT JOIN price      p  ON p.year  = y.year
  LEFT JOIN spend      s  ON s.year  = y.year
  LEFT JOIN production pr ON pr.year = y.year;


-- ---------------------------------------------------------
-- 2. Read-only BI role (Stage 6 Decision 2)
-- ---------------------------------------------------------
-- BI tools connect with this role. It can read MART and nothing else:
-- no RAW, no STAGING, no create or write. MART's fact views read
-- STAGING with the view owner's privileges, so the role needs SELECT
-- on the views only. SECURITYADMIN holds MANAGE GRANTS, so it can grant
-- on objects it does not own.
USE ROLE SECURITYADMIN;

CREATE ROLE IF NOT EXISTS MART_READER
  COMMENT = 'Read-only access to CONCRETE_PIPELINE.MART for BI tools';

GRANT USAGE  ON WAREHOUSE CONCRETE_PIPELINE_WH            TO ROLE MART_READER;
GRANT USAGE  ON DATABASE  CONCRETE_PIPELINE               TO ROLE MART_READER;
GRANT USAGE  ON SCHEMA    CONCRETE_PIPELINE.MART          TO ROLE MART_READER;
GRANT SELECT ON ALL TABLES    IN SCHEMA CONCRETE_PIPELINE.MART TO ROLE MART_READER;
GRANT SELECT ON ALL VIEWS     IN SCHEMA CONCRETE_PIPELINE.MART TO ROLE MART_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CONCRETE_PIPELINE.MART TO ROLE MART_READER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA CONCRETE_PIPELINE.MART TO ROLE MART_READER;

-- Standard hierarchy: system admins inherit every custom role.
GRANT ROLE MART_READER TO ROLE SYSADMIN;

-- FILL IN: replace <your_user> with your Snowflake user name.
GRANT ROLE MART_READER TO USER <your_user>;


-- ---------------------------------------------------------
-- Verification
-- ---------------------------------------------------------
-- This file ends on SECURITYADMIN, which cannot read MART. Run
-- USE ROLE ACCOUNTADMIN; (the MART owner) before checks 1-3, or they
-- fail with "does not exist or not authorized" -- a role problem, not
-- a broken view. Check 4 switches roles itself.
-- 1. One row per year, 2016 onward. Expect row_count = distinct_years.
-- SELECT COUNT(*) AS row_count, COUNT(DISTINCT year) AS distinct_years
--   FROM MART.rpt_annual_cement_market;

-- 2. Only the current, partial year is incomplete.
-- SELECT year, price_months, spend_months, is_complete_year
--   FROM MART.rpt_annual_cement_market WHERE NOT is_complete_year;

-- 3. The view reproduces the fact it aggregates. Expect the two
--    numbers to match (2025 cement PPI).
-- SELECT (SELECT cement_ppi_avg FROM MART.rpt_annual_cement_market WHERE year = 2025) AS from_view,
--        (SELECT AVG(f.price_index)
--           FROM MART.fact_price f
--           JOIN MART.dim_material m ON m.material_key = f.material_key
--          WHERE m.series_id = 'WPU1322' AND f.time_key BETWEEN 202501 AND 202512) AS from_fact;

-- 4. The role can read MART and cannot read RAW.
--    USE ROLE MART_READER;
--    SELECT COUNT(*) FROM CONCRETE_PIPELINE.MART.rpt_annual_cement_market;  -- succeeds
--    SELECT COUNT(*) FROM CONCRETE_PIPELINE.RAW.BLS_PPI_RAW;               -- fails: insufficient privileges
