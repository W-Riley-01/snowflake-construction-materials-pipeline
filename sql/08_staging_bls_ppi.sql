-- =========================================================
-- Concrete & Cement Materials Market Pipeline
-- Stage 5: Transform -- STAGING view for BLS PPI
-- File: sql/08_staging_bls_ppi.sql
-- =========================================================
-- What this does, in two sentences: flattens the BLS JSON payload (one
-- RAW row per series, each holding an array of monthly observations)
-- into one typed row per series per month per load, and surfaces the
-- "preliminary" footnote and any unparseable value as explicit columns
-- instead of letting them hide inside NULLs. It is a VIEW (Stage 5
-- Decision 1), so it always reflects RAW and a wrong rule is fixed by
-- editing a query, not by re-fetching from BLS.
--
-- Decision log: docs/data_sources.md, Stage 5 Decisions 9-12.
-- Depends on:   sql/02_raw_bls_ppi_landing.sql (RAW.BLS_PPI_RAW, loaded)
--
-- Grain: one row per series per year per period PER LOAD.
-- Today: 7 series x 127 months x 1 load = 889 rows.

USE WAREHOUSE CONCRETE_PIPELINE_WH;
USE DATABASE CONCRETE_PIPELINE;
USE SCHEMA STAGING;

CREATE OR REPLACE VIEW STAGING.stg_bls_ppi (
    series_id       COMMENT 'BLS series identifier, e.g. WPU1322. Natural key; joins to MART.dim_material.series_id.',
    year            COMMENT 'Calendar year of the observation.',
    period          COMMENT 'BLS period code as published: M01-M12 are months. M13 would be an annual average and S01/S02 semiannual -- none present today, none ever dropped here.',
    month           COMMENT 'Month number 1-12 parsed from period. NULL for any non-monthly period, so a non-monthly row is visible rather than mislabelled as a month.',
    value_numeric   COMMENT 'Price index value as a decimal. NULL only when value_flag is not VALUE.',
    value_flag      COMMENT 'VALUE = parsed cleanly. EMPTY = missing or blank. NOT_NUMERIC = present but not a number. Never NULL, so GROUP BY value_flag is a complete census.',
    value_raw       COMMENT 'The value token exactly as BLS sent it (a JSON string). The receipt behind value_numeric and value_flag.',
    is_preliminary  COMMENT 'TRUE when BLS footnote code P is present. BLS revises preliminary values for up to four months, so a TRUE row may change on a later pull.',
    footnote_codes  COMMENT 'All footnote codes on the observation, comma-separated. NULL when there are none. Surfaces any code other than P instead of ignoring it.',
    loaded_at       COMMENT 'When the pipeline loaded this pull into RAW. The only thing distinguishing one BLS pull from another -- used by fact_price to pick the latest.'
)
COMMENT = 'BLS PPI observations for the seven concrete and cement series. Casts the JSON payload to typed values, flags preliminary figures, and keeps every load so revisions stay visible. Grain: one row per series per period per load (7 x 127 = 889 for the 2026-08-30 pull).'
AS
-- ---------------------------------------------------------
-- CTE 1: flatten.
--
-- RAW holds ONE row per series, and each row's raw_data contains an
-- array (raw_data:data) of about 127 monthly observations. FLATTEN
-- expands that array into one output row per element, repeating the
-- parent row's columns (seriesID, loaded_at) alongside each. LATERAL
-- is what lets FLATTEN read the array from the row it is paired with.
--
-- Colon walks into the VARIANT by key; ::STRING casts the result to a
-- real type. Everything BLS sends is a string in the JSON -- including
-- year and value -- so every cast happens in this view, not in RAW.
-- That is Stage 4 BLS Decision 1 (land raw, type later) paying off.
--
-- footnotes is kept as an ARRAY, not pulled apart here. Every
-- observation has the key; when there is no footnote it holds ONE EMPTY
-- OBJECT ([{}]), not an empty array. That shape matters below.
-- ---------------------------------------------------------
WITH flattened AS (
    SELECT
        r.raw_data:seriesID::STRING AS series_id,
        o.value:year::STRING        AS year_raw,
        o.value:period::STRING      AS period,
        o.value:value::STRING       AS value_raw,
        o.value:footnotes::ARRAY    AS footnotes,
        r.loaded_at
    FROM RAW.BLS_PPI_RAW r,
         LATERAL FLATTEN(input => r.raw_data:data) o
),

-- ---------------------------------------------------------
-- CTE 2: parse once.
--
-- The numeric parse feeds two output columns (the number, and the flag
-- saying whether a number was found), so it is computed once here
-- rather than duplicated and left to drift.
--
-- TRY_TO_DECIMAL, not TO_DECIMAL: TRY_ returns NULL on a value it
-- cannot parse instead of failing the whole view. The explicit (38, 6)
-- is not decoration -- default scale 0 would ROUND an index of 357.489
-- to 357, a quiet error in every row.
-- ---------------------------------------------------------
parsed AS (
    SELECT
        *,
        TRY_TO_DECIMAL(TRIM(value_raw), 38, 6) AS value_parsed
    FROM flattened
)

SELECT
    series_id,
    TRY_TO_NUMBER(year_raw) AS year,
    period,

    -- -----------------------------------------------------
    -- month: parsed from period ONLY when period is M01-M12.
    -- RLIKE matches the whole string, so 'M13' does not match and
    -- yields NULL. STAGING deliberately does NOT filter these rows out
    -- (Stage 5 Decision 11): the monthly-grain filter belongs in
    -- fact_price, where the grain is defined, and verification check 4
    -- below reports any row it would exclude.
    -- -----------------------------------------------------
    CASE
        WHEN period RLIKE 'M(0[1-9]|1[0-2])' THEN TO_NUMBER(SUBSTR(period, 2))
    END AS month,

    value_parsed AS value_numeric,

    CASE
        WHEN value_raw IS NULL OR TRIM(value_raw) = '' THEN 'EMPTY'
        WHEN value_parsed IS NOT NULL                  THEN 'VALUE'
        ELSE 'NOT_NUMERIC'
    END AS value_flag,

    value_raw,

    -- -----------------------------------------------------
    -- is_preliminary and footnote_codes.
    --
    -- FILTER keeps only the footnote objects that have the code we ask
    -- about; ARRAY_SIZE > 0 asks "is there at least one". This checks
    -- the whole array rather than footnotes[0], so a second footnote on
    -- the same observation cannot hide a P in position two. For the
    -- [{}] shape, the empty object has no code, so FILTER returns an
    -- empty array and the answer is FALSE -- which is correct.
    --
    -- COALESCE makes a missing footnotes key mean FALSE instead of
    -- NULL, so is_preliminary is never NULL.
    --
    -- footnote_codes keeps every code as text, so a code other than P
    -- (BLS has others) shows up as a value to look at, not as nothing.
    -- -----------------------------------------------------
    COALESCE(ARRAY_SIZE(FILTER(footnotes, f -> f:code::STRING = 'P')) > 0, FALSE) AS is_preliminary,

    NULLIF(
        ARRAY_TO_STRING(
            TRANSFORM(FILTER(footnotes, f -> f:code IS NOT NULL), f -> f:code::STRING),
            ','
        ),
        ''
    ) AS footnote_codes,

    -- Lineage from RAW. The 2026-08-30 pull is the only load today.
    -- Every later pull arrives with a new loaded_at; keeping all of
    -- them here (Stage 5 Decision 9) is what lets a revision be seen.
    loaded_at

FROM parsed;


-- =========================================================
-- VERIFICATION -- run in the ScratchPad after creating the view
-- =========================================================

-- 1. Row count. Expect 889 (7 series x 127 months, one load).
-- SELECT COUNT(*) AS row_count FROM STAGING.stg_bls_ppi;

-- 2. Rows per series. Expect 7 rows, each 127.
-- SELECT series_id, COUNT(*) AS n FROM STAGING.stg_bls_ppi GROUP BY series_id ORDER BY series_id;

-- 3. Value flag census. Expect one row: VALUE = 889. The counts must
--    sum to the row count or there is a bug.
-- SELECT value_flag, COUNT(*) AS n FROM STAGING.stg_bls_ppi GROUP BY value_flag;

-- 4. Non-monthly periods. Expect ZERO rows. Any row here has month IS
--    NULL and will be excluded from fact_price. It is silent in the
--    view and loud here -- the same trade as Decision 7.
-- SELECT series_id, year, period, COUNT(*) AS n
--   FROM STAGING.stg_bls_ppi
--  WHERE month IS NULL
--  GROUP BY series_id, year, period;

-- 5. Duplicates inside a single load. Expect ZERO rows. Duplicates
--    across loads are expected and handled by fact_price; duplicates
--    within ONE load would make "latest load wins" arbitrary.
-- SELECT series_id, year, period, loaded_at, COUNT(*) AS n
--   FROM STAGING.stg_bls_ppi
--  GROUP BY series_id, year, period, loaded_at
-- HAVING COUNT(*) > 1;

-- 6. Footnote census. Expect two rows: NULL = 861, 'P' = 28.
--    Any other code is a footnote this view has never seen.
-- SELECT footnote_codes, COUNT(*) AS n
--   FROM STAGING.stg_bls_ppi
--  GROUP BY footnote_codes ORDER BY footnote_codes;

-- 7. Preliminary window. Expect 7 rows, each prelim_rows = 4, and the
--    four months are the most recent four in every series.
-- SELECT series_id,
--        COUNT_IF(is_preliminary) AS prelim_rows,
--        MIN(CASE WHEN is_preliminary THEN year * 100 + month END) AS first_prelim,
--        MAX(year * 100 + month) AS last_month
--   FROM STAGING.stg_bls_ppi
--  GROUP BY series_id ORDER BY series_id;

-- 8. Cast integrity. Expect ZERO rows: a row flagged VALUE must have
--    a number.
-- SELECT * FROM STAGING.stg_bls_ppi WHERE value_flag = 'VALUE' AND value_numeric IS NULL;

-- 9. Regression value. Expect WPU1322 2026 M07 = 357.489, preliminary.
--    This number comes from the 2026-08-30 pull itself, so it proves
--    the view reproduces RAW, not that RAW matches BLS. For an
--    independent check, compare one value by hand against data.bls.gov.
-- SELECT series_id, year, period, value_numeric, is_preliminary
--   FROM STAGING.stg_bls_ppi
--  WHERE series_id = 'WPU1322' AND year = 2026 AND period = 'M07';

-- 10. Deployed view matches this file. Compare against the repo copy.
-- SELECT GET_DDL('VIEW', 'CONCRETE_PIPELINE.STAGING.STG_BLS_PPI');
