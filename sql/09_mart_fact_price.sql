-- =========================================================
-- Concrete & Cement Materials Market Pipeline
-- Stage 5: Transform -- MART fact view for BLS price index
-- File: sql/09_mart_fact_price.sql
-- =========================================================
-- What this does, in two sentences: takes the typed BLS observations
-- from STAGING, keeps only monthly rows, picks the most recently loaded
-- value for each series and month, and resolves the dimension keys
-- against the MART dimension tables. It is a VIEW (Stage 5 Decision 4,
-- hybrid storage), so it is always current with STAGING and never
-- needs rebuilding.
--
-- Decision log: docs/data_sources.md, Stage 5 Decisions 9-12.
-- Depends on: sql/08_staging_bls_ppi.sql   (STAGING view)
--             sql/06_mart_dimensions.sql   (must run FIRST -- now
--                                           includes dim_time_monthly)
--
-- Grain: one row per month per material. Today that is 889 rows --
-- 7 series x 127 months, 2016-01 through 2026-07.

-- ---------------------------------------------------------
-- DIVERGENCES FROM THE STAGE 3 DESIGN -- to reconcile in docs/schema.md
--
-- 1. No `price_key` surrogate primary key. schema.md gave each fact its
--    own surrogate key, but this is a VIEW: it stores nothing, so a
--    generated key would be recomputed on every read and could not be
--    referenced stably. The grain (time_key, material_key) is the row's
--    identity and verification check 2 enforces it. Same reasoning as
--    fact_production (Stage 5 Decision 4). schema.md left this "to be
--    confirmed when built" -- confirmed.
--
-- 2. Adds `is_preliminary` (Stage 5 Decision 10). BLS publishes the
--    most recent four months as preliminary and revises them. A
--    preliminary index value and a final one look identical as a
--    number, so the status travels with the row.
-- ---------------------------------------------------------

USE WAREHOUSE CONCRETE_PIPELINE_WH;
USE DATABASE CONCRETE_PIPELINE;
USE SCHEMA MART;

CREATE OR REPLACE VIEW MART.fact_price (
    time_key        COMMENT 'FK -> dim_time_monthly. Year-month as an integer, YYYYMM (e.g. 202607). -1 = month missing from dim_time_monthly.',
    material_key    COMMENT 'FK -> dim_material, resolved through series_id. -1 = BLS series missing from dim_material.',
    source_key      COMMENT 'FK -> dim_source. Constant 1 (BLS PPI) by construction -- this view reads only BLS.',
    price_index     COMMENT 'BLS Producer Price Index value. NON-ADDITIVE -- an index, never sum it; average or compare only. NULL means BLS value was not a plain number; check STAGING.stg_bls_ppi.value_flag.',
    is_preliminary  COMMENT 'TRUE when BLS still flags this value preliminary (the latest four months). May be revised on a later pull.'
)
COMMENT = 'BLS PPI price index, one row per month per material, latest load wins. Monthly grain only (non-monthly BLS periods are excluded). Built over STAGING.stg_bls_ppi.'
AS
-- ---------------------------------------------------------
-- CTE 1: monthly rows only.
--
-- This is where the monthly grain is enforced (Stage 5 Decision 11).
-- STAGING keeps every period BLS sends; a non-monthly period such as
-- M13 (annual average) has month IS NULL and is dropped HERE, because
-- mixing an annual average into monthly rows would corrupt any AVG run
-- against them. The drop is silent in the view and loud in
-- verification check 4 of 08_staging_bls_ppi.sql.
-- ---------------------------------------------------------
WITH monthly AS (
    SELECT
        series_id,
        year,
        month,
        value_numeric,
        is_preliminary,
        loaded_at
    FROM STAGING.stg_bls_ppi
    WHERE month IS NOT NULL
),

-- ---------------------------------------------------------
-- CTE 2: release precedence -- the most recent load wins.
--
-- STAGING keeps every pull. When a later pull re-sends a month, there
-- are two rows for the same series and month, and the later one may
-- carry a revised value (BLS revises preliminary figures for four
-- months). ROW_NUMBER numbers the rows for each series-and-month from
-- newest load to oldest; QUALIFY keeps number 1.
--
-- This is the rule USGS still lacks (see data_sources.md open items).
-- It works here because loaded_at is a reliable ordering for BLS: one
-- timestamp per pull, and every pull covers the whole series.
--
-- Unlike MAX in the USGS pivot, this cannot mix figures from two
-- pulls: one whole row is chosen, never a value from each.
-- ---------------------------------------------------------
latest AS (
    SELECT *
    FROM monthly
    QUALIFY ROW_NUMBER() OVER (
                PARTITION BY series_id, year, month
                ORDER BY loaded_at DESC
            ) = 1
)

-- ---------------------------------------------------------
-- Dimension resolution -- LEFT JOIN with COALESCE(key, -1) so an
-- unmatched row lands visibly on Unknown instead of disappearing
-- (Stage 5 Decision 4).
--
-- time_key is computed as year * 100 + month and matched against
-- dim_time_monthly.time_key, which holds the same YYYYMM value
-- (Stage 5 Decision 6: time dimensions use a meaningful key).
--
-- material resolves through series_id, the BLS natural key added to
-- dim_material in Decision 5 -- an exact match on an identifier, not a
-- string join against publisher-controlled titles.
--
-- source_key is a literal for the same reason as in fact_production:
-- source is a property of this view, which reads only BLS.
-- ---------------------------------------------------------
SELECT
    COALESCE(t.time_key,      -1)  AS time_key,
    COALESCE(dm.material_key, -1)  AS material_key,
    1                              AS source_key,
    l.value_numeric                AS price_index,
    l.is_preliminary
FROM latest l
LEFT JOIN MART.dim_time_monthly t
       ON (l.year * 100 + l.month) = t.time_key
LEFT JOIN MART.dim_material dm
       ON l.series_id = dm.series_id;


-- ---------------------------------------------------------
-- KNOWN LIMITATION -- loaded_at orders loads, not publications.
--
-- "Latest load wins" assumes pulls are loaded in publication order.
-- If an older BLS file were re-loaded after a newer one, its loaded_at
-- would be newer and its older values would win. No guard exists
-- beyond check 5 below, which shows when more than one load covers
-- the same month so the winning values can be inspected. Acceptable
-- for a pipeline that fetches the current series on each run; revisit
-- if loads ever come from archived files.
-- ---------------------------------------------------------


-- =========================================================
-- VERIFICATION -- run in the ScratchPad after creating the view
-- =========================================================

-- 1. Row count. Expect 889 -- 7 series x 127 months. Grows by 7 each
--    month a later pull adds one.
-- SELECT COUNT(*) AS row_count FROM MART.fact_price;

-- 2. Grain uniqueness. Expect ZERO rows. The view has no primary key
--    (see DIVERGENCES), so this IS the identity check.
-- SELECT time_key, material_key, COUNT(*) AS n
--   FROM MART.fact_price
--  GROUP BY time_key, material_key
-- HAVING COUNT(*) > 1;

-- 3. Unknown-member usage. Expect ZERO rows. Any row means a dimension
--    is missing a member and the LEFT JOIN guard caught it.
-- SELECT * FROM MART.fact_price WHERE time_key = -1 OR material_key = -1;

-- 4. Empty prices. Expect ZERO rows. A NULL price_index means BLS sent
--    something that was not a number; STAGING value_flag says what.
-- SELECT * FROM MART.fact_price WHERE price_index IS NULL;

-- 5. Months covered by more than one load. Expect ZERO rows today
--    (one load). After a second pull this lists the months whose value
--    was decided by "latest wins" -- inspect them for expected revisions.
-- SELECT series_id, year, month, COUNT(DISTINCT loaded_at) AS loads
--   FROM STAGING.stg_bls_ppi
--  WHERE month IS NOT NULL
--  GROUP BY series_id, year, month
-- HAVING COUNT(DISTINCT loaded_at) > 1;

-- 6. Preliminary rows. Expect 28 (7 series x latest 4 months).
-- SELECT COUNT_IF(is_preliminary) AS prelim_rows FROM MART.fact_price;

-- 7. Spot check. Expect WPU1322 (Cement), 202607: price_index 357.489,
--    is_preliminary TRUE. From the 2026-08-30 pull; see check 9 in
--    08_staging_bls_ppi.sql for what this does and does not prove.
-- SELECT f.time_key, d.material_name, d.series_id, f.price_index, f.is_preliminary
--   FROM MART.fact_price f
--   JOIN MART.dim_material d ON f.material_key = d.material_key
--  WHERE f.time_key = 202607 AND d.series_id = 'WPU1322';

-- 8. Every BLS month has a dim_time_monthly row. Expect ZERO rows.
--    Without the unknown-member guard this would be silently dropped
--    facts; check 3 would also catch it.
-- SELECT DISTINCT s.year, s.month
--   FROM STAGING.stg_bls_ppi s
--   LEFT JOIN MART.dim_time_monthly t ON (s.year * 100 + s.month) = t.time_key
--  WHERE s.month IS NOT NULL AND t.time_key IS NULL;

-- 9. Every BLS series has a dim_material row. Expect ZERO rows.
-- SELECT DISTINCT s.series_id
--   FROM STAGING.stg_bls_ppi s
--   LEFT JOIN MART.dim_material d ON s.series_id = d.series_id
--  WHERE d.material_key IS NULL;

-- 10. THE CROSS-GRAIN JOIN -- the payoff of two unconnected time
--     dimensions. BLS cement price (monthly) against USGS cement
--     production (annual), correlated on the shared `year` column.
--     Expect 5 rows, 2021-2025, all Cement.
--     AVG of an index is a legitimate average, not a sum. MAX on
--     production is only there to collapse the twelve monthly rows
--     the join repeats it across back to the single annual value --
--     SUM here would multiply production by twelve, which is exactly
--     the error the separate time dimensions exist to make visible.
-- SELECT a.year,
--        d.material_name,
--        ROUND(AVG(p.price_index), 1)  AS avg_price_index,
--        MAX(pr.cement_production)     AS cement_production_kt
--   FROM MART.fact_price p
--   JOIN MART.dim_time_monthly m  ON p.time_key = m.time_key
--   JOIN MART.dim_material d      ON p.material_key = d.material_key
--   JOIN MART.fact_production pr  ON pr.material_key = p.material_key
--   JOIN MART.dim_time_annual a   ON pr.time_key = a.time_key
--                                AND a.year = m.year
--  GROUP BY a.year, d.material_name
--  ORDER BY a.year;
