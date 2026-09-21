-- =========================================================
-- Concrete & Cement Materials Market Pipeline
-- Stage 5: Transform -- STAGING view for USGS MCS (Cement, U.S.)
-- File: sql/05_staging_usgs_mcs_cement.sql
-- Rev 2 -- rebuilt after empirical verification of the routing logic
--          against all 8,886 RAW rows (see REVISION NOTES below).
-- =========================================================
-- What this does, in two sentences: reads RAW.USGS_MCS_RAW, narrows it
-- to the U.S. cement salient-statistics slice, and turns the all-TEXT
-- Value column into three columns -- a real number where one exists, a
-- plain-language reason where one doesn't, and the original token in
-- every case. RAW is never modified; because this is a view and not a
-- stored table, it re-derives on every read and picks up next year's
-- release with no rebuild step to schedule or forget.
--
-- Decision log: data_sources.md, Stage 5 Decisions 1 (view vs.
-- materialized view vs. CTAS) and 2 (sentinel routing).

-- ---------------------------------------------------------
-- REVISION NOTES (rev 1 -> rev 2)
--
-- Rev 1 was verified by applying its CASE expression to all 8,886 RAW
-- rows rather than only to the 55-row cement slice, which contains no
-- sentinels and therefore could not exercise the routing at all. That
-- diagnostic returned 33 rows the mapping could not classify. All
-- three changes below come from inspecting those 33 by hex.
--
-- 1. NON-BREAKING SPACE. The token displaying as '68' is the bytes
--    36 38 C2 A0 -- the digits, then a non-breaking space (U+00A0).
--    TRIM removes ordinary spaces only, so a valid number failed to
--    parse. Whitespace stripping now removes CHR(160) as well. This
--    is a correctness fix, not a refinement: rev 1 flagged a real
--    number as an unclassified sentinel.
--
--    Noted for the record: NBSP arrived as UTF-8 bytes (C2 A0) in a
--    file loaded as WINDOWS1252, where A0 alone is already an NBSP.
--    The publisher appears to have mixed encodings within one file.
--    Nothing to fix on our side -- but visible only because RAW
--    preserved the bytes instead of normalizing them.
--
-- 2. RANGES ARE A DISTINCT CATEGORY. Eleven of the 33 are two-sided
--    intervals ('190 - 290', '500-17,000', '890-1,000'). The
--    publisher's metadata does not document them. They are not
--    BOUND -- a one-sided inequality and a two-sided interval are
--    different facts -- so they get their own RANGE flag rather than
--    being folded in. Folding them would mean re-reading value_raw
--    to tell them apart, which is the re-implementation the flag
--    column exists to prevent.
--
--    THIRD DASH CHARACTER FOUND. Range separators are inconsistent:
--    some use a spaced hyphen-minus (U+002D), others an unspaced
--    EN dash (U+2013). Combined with the em dash (U+2014) meaning
--    zero, this file uses three dash characters for three unrelated
--    meanings. A generic "normalize the dashes" cleanup step would
--    have destroyed the zeros and merged two separate meanings.
--
-- 3. TWO QUALIFIERS ADDED. 'Moderate to large' and 'Very small' join
--    the exact-match qualifier list. Kept as literal strings rather
--    than a loose pattern so every classified token stays auditable
--    and anything genuinely new still falls to UNKNOWN_SENTINEL.
--
-- STILL UNCLASSIFIED BY DESIGN: '?1' and '?10' are hex 3F 31 and
-- 3F 31 30 -- a real ASCII question mark, not a rendering artifact.
-- Most likely a mangled inequality symbol in the publisher's own
-- export. The published bytes carry no recoverable meaning, so
-- UNKNOWN_SENTINEL is the correct and honest destination.
--
-- SCOPE: none of the 33 rows are cement. The 55-row output of this
-- view is identical in rev 1 and rev 2. These changes harden the
-- shared routing logic for the other two sources and for future
-- releases.
-- ---------------------------------------------------------

USE WAREHOUSE CONCRETE_PIPELINE_WH;
USE DATABASE CONCRETE_PIPELINE;
USE SCHEMA STAGING;

-- ---------------------------------------------------------
-- CREATE OR REPLACE, not CREATE IF NOT EXISTS.
--
-- Why the divergence from the RAW landing scripts: those scripts use
-- IF NOT EXISTS because re-running them must never endanger landed
-- data. A view stores no data, so replacing it costs nothing and
-- destroys nothing -- and transform logic is expected to be iterated
-- on, as this very rebuild demonstrates. IF NOT EXISTS here would
-- silently do nothing on re-run, leaving an edited file and an
-- unchanged view: your SQL and your warehouse disagree, neither errors.
-- ---------------------------------------------------------
CREATE OR REPLACE VIEW STAGING.STG_USGS_MCS_CEMENT
  COMMENT = 'U.S. cement salient statistics from USGS MCS. Casts RAW TEXT to typed values and routes sentinel codes to an explicit flag. Grain: one row per statistic per year (11 x 5 = 55 for the 2026 release).'
AS
-- ---------------------------------------------------------
-- CTE 1: filter to the cement slice, and build one cleaned copy of
-- the value token for classification to work against.
--
-- The cleaning is deliberately split from the parsing so each step is
-- inspectable on its own. value_clean strips whitespace including
-- NBSP; value_normalized (CTE 2) additionally folds the en dash to a
-- hyphen so range detection needs one pattern instead of two.
-- ---------------------------------------------------------
WITH cement_raw AS (
    SELECT
        commodity,
        statistics,
        statistics_detail,
        unit,
        year,
        value,
        source_file,
        loaded_at,

        -- Landed with TRIM_SPACE = FALSE, so whitespace is possible on
        -- either end. TRIM's default character set is the ordinary
        -- space only, so CHR(160) (non-breaking space) and CHR(9)
        -- (tab) are passed explicitly -- this is the fix that recovers
        -- the '68' row.
        TRIM(value, ' ' || CHR(160) || CHR(9)) AS value_clean

    FROM RAW.USGS_MCS_RAW

    -- -----------------------------------------------------
    -- The filter deferred from ingest (Stage 4 decision: land all
    -- 8,886 rows, filter downstream). This is where that deferred
    -- filter actually lives, and being in a view makes it a decision
    -- changeable by editing a query rather than by re-fetching.
    --
    -- CHR(8212) builds the em dash (U+2014) by codepoint instead of
    -- pasting the character into the SQL. The literal works, but a
    -- hyphen here matches ZERO rows and returns an empty result
    -- rather than an error -- and this file is now known to contain
    -- three different dash characters. Building it by codepoint is
    -- immune to copy-paste, editor re-encoding, and visual ambiguity.
    -- -----------------------------------------------------
    WHERE commodity = 'Cement'
      AND section   = 'Salient Statistics' || CHR(8212) || 'United States'
),

-- ---------------------------------------------------------
-- CTE 2: parse once, normalize once.
--
-- The numeric parse is needed by two output columns (the number, and
-- the flag saying whether a number was found), and the normalized
-- token is needed by range detection. Computing each once here beats
-- duplicating the expressions and letting the copies drift apart
-- during editing.
-- ---------------------------------------------------------
cement_parsed AS (
    SELECT
        *,

        -- En dash (U+2013) folded to hyphen for range detection only.
        -- The em dash is left alone -- it is a value, not a separator.
        REPLACE(value_clean, CHR(8211), '-') AS value_normalized,

        -- TRY_TO_DECIMAL, not TO_DECIMAL: TRY_ returns NULL on a value
        -- it cannot parse instead of failing the whole query, which is
        -- the entire point when 1,167 cells file-wide are not numbers.
        --
        -- The (38, 6) is NOT optional decoration. TRY_TO_NUMBER with
        -- default precision/scale uses scale 0, which ROUNDS -- a price
        -- of 127.50 dollars per metric ton would silently land as 128.
        -- Explicit scale prevents a quiet rounding bug in every price
        -- and percentage row.
        --
        -- REPLACE strips the thousands separators ("91,000" -> 91000)
        -- that made FIELD_OPTIONALLY_ENCLOSED_BY necessary at RAW.
        TRY_TO_DECIMAL(REPLACE(value_clean, ',', ''), 38, 6) AS value_parsed

    FROM cement_raw
)
SELECT
    -- Grain-defining columns. Filtered to one commodity, so commodity
    -- is constant here -- kept anyway so a row stays self-describing
    -- when read outside the context of the view's name.
    commodity,
    statistics        AS statistic,
    statistics_detail AS statistic_detail,
    unit,

    -- Year is a clean 4-digit string in every observed row. TRY_ is
    -- used regardless: a malformed year should surface as one NULL
    -- year, not as a failed query returning no cement data at all.
    TRY_TO_NUMBER(TRIM(year, ' ' || CHR(160))) AS year,

    -- -----------------------------------------------------
    -- value_numeric -- the number, where the source asserted one.
    --
    -- The em dash is the only sentinel mapping to a NUMBER rather than
    -- to NULL, because it is the only one that is a measurement: USGS
    -- is asserting the quantity is zero. Routing it to NULL would drop
    -- a real zero out of every AVG, COUNT and MIN downstream -- a
    -- wrong number rather than a missing one.
    --
    -- Bounds ('<1,000') and ranges ('500-17,000') deliberately stay
    -- NULL. A ceiling is not a measurement and neither is a midpoint;
    -- putting a number here guarantees some future SUM treats it as one.
    -- -----------------------------------------------------
    CASE
        WHEN value_clean = CHR(8212) THEN 0
        ELSE value_parsed
    END AS value_numeric,

    -- -----------------------------------------------------
    -- value_flag -- the reason, in plain language, on every row.
    --
    -- This column is the interpretation done ONCE at the boundary.
    -- Without it, every downstream consumer re-implements the
    -- codebook: knowing W means withheld, that NA and XX are
    -- different facts, and that the published metadata documents 6
    -- of the 20+ codes actually present in the file.
    --
    -- Clause order is load-bearing. The numeric test sits above the
    -- code tests so anything parsing cleanly is VALUE, and the codes
    -- are consulted only once parsing has failed.
    --
    -- Clean numbers get 'VALUE' rather than NULL so a NULL in this
    -- column is impossible, which makes GROUP BY value_flag a
    -- complete census: the counts must sum to the row count, or
    -- there is a bug.
    --
    -- UNKNOWN_SENTINEL is the catch-all for a code this mapping has
    -- never seen. It keeps unclassified distinct from unflagged, the
    -- same way withheld is kept distinct from zero, and makes the
    -- arrival of a new code a one-line query rather than a discovery.
    -- -----------------------------------------------------
    CASE
        WHEN value IS NULL                            THEN 'EMPTY'
        WHEN value_clean = ''                         THEN 'EMPTY'
        WHEN value_clean = CHR(8212)                  THEN 'ZERO'
        WHEN value_parsed IS NOT NULL                 THEN 'VALUE'
        WHEN value_clean = 'W'                        THEN 'WITHHELD'
        WHEN value_clean = 'NA'                       THEN 'NOT_AVAILABLE'
        WHEN value_clean = 'XX'                       THEN 'NOT_APPLICABLE'
        WHEN LEFT(value_clean, 1) IN ('>','<')        THEN 'BOUND'
        -- Range: a digit, then a hyphen, then a digit. Tested after
        -- BOUND so a one-sided inequality is never caught here, and
        -- after the numeric test so a negative number is not either.
        WHEN value_normalized RLIKE '^[0-9][0-9,\\. ]*-[ ]*[0-9][0-9,\\.]*$'
                                                      THEN 'RANGE'
        WHEN value_clean IN ('s','E','Large',
                            'Small','Moderate',
                            'Moderate to large',
                            'Very small')             THEN 'QUALIFIER'
        WHEN value_clean ILIKE 'Variable%'            THEN 'QUALIFIER'
        ELSE 'UNKNOWN_SENTINEL'
    END AS value_flag,

    -- The token exactly as landed -- untrimmed, un-normalized, NBSP
    -- and all. value_numeric and value_flag are both derived claims;
    -- this is the receipt. It is what makes a wrong routing rule a
    -- fixable bug instead of a re-fetch.
    value AS value_raw,

    -- Lineage carried through from RAW: which published release this
    -- row came from, and when the pipeline loaded it.
    source_file,
    loaded_at

FROM cement_parsed;


-- =========================================================
-- VERIFICATION -- run these after creating the view
-- =========================================================

-- 1. Grain and row count. Expect 55 for the 2026 release.
--    Confirmed rev 1: 55.
-- SELECT COUNT(*) AS row_count FROM STAGING.STG_USGS_MCS_CEMENT;

-- 2. Rows per year. Expect 11 for each of 2021-2025, no gaps.
-- SELECT year, COUNT(*) AS rows_in_year
--   FROM STAGING.STG_USGS_MCS_CEMENT
--  GROUP BY year
--  ORDER BY year;

-- 3. Flag census. Counts must sum to the row count from check 1.
--    Expect all 55 rows 'VALUE' -- U.S. cement currently contains
--    zero sentinels. Confirmed rev 1: 55 VALUE, one category.
-- SELECT value_flag, COUNT(*) AS rows_with_flag
--   FROM STAGING.STG_USGS_MCS_CEMENT
--  GROUP BY value_flag
--  ORDER BY rows_with_flag DESC;

-- 4. Cast integrity. Expect ZERO rows. A row here means value_flag
--    claims a number was found but value_numeric is empty -- the two
--    CASE expressions disagreeing with each other.
-- SELECT value_raw, value_numeric, value_flag
--   FROM STAGING.STG_USGS_MCS_CEMENT
--  WHERE value_flag = 'VALUE'
--    AND value_numeric IS NULL;

-- 5. Decimal preservation. Confirms the (38, 6) scale is holding --
--    price and percentage rows should retain decimals.
-- SELECT statistic, unit, value_raw, value_numeric
--   FROM STAGING.STG_USGS_MCS_CEMENT
--  WHERE value_raw LIKE '%.%';

-- ---------------------------------------------------------
-- 6. ROUTING LOGIC TEST -- the important one.
--
-- Checks 1-5 run against 55 rows containing no sentinels, so they
-- cannot test the sentinel routing at all; they would pass
-- identically if the entire CASE were broken. This applies the same
-- logic to all 8,886 RAW rows, where the sentinels live.
--
-- Rev 1 baseline: VALUE 7,719 | NOT_AVAILABLE 353 | ZERO 313 |
-- WITHHELD 224 | BOUND 145 | QUALIFIER 91 | UNKNOWN_SENTINEL 33 |
-- NOT_APPLICABLE 8. Total 8,886.
--
-- Rev 2 expectation: UNKNOWN_SENTINEL drops from 33 to 2 (the two
-- '?' tokens), RANGE appears, QUALIFIER gains the three
-- 'Moderate to large' / 'Very small' rows, and VALUE gains 1 (the
-- recovered NBSP row). Total must still be 8,886.
-- ---------------------------------------------------------
-- WITH all_rows AS (
--     SELECT
--         value,
--         TRIM(value, ' ' || CHR(160) || CHR(9)) AS value_clean
--       FROM RAW.USGS_MCS_RAW
-- ),
-- all_parsed AS (
--     SELECT
--         value,
--         value_clean,
--         REPLACE(value_clean, CHR(8211), '-') AS value_normalized,
--         TRY_TO_DECIMAL(REPLACE(value_clean, ',', ''), 38, 6) AS value_parsed
--       FROM all_rows
-- )
-- SELECT
--     CASE
--         WHEN value IS NULL                            THEN 'EMPTY'
--         WHEN value_clean = ''                         THEN 'EMPTY'
--         WHEN value_clean = CHR(8212)                  THEN 'ZERO'
--         WHEN value_parsed IS NOT NULL                 THEN 'VALUE'
--         WHEN value_clean = 'W'                        THEN 'WITHHELD'
--         WHEN value_clean = 'NA'                       THEN 'NOT_AVAILABLE'
--         WHEN value_clean = 'XX'                       THEN 'NOT_APPLICABLE'
--         WHEN LEFT(value_clean, 1) IN ('>','<')        THEN 'BOUND'
--         WHEN value_normalized RLIKE '^[0-9][0-9,\\. ]*-[ ]*[0-9][0-9,\\.]*$'
--                                                       THEN 'RANGE'
--         WHEN value_clean IN ('s','E','Large',
--                             'Small','Moderate',
--                             'Moderate to large',
--                             'Very small')             THEN 'QUALIFIER'
--         WHEN value_clean ILIKE 'Variable%'            THEN 'QUALIFIER'
--         ELSE 'UNKNOWN_SENTINEL'
--     END AS value_flag,
--     COUNT(*) AS rows_with_flag
--   FROM all_parsed
--  GROUP BY 1
--  ORDER BY rows_with_flag DESC;

-- ---------------------------------------------------------
-- 7. Inspect whatever check 6 still cannot classify, with hex.
--    Expect exactly two tokens: '?1' and '?10'.
--
--    HEX_ENCODE is the tool that settled rev 1's mystery rows --
--    '68' looked like a number and was not, because of a trailing
--    NBSP. When a token looks parseable but is not, read the bytes
--    before theorizing.
-- ---------------------------------------------------------
-- WITH all_rows AS (
--     SELECT
--         value,
--         TRIM(value, ' ' || CHR(160) || CHR(9)) AS value_clean
--       FROM RAW.USGS_MCS_RAW
-- )
-- SELECT
--     value_clean                 AS unclassified_token,
--     HEX_ENCODE(value_clean)     AS hex_bytes,
--     LENGTH(value_clean)         AS char_length,
--     COUNT(*)                    AS occurrences
--   FROM all_rows
--  WHERE value IS NOT NULL
--    AND value_clean <> ''
--    AND value_clean <> CHR(8212)
--    AND TRY_TO_DECIMAL(REPLACE(value_clean, ',', ''), 38, 6) IS NULL
--    AND value_clean NOT IN ('W','NA','XX','s','E','Large',
--                            'Small','Moderate',
--                            'Moderate to large','Very small')
--    AND LEFT(value_clean, 1) NOT IN ('>','<')
--    AND value_clean NOT ILIKE 'Variable%'
--    AND REPLACE(value_clean, CHR(8211), '-')
--        NOT RLIKE '^[0-9][0-9,\\. ]*-[ ]*[0-9][0-9,\\.]*$'
--  GROUP BY 1, 2, 3
--  ORDER BY occurrences DESC;