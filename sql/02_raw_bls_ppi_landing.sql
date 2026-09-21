-- =========================================================
-- Concrete & Cement Materials Market Pipeline
-- Stage 4: Prototype -- RAW landing objects for BLS PPI
-- =========================================================
-- What this does, in two sentences: creates a file format that
-- tells Snowflake how to read a JSON file, a named internal stage
-- to hold the BLS API response file, and a RAW table with a single
-- VARIANT column to hold the raw JSON once loaded. This is the
-- landing zone only -- pulling real columns (series_id, date,
-- value) out of that JSON happens later, in STAGING.

USE WAREHOUSE CONCRETE_PIPELINE_WH;
USE DATABASE CONCRETE_PIPELINE;
USE SCHEMA RAW;

-- ---------------------------------------------------------
-- File format: tells COPY INTO / staged queries how to parse
-- the files sitting in the stage. STRIP_OUTER_ARRAY handles the
-- BLS API's response shape (an array of series objects) by
-- unwrapping it so each element can land as its own row.
-- ---------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS RAW.JSON_FORMAT
  TYPE = 'JSON'
  STRIP_OUTER_ARRAY = TRUE
  COMMENT = 'Standard JSON format for raw API landing (BLS, later Census)';

-- ---------------------------------------------------------
-- Internal stage: the landing zone itself. One stage per source
-- keeps lineage obvious -- if something looks wrong, you know
-- immediately which source's files you're looking at.
-- ---------------------------------------------------------
CREATE STAGE IF NOT EXISTS RAW.BLS_PPI_STAGE
  FILE_FORMAT = RAW.JSON_FORMAT
  COMMENT = 'Landing zone for raw BLS PPI API JSON responses';

-- ---------------------------------------------------------
-- Raw table: single VARIANT column holding the untouched JSON
-- per record, plus a load timestamp for lineage/debugging.
-- Minimally processed on purpose -- see data_sources.md.
-- ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS RAW.BLS_PPI_RAW (
  raw_data     VARIANT,
  loaded_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Raw BLS PPI landing table -- untouched JSON per row, typed columns come in STAGING';

-- ---------------------------------------------------------
-- Once you've uploaded a BLS response JSON file into
-- RAW.BLS_PPI_STAGE (via Snowsight's "Upload files to stage"),
-- this loads it into the raw table:
-- ---------------------------------------------------------
-- COPY INTO RAW.BLS_PPI_RAW (raw_data)
--   FROM @RAW.BLS_PPI_STAGE
--   FILE_FORMAT = (FORMAT_NAME = 'RAW.JSON_FORMAT');

-- Sanity check after uploading + running the COPY INTO above:
-- SELECT * FROM RAW.BLS_PPI_RAW LIMIT 10;
