-- =========================================================
-- Concrete & Cement Materials Market Pipeline
-- Stage 5: Transform -- STAGING view for Census VIP
-- File: sql/10_staging_census_vip.sql
-- =========================================================
-- What this does, in two sentences: types the Census construction
-- spending observations, derives the construction category from the
-- category CODE Census sent through one map in this view, and carries a
-- verified flag on every row, set TRUE only for a category whose values
-- were checked against an independent republication of the Census
-- series (Stage 5 Decision 17). It is a
-- VIEW (Stage 5 Decision 1), so correcting the mapping is an edit to
-- this file, not a re-fetch.
--
-- Decision log: docs/data_sources.md, Stage 5 Decisions 13-15 and 17.
-- Depends on:   RAW.CENSUS_VIP_RAW (loaded; see Census Decisions 1-2)
--
-- Shape: unlike BLS, every RAW row here is ONE observation (one JSON
-- object), so no FLATTEN is needed. Keys are read straight off the row.
--
-- Grain: one row per category per month per load. Today: 3 categories
-- x 126 months x 1 load = 378 rows, 2016-01 through 2026-06.

USE WAREHOUSE CONCRETE_PIPELINE_WH;
USE DATABASE CONCRETE_PIPELINE;
USE SCHEMA STAGING;

CREATE OR REPLACE VIEW STAGING.stg_census_vip (
    category_code        COMMENT 'Census category code exactly as the API returned it, e.g. 03XX. This is the fact; the category name is our interpretation of it.',
    construction_category COMMENT 'Category name derived from category_code through the map in this view. Unknown when the code is not in the map, so an unmapped code is visible rather than dropped.',
    category_verified    COMMENT 'TRUE when the category values were checked against an independent republication of the Census series (FRED, 2026-10-02): every settled month identical. FALSE for any category not so checked. A value-level check, not the authoritative Census code table; the disputed codes 02XX and 12XX are not landed. See Stage 5 Decision 17.',
    category_label_raw   COMMENT 'The category label stamped onto the row by the fetch script at load time. Kept only so a disagreement with construction_category is detectable.',
    year                 COMMENT 'Calendar year parsed from time. NULL if time is not YYYY-MM.',
    month                COMMENT 'Month 1-12 parsed from time. NULL if time is not YYYY-MM, so a malformed period is visible rather than mislabelled.',
    time_raw             COMMENT 'The time token exactly as Census sent it (YYYY-MM).',
    value_numeric        COMMENT 'Construction spending value, millions of dollars, NOT seasonally adjusted. Unit taken from Census release tables; it is not carried in the API payload. NULL only when value_flag is not VALUE.',
    value_flag           COMMENT 'VALUE = parsed cleanly. EMPTY = missing or blank. NOT_NUMERIC = present but not a number. Never NULL, so GROUP BY value_flag is a complete census.',
    value_raw            COMMENT 'The cell_value token exactly as Census sent it (a JSON string). The receipt behind value_numeric.',
    data_type_code       COMMENT 'Census data type code. T on every row today. Kept so the assumption that it is constant can be checked.',
    seasonally_adj       COMMENT 'no on every row today -- the API offers only unadjusted data per category. Kept so the assumption can be checked.',
    us                   COMMENT 'Geography flag. 1 on every row today (national level). Kept so the assumption can be checked.',
    time_slot_id         COMMENT 'Census time slot. 0 on every row today (monthly). Kept so the assumption can be checked.',
    loaded_at            COMMENT 'When the pipeline loaded this pull into RAW. Used by fact_spend to pick the latest load.'
)
COMMENT = 'Census VIP construction spending for the loaded categories (Commercial, Power, Manufacturing). Types the payload, derives category from code through one map, and flags every row as verified or not. Grain: one row per category per month per load (3 x 126 = 378 for the 2026-08-31 pull).'
AS
-- ---------------------------------------------------------
-- CTE 1: read the keys off each RAW row.
--
-- Colon walks into the VARIANT by key; ::STRING casts the result.
-- Census sends every field as a string -- including cell_value -- so
-- all typing happens in this view, not in RAW (the same payoff as
-- BLS Decision 1: land raw, type later).
-- ---------------------------------------------------------
WITH base AS (
    SELECT
        raw_data:category_code::STRING  AS category_code,
        raw_data:category_label::STRING AS category_label_raw,
        raw_data:time::STRING           AS time_raw,
        raw_data:cell_value::STRING     AS value_raw,
        raw_data:data_type_code::STRING AS data_type_code,
        raw_data:seasonally_adj::STRING AS seasonally_adj,
        raw_data:us::STRING             AS us,
        raw_data:time_slot_id::STRING   AS time_slot_id,
        loaded_at
    FROM RAW.CENSUS_VIP_RAW
),

-- ---------------------------------------------------------
-- CTE 2: parse once.
--
-- TRY_TO_DECIMAL(38, 6): TRY_ returns NULL on a value it cannot parse
-- instead of failing the view, and the explicit scale stops default
-- scale 0 from rounding. time_ok tests the whole string against
-- YYYY-MM; COALESCE makes a NULL time count as not ok.
-- ---------------------------------------------------------
parsed AS (
    SELECT
        *,
        TRY_TO_DECIMAL(TRIM(value_raw), 38, 6)                          AS value_parsed,
        COALESCE(time_raw RLIKE '[0-9]{4}-(0[1-9]|1[0-2])', FALSE)      AS time_ok
    FROM base
),

-- ---------------------------------------------------------
-- CTE 3: the category map -- the ONLY place category names appear.
--
-- Census sends a code, not a name. The code is a fact about the
-- source; the name is OUR interpretation of it, reached by
-- cross-referencing live values against Census press-release tables
-- (Census Decision 1). Interpretation belongs downstream, where
-- changing it is an edit to a query. That is why the name is derived
-- here, not read from the label the fetch script stamped into RAW:
-- if a mapping turns out to be wrong, one line below changes and no
-- data is re-fetched.
--
-- category_verified is TRUE only for a category whose values were
-- checked against an independent republication of the Census series
-- (Stage 5 Decision 17). On 2026-10-02 all three landed categories
-- passed: yearly sums for 2016-2025 and Jan-Apr 2026 identical to
-- FRED's republication, with only the two newest months differing, as
-- Census revises them. That is strong value-level evidence, not the
-- authoritative code table. Census Decision 1 logged these mappings as
-- high confidence in a METHOD, and the Census reply that contradicted
-- another code in the same table shows why that is not verification.
-- A new category defaults to FALSE here until it passes the same check.
--
-- Highway and Street is deliberately absent: it is not landed, and
-- its code is the disputed one (02XX vs 12XX). Adding it later is one
-- line here plus a load.
-- ---------------------------------------------------------
category_map AS (
    SELECT
        column1 AS category_code,
        column2 AS construction_category,
        column3 AS category_verified
    FROM VALUES
        ('03XX', 'Commercial',    TRUE),
        ('11XX', 'Power',         TRUE),
        ('20IX', 'Manufacturing', TRUE)
)

SELECT
    p.category_code,

    -- LEFT JOIN, not INNER: a code with no map entry lands on 'Unknown'
    -- instead of vanishing. Same guard as the unknown dimension member.
    COALESCE(m.construction_category, 'Unknown') AS construction_category,
    COALESCE(m.category_verified, FALSE)         AS category_verified,

    p.category_label_raw,

    CASE WHEN p.time_ok THEN TO_NUMBER(SUBSTR(p.time_raw, 1, 4)) END AS year,
    CASE WHEN p.time_ok THEN TO_NUMBER(SUBSTR(p.time_raw, 6, 2)) END AS month,
    p.time_raw,

    p.value_parsed AS value_numeric,
    CASE
        WHEN p.value_raw IS NULL OR TRIM(p.value_raw) = '' THEN 'EMPTY'
        WHEN p.value_parsed IS NOT NULL                    THEN 'VALUE'
        ELSE 'NOT_NUMERIC'
    END AS value_flag,
    p.value_raw,

    -- The four fields below are constant today. They are kept, not
    -- dropped, so the assumption "every row is national, monthly,
    -- unadjusted, type T" is a check instead of a belief. If seasonally
    -- adjusted rows ever landed alongside unadjusted ones, fact_spend
    -- would double count; check 7 below would report it first.
    p.data_type_code,
    p.seasonally_adj,
    p.us,
    p.time_slot_id,

    p.loaded_at
FROM parsed p
LEFT JOIN category_map m
       ON p.category_code = m.category_code;


-- =========================================================
-- VERIFICATION -- run in the ScratchPad after creating the view
-- =========================================================

-- 1. Row count. Expect 378 (3 categories x 126 months, one load).
-- SELECT COUNT(*) AS row_count FROM STAGING.stg_census_vip;

-- 2. Rows per category. Expect 3 rows, each 126, months 2016-01 to 2026-06.
-- SELECT category_code, construction_category, COUNT(*) AS n,
--        MIN(time_raw) AS first_month, MAX(time_raw) AS last_month
--   FROM STAGING.stg_census_vip
--  GROUP BY category_code, construction_category ORDER BY category_code;

-- 3. Value flag census. Expect one row: VALUE = 378.
-- SELECT value_flag, COUNT(*) AS n FROM STAGING.stg_census_vip GROUP BY value_flag;

-- 4. Malformed periods. Expect ZERO rows. Any row has month IS NULL
--    and is excluded from fact_spend -- silent in the view, loud here.
-- SELECT category_code, time_raw, COUNT(*) AS n
--   FROM STAGING.stg_census_vip WHERE month IS NULL GROUP BY 1, 2;

-- 5. Unmapped category codes. Expect ZERO rows. A new code from a
--    future fetch lands here as 'Unknown' until it is added to the map.
-- SELECT DISTINCT category_code
--   FROM STAGING.stg_census_vip WHERE construction_category = 'Unknown';

-- 6. Map vs. fetch-time label. Expect ZERO rows. A row here means the
--    label stamped at load disagrees with this view's map -- either the
--    map was edited (intended, then update RAW's expectation) or the
--    fetch script and the map have drifted.
-- SELECT DISTINCT category_code, category_label_raw, construction_category
--   FROM STAGING.stg_census_vip
--  WHERE category_label_raw <> construction_category;

-- 7. Assumed-constant fields. Expect ZERO rows. Any row means a
--    seasonally adjusted, non-national, non-monthly or differently typed
--    observation has landed, and fact_spend's grain is no longer safe.
-- SELECT data_type_code, seasonally_adj, us, time_slot_id, COUNT(*) AS n
--   FROM STAGING.stg_census_vip
--  WHERE data_type_code <> 'T' OR seasonally_adj <> 'no'
--     OR us <> '1' OR time_slot_id <> '0'
--  GROUP BY 1, 2, 3, 4;

-- 8. Duplicates inside a single load. Expect ZERO rows. Duplicates
--    across loads are expected and handled by fact_spend.
-- SELECT category_code, year, month, loaded_at, COUNT(*) AS n
--   FROM STAGING.stg_census_vip
--  GROUP BY 1, 2, 3, 4 HAVING COUNT(*) > 1;

-- 9. Verification status. Expect 378 rows, all category_verified TRUE
--    (checked against an independent republication, 2026-10-02). A row
--    with FALSE is a category that has not passed that check.
-- SELECT category_verified, COUNT(*) AS n
--   FROM STAGING.stg_census_vip GROUP BY category_verified;

-- 10. Regression value. Expect Commercial 2019-01 = 6009. From the
--     2026-08-31 pull itself: proves the view reproduces RAW, not that
--     RAW matches Census.
-- SELECT category_code, construction_category, time_raw, value_numeric
--   FROM STAGING.stg_census_vip
--  WHERE category_code = '03XX' AND time_raw = '2019-01';

-- 11. Deployed view matches this file. Compare against the repo copy.
-- SELECT GET_DDL('VIEW', 'CONCRETE_PIPELINE.STAGING.STG_CENSUS_VIP');
