-- =========================================================
-- Concrete & Cement Materials Market Pipeline
-- Stage 4: Prototype -- Warehouse / Database / Schema setup
-- =========================================================
-- What this does, in two sentences: creates one compute engine
-- (warehouse), one storage container (database), and three
-- organizational layers inside it (RAW / STAGING / MART schemas)
-- -- the empty structure everything else in the pipeline loads into.
-- Nothing here touches data yet; this is just the building and the
-- kitchen staff, before any ingredients (BLS/Census/USGS data) arrive.

-- ---------------------------------------------------------
-- Warehouse (compute)
-- ---------------------------------------------------------
-- X-Small is the smallest size Snowflake offers -- plenty for a
-- dev-scale pipeline pulling three small public data sources.
-- AUTO_SUSPEND = 60 means it stops billing 60 seconds after your
-- last query; AUTO_RESUME wakes it back up automatically the next
-- time you query, so you never have to manually start/stop it.
CREATE WAREHOUSE IF NOT EXISTS CONCRETE_PIPELINE_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Compute for Concrete & Cement Materials Market Pipeline (portfolio project)';

-- ---------------------------------------------------------
-- Database (storage container)
-- ---------------------------------------------------------
CREATE DATABASE IF NOT EXISTS CONCRETE_PIPELINE
  COMMENT = 'Concrete & Cement Materials Market Pipeline -- BLS PPI, Census VIP, USGS MCS';

-- ---------------------------------------------------------
-- Schemas (the RAW -> STAGING -> MART layers from data_sources.md)
-- ---------------------------------------------------------
-- RAW:     exactly what COPY INTO lands, minimally touched.
-- STAGING: cleaned / typed / validated, still close to source shape.
-- MART:    the actual star schema (fact_price, dim_material, etc.)
--          -- the layer anything doing real analysis should query.
CREATE SCHEMA IF NOT EXISTS CONCRETE_PIPELINE.RAW
  COMMENT = 'Landing zone -- minimally processed data straight from COPY INTO';

CREATE SCHEMA IF NOT EXISTS CONCRETE_PIPELINE.STAGING
  COMMENT = 'Cleaned, typed, validated data -- still close to source shape';

CREATE SCHEMA IF NOT EXISTS CONCRETE_PIPELINE.MART
  COMMENT = 'Star schema -- fact/dim tables ready for real querying';

-- ---------------------------------------------------------
-- Sanity check -- run these after the block above to confirm
-- everything landed where you expect.
-- ---------------------------------------------------------
USE WAREHOUSE CONCRETE_PIPELINE_WH;
USE DATABASE CONCRETE_PIPELINE;
SHOW SCHEMAS IN DATABASE CONCRETE_PIPELINE;
