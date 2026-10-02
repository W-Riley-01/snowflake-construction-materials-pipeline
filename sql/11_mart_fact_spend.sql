-- =========================================================
-- Concrete & Cement Materials Market Pipeline
-- Stage 5: Transform -- MART fact view for Census construction spend
-- File: sql/11_mart_fact_spend.sql
-- =========================================================
-- What this does, in two sentences: takes the typed Census observations
-- from STAGING, keeps only monthly rows, picks the most recently loaded
-- value for each category and month, and resolves the time key against
-- dim_time_monthly. It is a VIEW (Stage 5 Decision 4, hybrid storage),
-- so it is always current with STAGING and never needs rebuilding.
--
-- Decision log: docs/data_sources.md, Stage 5 Decisions 13-15.
-- Depends on: sql/10_staging_census_vip.sql  (STAGING view)
--             sql/06_mart_dimensions.sql     (must run FIRST)
--
-- Grain: one row per month per construction category. Today that is
-- 378 rows -- 3 categories x 126 months, 2016-01 through 2026-06.
--
-- NOT A TOTAL. Only three of the four planned categories are landed.
-- Highway and Street is missing, so summing spend_amount across
-- categories gives the spend of THREE categories, not total
-- construction spending. See the column comment and check 6.

-- ---------------------------------------------------------
-- DIVERGENCES FROM THE STAGE 3 DESIGN -- to reconcile in docs/schema.md
--
-- 1. No `spend_key` surrogate primary key. A view stores nothing, so a
--    generated key would be recomputed on every read and could not be
--    referenced stably (Stage 5 Decision 4). The grain
--    (time_key, construction_category) is the row's identity and
--    verification check 2 enforces it.
--
-- 2. Adds `category_verified` (Stage 5 Decision 14). The mapping from
--    Census category code to category name has not been checked
--    against a source of record, and the status travels with each row.
--
-- 3. Three categories, not four. Highway and Street is not landed
--    (Census Decisions 1-2).
-- ---------------------------------------------------------

USE WAREHOUSE CONCRETE_PIPELINE_WH;
USE DATABASE CONCRETE_PIPELINE;
USE SCHEMA MART;

CREATE OR REPLACE VIEW MART.fact_spend (
    time_key              COMMENT 'FK -> dim_time_monthly. Year-month as an integer, YYYYMM (e.g. 202606). -1 = month missing from dim_time_monthly.',
    source_key            COMMENT 'FK -> dim_source. Constant 2 (Census VIP) by construction -- this view reads only Census.',
    construction_category COMMENT 'Degenerate dimension (Stage 3 Decision 4). Commercial, Power or Manufacturing today. Unknown = a Census category code not in the STAGING map. Highway and Street is NOT yet landed.',
    spend_amount          COMMENT 'Construction spending in millions of dollars, NOT seasonally adjusted. ADDITIVE across months and across categories -- but the categories loaded are only three of four, so a sum across categories is NOT total construction spending. Never add to price_index.',
    category_verified     COMMENT 'FALSE while the Census category code behind construction_category is an unverified inference (data_sources.md open item 2). Do not treat an unverified category label as a source of record.'
)
COMMENT = 'Census VIP construction spend, one row per month per category, latest load wins. Monthly, not seasonally adjusted. Three of four planned categories loaded. Built over STAGING.stg_census_vip.'
AS
-- ---------------------------------------------------------
-- CTE 1: monthly rows only.
--
-- The monthly-grain filter lives here, in the fact, where grain is
-- defined (Stage 5 Decision 11). A row whose time was not YYYY-MM has
-- month IS NULL and is dropped here -- silent in the view, loud in
-- check 4 of 10_staging_census_vip.sql.
-- ---------------------------------------------------------
WITH monthly AS (
    SELECT
        category_code,
        construction_category,
        category_verified,
        year,
        month,
        value_numeric,
        loaded_at
    FROM STAGING.stg_census_vip
    WHERE month IS NOT NULL
),

-- ---------------------------------------------------------
-- CTE 2: release precedence -- the most recent load wins.
--
-- The same rule as fact_price (Stage 5 Decision 9), restated for
-- Census. STAGING keeps every load; when a later pull re-sends a month
-- for a category, ROW_NUMBER numbers the rows newest first and QUALIFY
-- keeps number 1. One whole row is chosen, never a value from each.
--
-- Partitioned by category_CODE, not the derived name, so a mapping
-- edit in STAGING can never merge or split the groups. Two assumptions
-- keep this safe, and both are checked in STAGING: every row is
-- unadjusted (otherwise adjusted and unadjusted rows would compete for
-- one slot) and no duplicates exist within one load.
-- ---------------------------------------------------------
latest AS (
    SELECT *
    FROM monthly
    QUALIFY ROW_NUMBER() OVER (
                PARTITION BY category_code, year, month
                ORDER BY loaded_at DESC
            ) = 1
)

-- ---------------------------------------------------------
-- Dimension resolution -- LEFT JOIN with COALESCE(key, -1), so an
-- unmatched month lands visibly on Unknown instead of disappearing
-- (Stage 5 Decision 4). source_key is a literal because source is a
-- property of this view, which reads only Census.
--
-- There is no material_key: Census spending is by construction type,
-- not by material, so it cannot join dim_material. It meets BLS and
-- USGS through time, not through a shared category.
-- ---------------------------------------------------------
SELECT
    COALESCE(t.time_key, -1)       AS time_key,
    2                              AS source_key,
    l.construction_category,
    l.value_numeric                AS spend_amount,
    l.category_verified
FROM latest l
LEFT JOIN MART.dim_time_monthly t
       ON (l.year * 100 + l.month) = t.time_key;


-- ---------------------------------------------------------
-- KNOWN LIMITATIONS
--
-- 1. loaded_at orders loads, not publications -- the same limitation
--    as fact_price (Decision 9). Re-loading an older Census file after
--    a newer one would make the older values win. Check 5 shows months
--    covered by more than one load.
--
-- 2. Unverified categories. Every row carries category_verified =
--    FALSE. Verification means checking each code against the Census
--    zipped VIP dataset, then flipping the flag in the STAGING map.
--    The disputed codes (02XX, 12XX) are not landed, so no row in this
--    view depends on the contradicted mapping -- but the three landed
--    codes were reached by the same method and are not yet confirmed.
-- ---------------------------------------------------------


-- =========================================================
-- VERIFICATION -- run in the ScratchPad after creating the view
-- =========================================================

-- 1. Row count. Expect 378 -- 3 categories x 126 months.
-- SELECT COUNT(*) AS row_count FROM MART.fact_spend;

-- 2. Grain uniqueness. Expect ZERO rows. The view has no primary key
--    (see DIVERGENCES), so this IS the identity check.
-- SELECT time_key, construction_category, COUNT(*) AS n
--   FROM MART.fact_spend
--  GROUP BY time_key, construction_category
-- HAVING COUNT(*) > 1;

-- 3. Unknown-member usage. Expect ZERO rows. A row here means a month
--    is missing from dim_time_monthly or a category code is unmapped.
-- SELECT * FROM MART.fact_spend
--  WHERE time_key = -1 OR construction_category = 'Unknown';

-- 4. Empty spend. Expect ZERO rows.
-- SELECT * FROM MART.fact_spend WHERE spend_amount IS NULL;

-- 5. Months covered by more than one load. Expect ZERO rows today
--    (one load). After a second pull this lists the months decided by
--    "latest wins".
-- SELECT category_code, year, month, COUNT(DISTINCT loaded_at) AS loads
--   FROM STAGING.stg_census_vip
--  WHERE month IS NOT NULL
--  GROUP BY 1, 2, 3 HAVING COUNT(DISTINCT loaded_at) > 1;

-- 6. Categories present. Expect exactly 3 rows: Commercial, Manufacturing,
--    Power -- 126 each. A fourth row means Highway and Street has landed;
--    update the NOT A TOTAL warning and the category count in schema.md.
-- SELECT construction_category, category_verified, COUNT(*) AS n
--   FROM MART.fact_spend
--  GROUP BY construction_category, category_verified
--  ORDER BY construction_category;

-- 7. Regression value. Expect Commercial, 201901: spend_amount 6009.
--    From the 2026-08-31 pull; see check 10 in 10_staging_census_vip.sql
--    for what this does and does not prove.
-- SELECT * FROM MART.fact_spend
--  WHERE time_key = 201901 AND construction_category = 'Commercial';

-- 8. THE TWO-FACT MONTHLY JOIN -- the payoff of one shared
--    dim_time_monthly. BLS cement price against Census construction
--    spend, joined on time_key because both are monthly. Expect 126 rows
--    (2016-01 to 2026-06, the months both cover).
--    SUM of spend across the three loaded categories is a legitimate sum
--    (spend is additive) but is NOT total construction spending -- see
--    NOT A TOTAL. price_index is read, never summed.
-- SELECT s.time_key,
--        MAX(p.price_index)        AS cement_price_index,
--        SUM(s.spend_amount)       AS spend_three_categories_musd
--   FROM MART.fact_spend s
--   JOIN MART.fact_price p
--     ON p.time_key = s.time_key
--    AND p.material_key = 1
--  GROUP BY s.time_key
--  ORDER BY s.time_key;
