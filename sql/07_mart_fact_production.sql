-- =========================================================
-- Concrete & Cement Materials Market Pipeline
-- Stage 5: Transform -- MART fact view for USGS cement production
-- File: sql/07_mart_fact_production.sql
-- =========================================================
-- What this does, in two sentences: pivots the long STAGING view
-- (eleven rows per year, one per statistic) into one wide row per
-- year with a named, documented column per statistic, and resolves
-- the dimension keys against the MART dimension tables. It is a VIEW
-- (Stage 5 Decision 4, hybrid storage), so it is always current with
-- STAGING and never needs rebuilding.
--
-- Decision log: docs/data_sources.md, Stage 5 Decisions 3-8.
-- Depends on: sql/05_staging_usgs_mcs_cement.sql (STAGING view)
--             sql/06_mart_dimensions.sql         (must run FIRST)
--
-- Grain: one row per year per material. Today that is 5 rows --
-- 2021-2025, cement only.

-- ---------------------------------------------------------
-- DIVERGENCES FROM THE STAGE 3 DESIGN -- reconciled in docs/schema.md, 2026-09-28
--
-- 1. Eleven named measure columns replace the single
--    `production_volume` column (Stage 5 Decision 3, wide grain).
--
-- 2. No `production_key` surrogate primary key. schema.md gives each
--    fact its own surrogate key, but this is a VIEW: it stores
--    nothing, so a generated key would be recomputed on every read
--    and could not be referenced stably by anything. Nothing
--    references a fact row by key anyway -- facts are referenced
--    through their dimensions. The grain (time_key, material_key)
--    is the row's identity, and verification check 2 enforces it.
--
-- 3. Adds `non_value_measure_count` (Stage 5 Decision 8).
-- ---------------------------------------------------------

USE WAREHOUSE CONCRETE_PIPELINE_WH;
USE DATABASE CONCRETE_PIPELINE;
USE SCHEMA MART;

-- ---------------------------------------------------------
-- Column-level COMMENTs carry the unit and the additivity rule for
-- every measure. This is where Stage 5 Decision 3 said that
-- documentation would live: each column has exactly one unit and one
-- additivity rule, and the rule is attached to the column itself, so
-- anyone browsing the view in Snowsight sees it without opening this
-- file.
--
-- Additivity, in one line each:
--   ADDITIVE      -- safe to SUM across years
--   SEMI-ADDITIVE -- a balance or headcount; do NOT sum across years
--   NON-ADDITIVE  -- never sum; average or compare only
-- ---------------------------------------------------------
CREATE OR REPLACE VIEW MART.fact_production (
    time_key                    COMMENT 'FK -> dim_time_annual. Holds the calendar year. -1 = year missing from dim_time_annual.',
    material_key                COMMENT 'FK -> dim_material. Constant at 1 (Cement) today. -1 = commodity missing from dim_material.',
    source_key                  COMMENT 'FK -> dim_source. Constant 3 (USGS MCS) by construction -- this view reads only USGS.',
    cement_production           COMMENT 'Portland, blended and masonry cement production. Thousand metric tons. ADDITIVE. Never add to clinker_production -- clinker becomes cement, so the sum double-counts.',
    clinker_production          COMMENT 'Clinker production. Thousand metric tons. ADDITIVE across years. Never add to cement_production.',
    shipments                   COMMENT 'Shipments to final customers, includes exports. Thousand metric tons. ADDITIVE.',
    imports_cement              COMMENT 'Imports for consumption, hydraulic cement. Thousand metric tons. ADDITIVE.',
    imports_clinker             COMMENT 'Imports for consumption, clinker. Thousand metric tons. ADDITIVE.',
    exports                     COMMENT 'Exports, hydraulic cement and clinker combined. Thousand metric tons. ADDITIVE.',
    apparent_consumption        COMMENT 'Apparent consumption. Thousand metric tons. ADDITIVE. Natural pairing for Census VIP construction spend.',
    stocks_yearend              COMMENT 'Cement stocks at year end. Thousand metric tons. SEMI-ADDITIVE -- a balance; summing across years is meaningless.',
    employment                  COMMENT 'Mine and mill employment. Headcount. SEMI-ADDITIVE -- do not sum across years.',
    avg_mill_price_usd_per_t    COMMENT 'Average mill unit value. US dollars per metric ton. NON-ADDITIVE. Natural cross-check against BLS PPI WPU1322.',
    net_import_reliance_pct     COMMENT 'Net import reliance as a percentage of apparent consumption. Percent. NON-ADDITIVE.',
    non_value_measure_count     COMMENT 'Number of measures in this row whose source value was NOT a plain number (withheld, not available, bound, etc). 0 = every measure is a real number. Anything else: check STAGING.STG_USGS_MCS_CEMENT.value_flag before trusting a NULL in this row.'
)
COMMENT = 'USGS cement salient statistics, one row per year. Wide grain: one named column per statistic, each with a single unit and additivity rule (see column comments). Built by conditional aggregation over STAGING.STG_USGS_MCS_CEMENT.'
AS
-- ---------------------------------------------------------
-- CTE 1: the statistic map -- the ONLY place publisher text appears.
--
-- Stage 5 Decision 7 confined USGS's wording to one place. This is
-- that place. Every other part of the view refers to the short
-- measure codes on the right, which are ours and never change.
--
-- If USGS rewords a statistic, the fix is one line here. And because
-- the pivot below matches on the measure code rather than on the
-- publisher string, the CASE expressions never need touching.
--
-- This also avoids the three-copies drift from Stage 5 Decision 2:
-- the strings exist once, and verification check 3 joins against
-- this same list rather than re-typing it.
-- ---------------------------------------------------------
WITH statistic_map AS (
    SELECT
        column1 AS statistic_detail,
        column2 AS measure
    FROM VALUES
        ('Production: Portland, blended, and masonry cement',            'cement_production'),
        ('Production: Clinker',                                          'clinker_production'),
        ('Shipments to final customers, includes exports',               'shipments'),
        ('Imports for consumption: Hydraulic cement',                    'imports_cement'),
        ('Imports for consumption: Clinker',                             'imports_clinker'),
        ('Exports, hydraulic cement and clinker',                        'exports'),
        ('Consumption, apparent',                                        'apparent_consumption'),
        ('Stocks, cement, yearend',                                      'stocks_yearend'),
        ('Employment, mine and mill, number',                            'employment'),
        ('Price, average mill unit value, dollars per metric ton',       'avg_mill_price_usd_per_t'),
        ('Net import reliance as a percentage of apparent consumption',  'net_import_reliance_pct')
),

-- ---------------------------------------------------------
-- CTE 2: attach a measure code to every STAGING row.
--
-- INNER JOIN on purpose: a statistic with no map entry is dropped
-- from the pivot here. That is the "silently ignored" behaviour Stage
-- 5 Decision 7 accepted -- and it is only acceptable because
-- verification check 3 reports every dropped statistic. The drop is
-- silent in the view; it is loud in the checks.
-- ---------------------------------------------------------
mapped AS (
    SELECT
        s.year,
        s.commodity,
        m.measure,
        s.value_numeric,
        s.value_flag
    FROM STAGING.STG_USGS_MCS_CEMENT s
    JOIN statistic_map m
      ON s.statistic_detail = m.statistic_detail
),

-- ---------------------------------------------------------
-- CTE 3: the pivot, by conditional aggregation.
--
-- Each line reads: "for this year, take the value whose measure code
-- is X." GROUP BY collapses the eleven rows per year into one.
--
-- Why MAX: SQL cannot know there is exactly one row per year per
-- measure, so a pivot must aggregate. With exactly one row, MAX just
-- returns it. The danger is the other case -- if two rows ever exist
-- for the same year and measure, MAX silently returns one of them and
-- hides the duplicate. Verification check 5 exists for exactly that.
-- See KNOWN LIMITATION below: it is not hypothetical.
--
-- COUNT_IF counts the measures in this year whose flag is anything
-- other than VALUE. Today every row is VALUE, so it returns 0. The
-- day USGS withholds a cement figure, this becomes 1 -- and the NULL
-- that appears in that measure's column can no longer be mistaken for
-- clean data (Stage 5 Decision 8).
-- ---------------------------------------------------------
pivoted AS (
    SELECT
        year,
        commodity,
        MAX(CASE WHEN measure = 'cement_production'        THEN value_numeric END) AS cement_production,
        MAX(CASE WHEN measure = 'clinker_production'       THEN value_numeric END) AS clinker_production,
        MAX(CASE WHEN measure = 'shipments'                THEN value_numeric END) AS shipments,
        MAX(CASE WHEN measure = 'imports_cement'           THEN value_numeric END) AS imports_cement,
        MAX(CASE WHEN measure = 'imports_clinker'          THEN value_numeric END) AS imports_clinker,
        MAX(CASE WHEN measure = 'exports'                  THEN value_numeric END) AS exports,
        MAX(CASE WHEN measure = 'apparent_consumption'     THEN value_numeric END) AS apparent_consumption,
        MAX(CASE WHEN measure = 'stocks_yearend'           THEN value_numeric END) AS stocks_yearend,
        MAX(CASE WHEN measure = 'employment'               THEN value_numeric END) AS employment,
        MAX(CASE WHEN measure = 'avg_mill_price_usd_per_t' THEN value_numeric END) AS avg_mill_price_usd_per_t,
        MAX(CASE WHEN measure = 'net_import_reliance_pct'  THEN value_numeric END) AS net_import_reliance_pct,
        COUNT_IF(value_flag <> 'VALUE')                                            AS non_value_measure_count
    FROM mapped
    GROUP BY year, commodity
)

-- ---------------------------------------------------------
-- Resolve dimension keys.
--
-- LEFT JOIN + COALESCE(..., -1): the hybrid-storage guard. An INNER
-- JOIN against a dimension missing a member would make fact rows
-- silently disappear. Here they survive and land visibly on the -1
-- unknown member instead. Verification check 6 reports any that do.
--
-- material_key joins on the commodity NAME. USGS publishes no other
-- identifier -- BLS series IDs do not exist in this source -- so the
-- name is the only natural key available. That is acceptable here for
-- two reasons: the -1 guard makes a mismatch visible rather than
-- silent, and a rename of 'Cement' would in fact first empty the
-- STAGING view, whose filter matches the same string, which
-- verification check 1 reports as a row count of zero.
--
-- source_key is a literal, not a join. Keys in dim_source are
-- explicit literals committed in 06_mart_dimensions.sql and stable
-- across rebuilds (Stage 5 Decision 6), so 3 always means USGS MCS.
-- And unlike material, source is a property of this view itself, not
-- something the data varies on: this view reads only USGS, by
-- construction. Joining to look it up would add a lookup that cannot
-- produce any other answer.
-- ---------------------------------------------------------
SELECT
    COALESCE(t.time_key,      -1)  AS time_key,
    COALESCE(dm.material_key, -1)  AS material_key,
    3                              AS source_key,
    p.cement_production,
    p.clinker_production,
    p.shipments,
    p.imports_cement,
    p.imports_clinker,
    p.exports,
    p.apparent_consumption,
    p.stocks_yearend,
    p.employment,
    p.avg_mill_price_usd_per_t,
    p.net_import_reliance_pct,
    p.non_value_measure_count
FROM pivoted p
LEFT JOIN MART.dim_time_annual t
       ON p.year = t.time_key
LEFT JOIN MART.dim_material dm
       ON p.commodity = dm.material_name;


-- ---------------------------------------------------------
-- KNOWN LIMITATION -- overlapping releases. Must be resolved before
-- a second USGS release is loaded.
--
-- USGS Decision 4 (Stage 4) designed RAW to APPEND each annual release
-- into the same table, with source_file recording which release a row
-- came from. Each release covers five years. So the 2027 release
-- (covering 2022-2026) will overlap the 2026 release (2021-2025) on
-- four years -- and USGS revises prior-year figures in later releases.
--
-- Once that second release lands, STAGING will hold TWO rows for each
-- overlapping year and statistic, possibly with different values. MAX
-- in the pivot above will then silently pick the larger of the two,
-- mixing figures from different releases in one row. No error.
--
-- Today there is one release loaded, so there are no duplicates and
-- the view is correct. The decision still to be made is RELEASE
-- PRECEDENCE: which release wins for a year both cover. Almost
-- certainly "the latest," since later releases carry revisions --
-- but "latest" needs a reliable ordering, and source_file names are
-- not currently consistent (the 2026 file was staged under its
-- published name; future fetches use a timestamped name).
--
-- Guard until then: verification check 5 fails the moment any
-- duplicate appears. Run it after every USGS load.
-- ---------------------------------------------------------


-- =========================================================
-- VERIFICATION -- run in the ScratchPad after creating the view
-- =========================================================

-- 1. Row count. Expect 5 -- one per year, 2021-2025.
-- SELECT COUNT(*) AS row_count FROM MART.fact_production;

-- 2. Grain uniqueness. Expect ZERO rows. The view has no primary
--    key (see DIVERGENCES), so this IS the identity check.
-- SELECT time_key, material_key, COUNT(*) AS n
--   FROM MART.fact_production
--  GROUP BY time_key, material_key
-- HAVING COUNT(*) > 1;

-- 3. Unmapped statistics. Expect ZERO rows. Any statistic_detail in
--    STAGING with no entry in statistic_map is being silently
--    dropped by the pivot. A reworded statistic appears here as an
--    unknown string. Add a line to statistic_map to fix.
--    (The map is repeated below because a CTE cannot be referenced
--    from outside its view. If you edit the map above, edit it here.)
-- WITH statistic_map AS (
--     SELECT column1 AS statistic_detail FROM VALUES
--         ('Production: Portland, blended, and masonry cement'),
--         ('Production: Clinker'),
--         ('Shipments to final customers, includes exports'),
--         ('Imports for consumption: Hydraulic cement'),
--         ('Imports for consumption: Clinker'),
--         ('Exports, hydraulic cement and clinker'),
--         ('Consumption, apparent'),
--         ('Stocks, cement, yearend'),
--         ('Employment, mine and mill, number'),
--         ('Price, average mill unit value, dollars per metric ton'),
--         ('Net import reliance as a percentage of apparent consumption')
-- )
-- SELECT DISTINCT s.statistic_detail
--   FROM STAGING.STG_USGS_MCS_CEMENT s
--   LEFT JOIN statistic_map m ON s.statistic_detail = m.statistic_detail
--  WHERE m.statistic_detail IS NULL;

-- 4. Empty measure columns. Expect ZERO rows for the 2026 release.
--    A NULL measure in a row where non_value_measure_count = 0 means
--    the value did not come from a sentinel -- the statistic was
--    simply not found. That is the signature of a REWORDED
--    statistic: check 3 shows the new string, check 4 shows the hole
--    it left.
-- SELECT time_key
--   FROM MART.fact_production
--  WHERE non_value_measure_count = 0
--    AND (   cement_production        IS NULL
--         OR clinker_production       IS NULL
--         OR shipments                IS NULL
--         OR imports_cement           IS NULL
--         OR imports_clinker          IS NULL
--         OR exports                  IS NULL
--         OR apparent_consumption     IS NULL
--         OR stocks_yearend           IS NULL
--         OR employment               IS NULL
--         OR avg_mill_price_usd_per_t IS NULL
--         OR net_import_reliance_pct  IS NULL);

-- 5. Duplicate source rows. Expect ZERO rows. MAX in the pivot hides
--    duplicates, so this is the only thing that catches them. First
--    thing to fail after a second USGS release is loaded (see KNOWN
--    LIMITATION), or after an accidental double load.
-- SELECT year, statistic_detail, COUNT(*) AS n
--   FROM STAGING.STG_USGS_MCS_CEMENT
--  GROUP BY year, statistic_detail
-- HAVING COUNT(*) > 1;

-- 6. Unknown-member usage. Expect ZERO rows. Any row here means a
--    dimension is missing a member and the LEFT JOIN guard caught it.
-- SELECT *
--   FROM MART.fact_production
--  WHERE time_key = -1 OR material_key = -1;

-- 7. Spot check against the published file. Expect 2025:
--    cement_production 84000, clinker_production 69000,
--    apparent_consumption 110000, avg_mill_price_usd_per_t 160,
--    net_import_reliance_pct 21, non_value_measure_count 0.
-- SELECT *
--   FROM MART.fact_production
--  WHERE time_key = 2025;

-- 8. Conformed-dimension join -- the reason material_key exists.
--    Proves fact_production resolves to the same dim_material row
--    fact_price will use for BLS WPU1322. Expect 5 rows, all
--    material_name 'Cement', series_id 'WPU1322'.
-- SELECT f.time_key, d.material_name, d.series_id, f.cement_production
--   FROM MART.fact_production f
--   JOIN MART.dim_material d ON f.material_key = d.material_key
--  ORDER BY f.time_key;