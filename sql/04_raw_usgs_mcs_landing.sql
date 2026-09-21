-- =========================================================
-- Concrete & Cement Materials Market Pipeline
-- Stage 4: Prototype -- RAW landing objects for USGS MCS
-- =========================================================
-- What this does, in two sentences: creates a CSV file format that
-- tells Snowflake how to read the USGS Mineral Commodity Summaries
-- data release, an internal stage to hold the downloaded file, and a
-- RAW table with one TEXT column per source column to hold the file
-- exactly as published. Every column is TEXT on purpose -- the Value
-- column mixes numbers with sentinel codes (W, NA, E, s, XX, and an
-- em dash meaning zero), so typing happens in STAGING, not here.

USE WAREHOUSE CONCRETE_PIPELINE_WH;
USE DATABASE CONCRETE_PIPELINE;
USE SCHEMA RAW;

-- ---------------------------------------------------------
-- File format: CSV, not JSON. RAW.JSON_FORMAT cannot be reused
-- here -- a JSON format has no concept of a header row, quoted
-- fields, or a text encoding, because JSON carries its own
-- structure. A CSV does not, so every one of those has to be
-- declared. Named generically (CSV_FORMAT rather than
-- USGS_CSV_FORMAT) following the same reasoning used for
-- JSON_FORMAT: one format per file SHAPE, not per source.
--
-- Each option below is forced by something verified in the file:
--   SKIP_HEADER               row 1 is column names
--   FIELD_OPTIONALLY_...      values are quoted BECAUSE they contain
--                             thousands separators: "91,000". Without
--                             this, the comma inside the quotes splits
--                             the row and shifts every later column --
--                             silent corruption, not an error.
--   ENCODING                  file is Windows-1252, NOT UTF-8. It holds
--                             5,773 em dash bytes (0x97). Snowflake's
--                             UTF8 default rejects them.
--   NULL_IF = ()              convert NOTHING to NULL. The sentinels
--                             W / NA / E / s / XX / em dash each mean
--                             something different; collapsing them to
--                             NULL at RAW destroys that distinction
--                             permanently. STAGING decides what they mean.
--   TRIM_SPACE = FALSE        land bytes as sent; do not silently edit.
-- ---------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS RAW.CSV_FORMAT
  TYPE = 'CSV'
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  ENCODING = 'WINDOWS1252'
  NULL_IF = ()
  TRIM_SPACE = FALSE
  EMPTY_FIELD_AS_NULL = TRUE
  COMMENT = 'CSV landing format -- header row, quoted fields, Windows-1252, no NULL substitution';

-- ---------------------------------------------------------
-- Internal stage: the landing zone. One stage per source, same
-- as BLS and Census -- if something looks wrong, you know
-- immediately whose file you are looking at.
-- ---------------------------------------------------------
CREATE STAGE IF NOT EXISTS RAW.USGS_MCS_STAGE
  FILE_FORMAT = RAW.CSV_FORMAT
  COMMENT = 'Landing zone for the USGS Mineral Commodity Summaries annual CSV data release';

-- ---------------------------------------------------------
-- Raw table: one TEXT column per source column, in source order,
-- holding all 8,886 published rows -- not just the 55 cement ones.
-- Filtering happens downstream so that a change in the source's
-- commodity or section labels shows up as a visible difference
-- rather than as rows that silently never arrived.
--
-- Column names are snake_cased from the source's spaced names
-- ("MCS chapter", "Is critical mineral 2025"). That renames the
-- container, not the contents -- values land byte-identical.
--
-- is_critical_mineral_2025 is NOT described in the publisher's
-- FGDC metadata file. It exists in the CSV anyway. Landed because
-- RAW's job is to hold what the source sent, documented or not.
--
-- source_file is a deliberate divergence from BLS_PPI_RAW: USGS
-- republishes annually into this same table, so without it there is
-- no way to tell a 2026-release row from a 2027-release row.
-- ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS RAW.USGS_MCS_RAW (
  mcs_chapter                TEXT,
  section                    TEXT,
  commodity                  TEXT,
  country                    TEXT,
  statistics                 TEXT,
  statistics_detail          TEXT,
  unit                       TEXT,
  year                       TEXT,
  value                      TEXT,
  notes                      TEXT,
  is_critical_mineral_2025   TEXT,
  other_notes                TEXT,
  source_file                TEXT,
  loaded_at                  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Raw USGS MCS landing table -- all columns TEXT, full published file, typed columns come in STAGING';

-- ---------------------------------------------------------
-- Once MCS2026_Commodities_Data.csv is uploaded into
-- RAW.USGS_MCS_STAGE (Snowsight -> "Upload files to stage"),
-- this loads it. METADATA$FILENAME is supplied by Snowflake at
-- load time, which is why the column list is explicit here and
-- the SELECT names $1..$12 positionally.
-- ---------------------------------------------------------
-- COPY INTO RAW.USGS_MCS_RAW (
--   mcs_chapter, section, commodity, country, statistics,
--   statistics_detail, unit, year, value, notes,
--   is_critical_mineral_2025, other_notes, source_file
-- )
-- FROM (
--   SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
--          METADATA$FILENAME
--   FROM @RAW.USGS_MCS_STAGE
-- )
-- FILE_FORMAT = (FORMAT_NAME = 'RAW.CSV_FORMAT');

-- ---------------------------------------------------------
-- Verification after loading. Expected results are stated so a
-- wrong answer is recognisable as wrong, rather than just "a number".
-- ---------------------------------------------------------

-- 1. Total rows. Expect 8886.
-- SELECT COUNT(*) FROM RAW.USGS_MCS_RAW;

-- 2. Cement, US salient statistics only. Expect 55.
--    NOTE: the em dash in 'Statistics—United States' is U+2014,
--    not a hyphen. A hyphen here matches zero rows and returns an
--    empty result rather than an error.
-- SELECT COUNT(*)
-- FROM RAW.USGS_MCS_RAW
-- WHERE commodity = 'Cement'
--   AND section   = 'Salient Statistics—United States';

-- 3. Grain check. Expect 11 rows per year, 2021-2025.
-- SELECT year, COUNT(*) AS row_count
-- FROM RAW.USGS_MCS_RAW
-- WHERE commodity = 'Cement'
--   AND section   = 'Salient Statistics—United States'
-- GROUP BY year
-- ORDER BY year;

-- 4. Encoding check -- proves WINDOWS1252 was applied correctly.
--    Expect a single clean em dash, no question marks or diamonds.
-- SELECT DISTINCT section
-- FROM RAW.USGS_MCS_RAW
-- WHERE section ILIKE 'Salient%';

-- 5. Sentinel survival check -- proves NULL_IF = () worked.
--    Expect literal 'W', 'NA', 'E', 's', 'XX' etc., not NULLs.
-- SELECT value, COUNT(*) AS occurrences
-- FROM RAW.USGS_MCS_RAW
-- WHERE TRY_TO_DOUBLE(REPLACE(value, ',', '')) IS NULL
--   AND value IS NOT NULL
-- GROUP BY value
-- ORDER BY occurrences DESC
-- LIMIT 20;CONCRETE_PIPELINE.RAW.USGS_MCS_STAGE