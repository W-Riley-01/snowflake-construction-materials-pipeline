-- =========================================================
-- Concrete & Cement Materials Market Pipeline
-- Stage 4: Prototype -- RAW landing objects for Census VIP
-- =========================================================
-- What this does, in two sentences: creates a named internal stage
-- to hold Census VIP API response files and a RAW table with a
-- single VARIANT column to hold the raw JSON once loaded. Reuses
-- the same RAW.JSON_FORMAT file format already created for BLS,
-- since both sources return JSON in the same shape -- one file
-- format per JSON-shaped source family, not one per table.

USE WAREHOUSE CONCRETE_PIPELINE_WH;
USE DATABASE CONCRETE_PIPELINE;
USE SCHEMA RAW;

-- ---------------------------------------------------------
-- File format: RAW.JSON_FORMAT already exists (created in
-- 02_raw_bls_ppi_landing.sql) and is reused here rather than
-- creating a second, near-identical JSON format. Both BLS and
-- Census APIs return an array of records, so STRIP_OUTER_ARRAY
-- applies the same way to both.
-- ---------------------------------------------------------

-- ---------------------------------------------------------
-- Internal stage: the landing zone for Census VIP files.
-- Kept as its own stage, separate from RAW.BLS_PPI_STAGE, so
-- lineage stays obvious per source -- same reasoning as BLS.
-- ---------------------------------------------------------
CREATE STAGE IF NOT EXISTS RAW.CENSUS_VIP_STAGE
  FILE_FORMAT = RAW.JSON_FORMAT
  COMMENT = 'Landing zone for raw Census VIP API JSON responses';

-- ---------------------------------------------------------
-- Raw table: single VARIANT column holding the untouched JSON
-- per record, plus a load timestamp for lineage/debugging.
-- This table is category-agnostic on purpose -- it will accept
-- rows for Commercial, Power, and the other confirmed categories
-- now, and Highway and Street's rows once that category_code is
-- confirmed, without any structural change to this table.
-- ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS RAW.CENSUS_VIP_RAW (
  raw_data     VARIANT,
  loaded_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Raw Census VIP landing table -- untouched JSON per row, typed columns come in STAGING';

-- ---------------------------------------------------------
-- Once a Census VIP response JSON file has been uploaded into
-- RAW.CENSUS_VIP_STAGE (via the upload script, PUT + COPY INTO,
-- same pattern as BLS -- Snowsight's wizard was already rejected
-- for BLS in Stage 4 Decision 4 and that reasoning applies here
-- too), this loads it into the raw table:
-- ---------------------------------------------------------
-- COPY INTO RAW.CENSUS_VIP_RAW (raw_data)
--   FROM @RAW.CENSUS_VIP_STAGE
--   FILE_FORMAT = (FORMAT_NAME = 'RAW.JSON_FORMAT');

-- Sanity check after uploading + running the COPY INTO above:
-- SELECT * FROM RAW.CENSUS_VIP_RAW LIMIT 10;