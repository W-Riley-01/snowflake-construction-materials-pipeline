-- =========================================================
-- Concrete & Cement Materials Market Pipeline
-- Stage 5: Transform -- MART dimension tables
-- File: sql/06_mart_dimensions.sql
-- =========================================================
-- What this does, in two sentences: creates and populates the three
-- shared dimension tables the fact views join against, with every key
-- value written as an explicit literal so a full rebuild produces
-- identical keys. Dimensions are TABLES (not views) because a
-- surrogate key has to persist to mean anything -- see Stage 5
-- Decision 4.
--
-- Decision log: docs/data_sources.md, Stage 5 Decisions 3-6.
-- Schema design: docs/schema.md (see DIVERGENCES below).
--
-- RUN ORDER: this file must run BEFORE any fact view is queried.
-- Fact views join to these tables; an empty dimension means a fact
-- view returns zero rows.

-- ---------------------------------------------------------
-- DIVERGENCES FROM docs/schema.md -- CONFIRM, then update schema.md
--
-- 1. dim_material gains a `series_id` column (NOT in schema.md).
--    schema.md gives dim_material only `material_name` and
--    `parent_series`. But `parent_series` is 'WPU133' for all six
--    child materials, so it cannot identify which material a BLS row
--    belongs to -- WPU1332 (pipe) and WPU1333 (ready-mix) share it.
--    Without series_id, loading fact_price would have to join on
--    material_name matched against BLS series titles: a string join
--    against publisher-controlled text, which is the exact fragility
--    surrogate keys exist to avoid. series_id is the natural key;
--    material_key remains the surrogate.
--
-- 2. dim_time_annual.time_key holds the YEAR, not an opaque
--    surrogate. A calendar year cannot be renamed, reused or
--    retired, so there is no source instability to insulate against
--    -- the usual reason for a surrogate key does not apply. Time
--    dimensions are the standard exception. Column name stays
--    `time_key` so the ERD and the fact FK naming stay valid.
--    dim_time_monthly will use YYYYMM on the same principle.
--
-- 3. fact_production is NOT a single `production_volume` column.
--    Per Stage 5 Decision 3 its grain is one row per year with a
--    named column per statistic. schema.md still shows the single
--    measure and needs updating. Not built in this file.
-- ---------------------------------------------------------

USE WAREHOUSE CONCRETE_PIPELINE_WH;
USE DATABASE CONCRETE_PIPELINE;
USE SCHEMA MART;

-- ---------------------------------------------------------
-- CREATE OR REPLACE TABLE -- a deliberate divergence from the RAW
-- landing scripts, which use IF NOT EXISTS.
--
-- The RAW scripts use IF NOT EXISTS because re-running them must
-- never endanger landed data that cannot be recovered without
-- re-fetching from a publisher. These dimension tables hold no
-- landed data: every row is a literal written in this file and under
-- version control. Replacing them reproduces exactly the same
-- content, which is the whole point of choosing explicit keys over
-- AUTOINCREMENT. Re-running this file is therefore safe and
-- deterministic.
--
-- The tradeoff being accepted: any row added to these tables by hand
-- outside this file is destroyed on the next run. That is intended --
-- this file is the single source of truth for dimension membership.
--
-- Storage class: permanent tables (the default). Transient tables
-- would skip Fail-safe and cost less, and are arguably correct for
-- content this reproducible -- that decision is still open and is
-- deliberately not taken here. See docs/data_sources.md open items.
-- ---------------------------------------------------------

-- =========================================================
-- dim_time_annual
-- =========================================================
-- Grain: one row per calendar year. time_key IS the year.
-- Covers 2021-2025, the span of the USGS 2026 release. A future
-- release adds rows here; nothing else changes.
CREATE OR REPLACE TABLE MART.dim_time_annual (
    time_key    NUMBER(4,0)  NOT NULL PRIMARY KEY,
    year        NUMBER(4,0)  NOT NULL
)
COMMENT = 'Annual time dimension. time_key holds the calendar year itself, not a surrogate. Deliberately NOT joined to dim_time_monthly -- correlate on the year column instead.';

-- `year` duplicates `time_key` by value. This is deliberate, not an
-- oversight: schema.md defines `year` as the documented cross-grain
-- correlation column shared with dim_time_monthly. Keeping it means a
-- query correlating annual and monthly data references the same
-- column name on both sides, and it survives if the key convention
-- ever changes.
INSERT INTO MART.dim_time_annual (time_key, year) VALUES
    (-1,   -1),      -- unknown member, see note below
    (2021, 2021),
    (2022, 2022),
    (2023, 2023),
    (2024, 2024),
    (2025, 2025);

-- =========================================================
-- dim_material
-- =========================================================
-- Grain: one row per material. CONFORMED dimension -- shared by
-- fact_price (BLS, varies across all 7 series) and fact_production
-- (USGS, currently constant at Cement). That shared join is what
-- makes "BLS cement price index vs. USGS cement production" a query
-- rather than a manual reconciliation.
--
-- All seven BLS series are populated now, though only fact_production
-- is being built in this stage. The set is known, static, and small,
-- and fixing the key literals now means fact_price inherits stable
-- keys rather than renumbering the table later.
CREATE OR REPLACE TABLE MART.dim_material (
    material_key    NUMBER(9,0)   NOT NULL PRIMARY KEY,
    material_name   VARCHAR(100)  NOT NULL,
    series_id       VARCHAR(20),
    parent_series   VARCHAR(20)
)
COMMENT = 'Material dimension, conformed across fact_price and fact_production. material_key is the surrogate; series_id is the BLS natural key. parent_series is NULL for the parent index itself.';

-- material_key 1 is Cement -- the row fact_production references on
-- every one of its rows, and the row that ties USGS production to
-- the BLS WPU1322 cement price index.
--
-- parent_series is NULL for WPU133 because it IS the parent; giving
-- it itself as a parent would make the hierarchy self-referential
-- and break any recursive walk of it.
INSERT INTO MART.dim_material (material_key, material_name, series_id, parent_series) VALUES
    (-1, 'Unknown',                        NULL,      NULL),
    (1,  'Cement',                         'WPU1322', 'WPU133'),
    (2,  'Concrete block and brick',       'WPU1331', 'WPU133'),
    (3,  'Concrete pipe',                  'WPU1332', 'WPU133'),
    (4,  'Ready-mixed concrete',           'WPU1333', 'WPU133'),
    (5,  'Precast concrete products',      'WPU1334', 'WPU133'),
    (6,  'Prestressed concrete products',  'WPU1335', 'WPU133'),
    (7,  'Concrete products',              'WPU133',  NULL);

-- =========================================================
-- dim_source
-- =========================================================
-- Grain: one row per upstream data source. Lineage at the MART
-- layer, the counterpart to source_file / loaded_at at RAW.
CREATE OR REPLACE TABLE MART.dim_source (
    source_key      NUMBER(9,0)   NOT NULL PRIMARY KEY,
    source_name     VARCHAR(100)  NOT NULL
)
COMMENT = 'Source dimension for MART-layer lineage. One row per upstream publisher feed.';

INSERT INTO MART.dim_source (source_key, source_name) VALUES
    (-1, 'Unknown'),
    (1,  'BLS PPI'),
    (2,  'Census VIP'),
    (3,  'USGS MCS');

-- ---------------------------------------------------------
-- THE UNKNOWN MEMBER (key -1) -- why every dimension has one
--
-- Facts are views joining to these tables (Stage 5 Decision 4,
-- hybrid storage). An INNER JOIN with no matching dimension row
-- returns nothing: the fact rows SILENTLY DISAPPEAR. No error, fewer
-- rows, green checkmark -- the same failure family as an ingest-time
-- filter against a renamed label, or a stale CTAS table.
--
-- The -1 row plus a LEFT JOIN in the fact views means an unmatched
-- row lands visibly against 'Unknown' instead of vanishing. Combined
-- with the anti-join check below, a missing dimension member becomes
-- a one-query finding rather than a discovery months later.
--
-- -1 rather than 0 by convention, so it cannot be confused with a
-- legitimate zero-valued key and reads obviously wrong in output.
-- ---------------------------------------------------------

-- ---------------------------------------------------------
-- NOTE ON PRIMARY KEY constraints
--
-- Snowflake ACCEPTS primary key and foreign key constraints but does
-- NOT ENFORCE them (NOT NULL is the exception -- that is enforced).
-- They are metadata: documentation for anyone reading the schema, and
-- hints the query optimizer may use. They will not stop a duplicate
-- key from being inserted.
--
-- This is why verification check 2 below exists. In an enforcing
-- database it would be redundant; here it is the only thing actually
-- checking uniqueness.
-- ---------------------------------------------------------


-- =========================================================
-- VERIFICATION -- run these after this file
-- =========================================================

-- 1. Row counts. Expect 6 / 9 / 4 (each includes its -1 unknown).
-- SELECT 'dim_time_annual' AS table_name, COUNT(*) AS rows FROM MART.dim_time_annual
-- UNION ALL SELECT 'dim_material',  COUNT(*) FROM MART.dim_material
-- UNION ALL SELECT 'dim_source',    COUNT(*) FROM MART.dim_source;

-- 2. Key uniqueness. Expect ZERO rows from all three -- Snowflake
--    does not enforce the PRIMARY KEY declared above, so this is the
--    real check.
-- SELECT 'dim_time_annual' AS table_name, time_key AS key_value, COUNT(*) AS n
--   FROM MART.dim_time_annual GROUP BY time_key HAVING COUNT(*) > 1
-- UNION ALL
-- SELECT 'dim_material', material_key, COUNT(*)
--   FROM MART.dim_material GROUP BY material_key HAVING COUNT(*) > 1
-- UNION ALL
-- SELECT 'dim_source', source_key, COUNT(*)
--   FROM MART.dim_source GROUP BY source_key HAVING COUNT(*) > 1;

-- 3. Unknown member present in all three. Expect 3 rows.
-- SELECT 'dim_time_annual' AS table_name FROM MART.dim_time_annual WHERE time_key = -1
-- UNION ALL SELECT 'dim_material' FROM MART.dim_material WHERE material_key = -1
-- UNION ALL SELECT 'dim_source'   FROM MART.dim_source   WHERE source_key = -1;

-- 4. ANTI-JOIN -- every year present in USGS staging has a
--    dim_time_annual row. Expect ZERO rows. A row here is a missing
--    dimension member, and without the unknown-member guard it would
--    mean silently dropped facts.
-- SELECT DISTINCT s.year
--   FROM STAGING.STG_USGS_MCS_CEMENT s
--   LEFT JOIN MART.dim_time_annual d ON s.year = d.time_key
--  WHERE d.time_key IS NULL;

-- 5. Anti-join for material. Expect ZERO rows. USGS publishes the
--    commodity string 'Cement'; dim_material stores 'Cement'. If a
--    future release renames it, this check is what reports it --
--    which is why the fact view's name join uses a LEFT JOIN onto
--    the -1 unknown member rather than an INNER JOIN.
-- SELECT DISTINCT s.commodity
--   FROM STAGING.STG_USGS_MCS_CEMENT s
--   LEFT JOIN MART.dim_material d ON s.commodity = d.material_name
--  WHERE d.material_key IS NULL;

-- 6. Rebuild determinism. Run this file twice, then run check 1 and
--    check 2 again -- counts and uniqueness must be identical. This
--    is the property explicit literal keys were chosen for, and the
--    one AUTOINCREMENT or a SEQUENCE would NOT give: those derive
--    the value from insertion order and history, so a rebuild can
--    silently reassign material_key 1 to a different material while
--    every fact row still points at key 1.
