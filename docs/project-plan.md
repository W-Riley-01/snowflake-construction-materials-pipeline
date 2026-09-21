# Concrete & Cement Materials Market Pipeline — Project Plan

**Goal:** Build a SQL/Snowflake-heavy data integration project that mirrors real materials-industry data work — multiple public sources, different formats and time grains, reconciled into a clean warehouse. Purpose: a portfolio project showcasing integration architecture, data mapping, and monitoring — not a dashboard-first project.

**One-sentence architecture summary:**
> Three public data sources with different formats and time grains land in Snowflake as raw stages, get validated and reshaped through SQL transforms into a clean star schema, and refresh on a schedule — mirroring what materials pricing/demand integration looks like at scale, just with public data instead of internal systems.

---

## Data Sources (scoped to concrete/cement only)

| Source | What it provides | Format | Grain |
|---|---|---|---|
| Census Bureau — Value of Construction Put in Place (VIP) | Construction spend, nonresidential/infrastructure categories where concrete demand concentrates | CSV / API | Monthly, national/regional |
| BLS — Producer Price Index (PPI) | Cement & concrete product pricing series | API (BLS Public Data API) | Monthly, national |
| USGS — Mineral Commodity Summaries | Cement production/consumption | CSV / PDF tables | Annual, state-level |

Note: pull only the concrete/cement-relevant series/categories from each source at ingestion time — don't land the full dataset. Keeps scope tight and makes the filtering logic itself a documented data-mapping decision.

---

## Pipeline Stages (tracked on a 7-stage GitHub Projects board)

### 1. Question
What does cement/concrete pricing and demand look like over time, and how do national spending trends, pricing indices, and production/consumption data relate to each other at different grains?

### 2. Data Discovery
- Confirm exact series/codes needed from each source (BLS series ID for cement/concrete PPI, Census VIP category codes, USGS table sections)
- Document access method per source (API key needed? rate limits? update cadence?)
- Capture this in a `docs/data_sources.md` file — this doubles as your integration documentation artifact

### 3. Data Mapping
- Define how monthly (VIP, PPI) and annual (USGS) grains reconcile — decide: downsample monthly to annual, or keep separate fact tables joined at the year level?
- Define region mapping — VIP/PPI are national, USGS has state-level; decide what level the star schema operates at
- Document these decisions explicitly — grain mismatch is the central architecture problem in this project

### 4. Prototype
- Set up Snowflake trial account, warehouse, database, schema structure (RAW → STAGING → MART)
- Land one source (start with BLS PPI — cleanest API) via a Snowflake stage + `COPY INTO`
- Confirm raw ingestion works end to end before adding sources 2 and 3

### 5. Test/Calibrate
- Validate row counts, null handling, date parsing per source
- Build the transform SQL (CTEs, window functions for period-over-period change) from RAW → STAGING → MART
- Spot-check the star schema against source data manually for a couple of known periods

### 6. Iterate
- Add Streams + Tasks for scheduled incremental refresh (monitoring integration jobs)
- Add lightweight RBAC (role separation between raw/staging/mart access) — governance signal
- Decide if a thin Streamlit or dashboard layer is worth adding (secondary priority — the pipeline is the story)

### 7. Deploy
- Public GitHub repo with a README covering what it does, the architecture, and what was learned
- GitHub Projects board mirroring this plan, kept current and visible

---

## Snowflake Features to Use Deliberately

- **Stages + COPY INTO** — raw ingestion story
- **Streams + Tasks** — incremental refresh / monitoring story
- **Views vs. materialized tables** — cost/performance tradeoff awareness
- **Role-based access (RBAC)** — governance/compliance signal

## Target Schema (draft — refine during Data Mapping stage)

**Fact table:** `fact_material_price_volume`
- date_key, region_key, material_key, source_key, price_index, spend_amount, production_volume

**Dimension tables:**
- `dim_material` (cement, ready-mix concrete, etc.)
- `dim_region` (national / state, depending on Data Mapping decision)
- `dim_time` (month, quarter, year — supports both monthly and annual grains)
- `dim_source` (VIP, PPI, USGS — tracks lineage per record)

---

## Working Notes
- One stage at a time — don't start ingestion until Data Mapping decisions are documented
- Full-file rebuilds preferred over patches when iterating on transform SQL
- Tie each new SQL/Snowflake concept back to why it's being used, not just how — this is now data-engineering-focused, not AWS cert–focused
