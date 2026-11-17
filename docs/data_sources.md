# Data Sources — Concrete & Cement Materials Market Pipeline

**Stage:** 6 — BI layer (Stages 2–5 complete)
**Status:** All three sources run end to end, RAW → STAGING → MART. What remains
is verification and documentation; see "Open items carried forward" at the end.
**Last updated:** 2026-11-17

This document captures exact access method, identifiers, and cadence for each of
the three sources feeding the pipeline. It is the integration documentation
artifact referenced in the project plan, and doubles as the decision log for
every stage.

**Convention for every decision entry:** what was chosen, what was rejected, why,
and the cost accepted. An entry without a rejected alternative is not finished.

---

## 1. BLS — Producer Price Index (PPI)

**What it provides:** Monthly pricing indices for cement and concrete products.

**Access method:** BLS Public Data API v2 (registered, not v1/anonymous)
**Endpoint:** `https://api.bls.gov/publicAPI/v2/timeseries/data/`
**Why v2 over v1:** v2 unlocks the series metadata catalog — series descriptions,
units, and survey info returned by the API itself rather than hardcoded from
documentation. For a project centered on lineage and documentation, having the
source system self-describe its own data is a meaningfully stronger design
posture than copy-pasting labels from a webpage. v2 also raises daily query
limits (500 vs. 25) and allows up to 20 years of history per call vs. 10, though
volume was not the deciding factor here.

**Series selected** (full `WPU133` "Concrete products" family — chosen
deliberately over a narrower Cement + Ready-mix-only set, to allow
within-category divergence analysis, e.g. input cement costs vs. finished precast
product costs):

| Series ID | Description | Level |
|---|---|---|
| `WPU133` | Concrete products (parent index) | Category |
| `WPU1322` | Cement | Item |
| `WPU1331` | Concrete block and brick | Item |
| `WPU1332` | Concrete pipe | Item |
| `WPU1333` | Ready-mixed concrete | Item |
| `WPU1334` | Precast concrete products | Item |
| `WPU1335` | Prestressed concrete products | Item |

**Cadence:** Monthly.

**Key management:** API key registered under an individual/independent-project
account (not affiliated with an employer — this is a self-directed learning
project). Key must **not** be hardcoded into any SQL/config committed to the
public repo; stored in a gitignored `.env` and read at runtime.

---

## 2. Census Bureau — Value of Construction Put in Place (VIP)

**What it provides:** Monthly estimates of construction spending, broken into
categories by construction type. Used as a proxy for where concrete demand
concentrates, since VIP has no line item literally called "concrete."

**Access method:** Census Data API (timeseries), registration key **required** as
of May 12, 2026 — no longer optional/anonymous access.
**Endpoint:** `https://api.census.gov/data/timeseries/eits/vip`

**Categories selected** (chosen over "Nonresidential Total" as a single lump
category, to preserve a defensible, documented filtering rationale rather than an
arbitrary broad pull):

| Category | Rationale | Landed? |
|---|---|---|
| Commercial | Meaningful concrete share (foundations, slabs) | Yes |
| Manufacturing | Heavy foundation/slab work, concrete-intensive | Yes |
| Power | Plant foundations, cooling structures | Yes |
| Highway and Street | Pavement — inherently concrete/asphalt-intensive | **No — code unresolved** |

**Cadence:** Monthly, but released on the first working day of the month, **two
months after** the reference month. Any scheduled refresh needs to account for
this lag, not assume same-month availability.

Note this also makes VIP a **late-arriving and revised** source: prior months are
restated after initial publication. `fact_spend` will eventually have to decide
whether to restate history or hold the first-published figure.

**Geography:** National, monthly. State-level breakdowns exist only annually, and
only for select categories — not used in this pipeline (national grain only,
consistent with BLS and the USGS finding below).

**Open item — `category_code` values. See Open Items #1.** The literal
`category_code` strings the API expects were not resolvable from Census's public
metadata endpoints (`variables.json`, `groups.json` return no enumerated value
list for this field). They were inferred empirically, and Census has since
supplied information that **contradicts** part of that inference. Unresolved.

---

## 3. USGS — Mineral Commodity Summaries (Cement)

**What it provides:** Annual U.S. cement production/consumption salient
statistics.

**Access method:** Static file download, no authentication, no API key. Published
as a structured **Data Release** (CSV + FGDC metadata) via ScienceBase, CC0
public domain license — better format than the PDF-table-scraping originally
assumed in the project plan.
**Source:** USGS National Minerals Information Center, annual Mineral Commodity
Summaries Data Release.
**Parent DOI:** `10.5066/P1WKQ63T` — note this is a *container* item and holds no
data files. Files hang off its child items.
**Child item used:** "Commodity Salient U.S. and World Statistics"
(`69837e43b66b01367d7ec7c7`). The sibling child item holds the report's figure
CSVs (Fig1–Fig13) — chart-backing data, not a source.

### Structure — CORRECTED at Stage 4

**The Stage 2 finding that this release contains "exactly two tables — Salient
Statistics and World Production" is wrong for the 2026 release and has been
superseded.**

The 2026 release (published 2026-02-06, covering CY2025) ships **one combined
CSV**, `MCS2026_Commodities_Data.csv`, ~3.0 MB, 8,886 data rows covering 90+
commodities and years 2021–2025. What were separate table files in older editions
are now values in a `Section` column within the single file.

`Section` carries **22 distinct values**, not two. `Salient Statistics—United
States` (4,863 rows) is the U.S. slice; the remaining 21 are heterogeneous
per-commodity world labels (`World Production and Capacity`, `World Mine
Production and Reserves`, `World Lime Production and Limestone Reserves`, etc.).
**Filter *for* the U.S. string; do not attempt to exclude the world variants.**

Note the string contains an **em dash** (U+2014), not a hyphen. A hyphen matches
zero rows and returns an empty result rather than an error.

### Columns — metadata disagrees with the file

The published FGDC metadata (`MCS2026_Commodities_Data.xml`) declares **11**
columns. The CSV has **12**. The undocumented one is `Is critical mineral 2025`
(`Yes`/`No`).

The metadata also names its subject file as `MCS2026_ALLchapters_Reconcile.csv` —
not the filename actually published.

**Lesson recorded:** for a self-describing format (JSON), field names travel
inside the payload and cannot disagree with it. For CSV, the schema is a separate
artifact that can and does drift from the file it describes. Treat publisher
metadata as a hint; treat the file as authoritative.

| # | Column | Notes |
|---|---|---|
| 1 | `MCS chapter` | Upper-case commodity chapter, e.g. `CEMENT` |
| 2 | `Section` | 22 values; U.S. slice is `Salient Statistics—United States` |
| 3 | `Commodity` | Cement's exact string is `Cement` |
| 4 | `Country` | |
| 5 | `Statistics` | Production, Import, Export, Shipment, Consumption, Price, Stock, Employment, Net import reliance |
| 6 | `Statistics_detail` | Sub-detail, e.g. `Production: Clinker` |
| 7 | `Unit` | thousand metric tons / dollars per metric ton / number / percent |
| 8 | `Year` | 2021–2025 |
| 9 | `Value` | **Mixed numeric and sentinel — see Stage 4 Decision 2 and Stage 5 Decision 2** |
| 10 | `Notes` | |
| 11 | `Is critical mineral 2025` | **Undocumented in publisher metadata** |
| 12 | `Other notes` | |

### Shape

**Long format** — one row per commodity per statistic per year, with `Year` and
`Value` as their own columns. This is already the shape `fact_production`
requires; no unpivot is needed in STAGING.

Had the release been pivoted the other way (a column per year), each annual
release would add a column and break the landing table. Recorded as a favourable
finding, not an assumption to rely on for future releases.

**Cement scope:** filtered to `Commodity = 'Cement'` and `Section = 'Salient
Statistics—United States'` yields **55 rows** — 11 statistics × 5 years, no gaps.

### Encoding

The file is **Windows-1252**, not UTF-8. It contains 5,773 `0x97` bytes (em dash).
Attempting a UTF-8 read fails at the first one. Snowflake's CSV file format
defaults to `ENCODING = 'UTF8'`, so `ENCODING = 'WINDOWS1252'` must be set
explicitly.

**Amended at Stage 5:** the file is not cleanly Windows-1252 either. At least one
cell contains a non-breaking space as *UTF-8* bytes (`C2 A0`) in a file declared
Windows-1252, where `A0` alone is already an NBSP. The publisher mixed encodings
within one file. See Stage 5 Decision 2.

### Sentinel values in `Value`

The publisher metadata enumerates six: `XX` (not applicable), `W` (withheld —
would reveal individual company data), `s` (small), `NA` (not available), `E`
(net exporter), and an em dash meaning zero.

**The actual file contains far more than the metadata declares.** The complete
set, established empirically at Stage 5, is catalogued in **Stage 5 Decision 2**.
Headline figures: **1,166 of 8,886 rows** carry a `Value` that is not directly
castable, across **nine** distinct handling categories.

Numeric values additionally carry **thousands separators** inside quoted fields
(`"91,000"`), so even clean rows are not directly castable.

**U.S. cement rows currently contain zero sentinels.** This is a property of the
2026 release, not a guarantee — see Stage 4 Decision 2.

**Cadence:** Annual. Released ~January/February of the year following the
reference year.

### Geography — confirmed finding, differs from original plan assumption

The project plan assumed USGS would provide state-level grain. Confirmed: the
structured data release is **national-level only**. State-by-state figures exist
only as narrative prose within the PDF commodity chapter, not as a joinable table.

**Decision — state-level sourcing rejected:** Individual states do sometimes
publish their own mineral production data, but with no standardized format,
cadence, or access method across states — pursuing this would mean repeating full
Data Discovery per state for marginal benefit. Rejected as scope creep
disproportionate to the project's goal of demonstrating integration architecture
in general. **USGS is treated as national-grain only**, same as BLS and Census.

---

## Summary

| Source | Format | Access | Cadence | Grain | RAW | STAGING | MART |
|---|---|---|---|---|---|---|---|
| BLS PPI | REST API (JSON) | v2 key (registered) | Monthly | National | ✓ 7 rows | — | — |
| Census VIP | REST API (JSON) | Key required (registered) | Monthly, 2-mo. lag | National | ✓ 378 rows (3 of 4 categories) | — | — |
| USGS MCS | CSV data release | Public download, no key | Annual | National | ✓ 8,886 rows | ✓ 55 rows | ✓ 5 rows (`fact_production`) |

---

## Stage 3 — Data Mapping Decisions

**Status:** Grain and fact-table structure locked.

### Decision 1 — Grain reconciliation

**Chosen:** Native-grain fact tables. BLS and Census stay at their real monthly
grain; USGS stays at its real annual grain. Sources are joined at the year level
only where a query genuinely needs both, rather than forcing everything into one
shared grain.

**Rejected alternative:** Downsampling everything to annual (or worse, stretching
USGS's annual figures down into fabricated monthly rows). Rejected because it
would mean inventing detail no source actually measured — e.g. repeating one
annual production number across 12 fake "monthly" rows, which looks precise but
isn't real, and silently breaks aggregate queries (SUM/AVG) run against it.

**Cost accepted:** Anyone querying across sources has to know the separate tables
exist and explicitly join them by year — nothing does that automatically. This is
the direct tradeoff for never fabricating a number a source didn't produce.

### Decision 2 — Fact table structure

**Chosen:** Three fact tables, split by *what is actually measured*, not by source
or by cadence alone:
- Price (BLS PPI — price index per material)
- Spend (Census VIP — construction dollar spend per category)
- Production (USGS MCS — cement production/consumption volume)

**Rejected alternatives:**
- One fact table for everything — rejected before this point, since it can't
  honestly hold three different grains and three different kinds of measurement
  in one row.
- Two fact tables split purely by grain (one monthly table holding both BLS price
  *and* Census spend, one annual table for USGS) — rejected because BLS and
  Census, despite sharing a monthly cadence, measure genuinely different things
  (a price index is not a dollar amount). Grouping them by schedule alone would
  hide that difference.

**Rationale:** Splitting by what's measured means each table has a single clear
meaning, and an ingestion failure in one source is isolated and immediately
identifiable rather than buried in a shared table. The named cost: any question
spanning all three measurements requires two joins instead of one, and whoever
queries this has to know all three tables exist. Accepted as reasonable at three
tables; explicitly noted as a pattern that would need revisiting if the source
count grew much further — more sources means more joins and more for a querying
person to hold in their head, a scaling cost rather than a one-time one.

### Decision 3 — Region dimension

**Chosen:** No `dim_region` table. Dropped entirely rather than kept as a
placeholder.

**Why:** Confirmed during Data Discovery that all three sources are
national-level only — USGS's structured data release does not include a usable
state-level table (see Section 3). With no source varying by region, a region
dimension has nothing to slice by, so it isn't a real dimension — it's an empty
placeholder. This is a constraint-driven decision, not a preference between
national and state.

**Note for later:** If a future source is added that does carry regional detail,
`dim_region` can be introduced at that point — not built in advance for a need
that doesn't yet exist.

### Decision 4 — Census spend category as a degenerate dimension

**Chosen:** No separate `dim_construction_category` table. The four selected VIP
categories are stored as an attribute directly on `fact_spend` — a **degenerate
dimension**.

**Why:** A dimension table earns its place when there's enough descriptive detail,
or enough reuse across multiple fact tables, to justify a separate table with its
own key — the way `dim_material` is shared by both `fact_price` and
`fact_production`. Here there are only four fixed values, they don't change over
time, and no other fact table needs to reference them. Building a table for four
static labels adds a join without adding real value.

**Cost accepted:** If Census's category list grows or needs its own hierarchy
later, this would need to be revisited and split into a real dimension table.
Acceptable now given the fixed, small, stable set.

---

## Stage 4 — Prototype Decisions

> Entries are numbered per source (BLS, Census, USGS) rather than globally, so
> no renumbering is needed as sources are added. BLS Decisions 1–3 were written
> up after the fact from `02_raw_bls_ppi_landing.sql`; the original notes were
> not kept.

### BLS Decision 1 — Land raw JSON into a single `VARIANT` column
*Written retrospectively from `02_raw_bls_ppi_landing.sql`.*

**Chosen:** `RAW.BLS_PPI_RAW` holds one `VARIANT` column (`raw_data`) plus
`loaded_at`. Each JSON record lands untouched.

**Rejected alternative:** Extract typed columns (`series_id`, period, `value`) at
the landing table.

**Why:** RAW is the landing zone only — minimally processed on purpose. A
`VARIANT` column makes no claims about the payload's structure and accepts
whatever shape arrives, so a change in the API response cannot fail the load.
Extracting fields happens in STAGING, where a structural surprise surfaces as a
visible transform problem instead of an ingestion failure. This is the same
fidelity-over-correctness principle later applied to the USGS CSV as
TEXT columns (USGS Decision 2).

**Cost accepted:** every consumer must use path notation and `FLATTEN` to get at
the data. That work lands in the BLS STAGING view.

### BLS Decision 2 — One named internal stage per source
*Written retrospectively from `02_raw_bls_ppi_landing.sql`.*

**Chosen:** `RAW.BLS_PPI_STAGE` is dedicated to BLS. Census and USGS each get
their own stage.

**Rejected alternative:** One shared stage with a subfolder per source.

**Why:** lineage stays obvious — if something in a stage looks wrong, the stage
name alone identifies whose file it is. Consistent with Stage 3 Decision 2's
principle of isolating each source so a failure is attributable.

**Cost accepted:** one additional Snowflake object per source.

### BLS Decision 3 — API key held in local `.env`, not a Snowflake `SECRET`
*Written retrospectively.*

**Chosen:** `BLS_API_KEY` (and later `CENSUS_API_KEY`) is stored in a gitignored
`.env` and read by the fetch script through `python-dotenv`. `.env.example`
documents the required variables with placeholder values.

**Rejected alternative:** a Snowflake `SECRET` object — which was the **Stage 2
plan** (see the original BLS key-management note).

**Why the plan changed:** the BLS API is called by a Python script running
locally, not by Snowflake. A Snowflake `SECRET` holds credentials that Snowflake
itself uses — calling an external API from *inside* Snowflake would additionally
require an External Access Integration and a procedure or UDF to make the call.
That is a different ingestion architecture, not a different place to keep a key.
The credential lives with the process that consumes it.

**Cost accepted:** the key's protection depends on `.gitignore` and local
filesystem hygiene rather than Snowflake's access controls. Verified: `git
check-ignore -v .env` matches `.gitignore:2`; `.env.example` is not ignored.

### BLS Decision 4 — Upload via local `PUT` + `COPY INTO`, not Snowsight's Load Data wizard
**Chosen:** A local Python script (`snowflake-connector-python`) runs `PUT` to
place the fetched file in `RAW.BLS_PPI_STAGE`, then `COPY INTO` to load it.

**Rejected alternative:** Snowsight's browser-based **"Load Data into Table"**
wizard.

**Why:** the wizard's own "Show SQL" output revealed two problems. It uploads
into a hidden, Snowsight-managed temporary stage rather than the named stage —
so the stage designed as the landing archive would stay empty. And it explicitly
writes `null` into `loaded_at` rather than leaving the column to its
`DEFAULT CURRENT_TIMESTAMP()`, silently destroying the lineage timestamp.

**Scope of the rejection — clarified at USGS:** this rules out *Load Data into
Table*, which bypasses the stage. It does not rule out Snowsight's
**Ingestion → Add Data → Load files into a stage**, which writes to the named
stage and leaves the `COPY INTO` to be run separately. The USGS file was staged
that way, correctly.

**Cost accepted:** a Python dependency and Snowflake credentials in `.env`.
**Superseded in part** by Census Decision 4 — the per-source script this produced
was replaced by a generalized one.

**Verified:** 7 rows in `RAW.BLS_PPI_RAW`, real JSON, real `loaded_at` timestamps.

### Census Decision 1 — `category_code` values resolved empirically
**Background:** VIP's `/variables.html` metadata endpoint does not enumerate
`category_code`'s valid values — confirmed at Stage 2 and again at Stage 4 by
checking the same endpoint pattern across several sibling EITS datasets, none of
which expose an enumerated list for this field. The codes had to be resolved
against live API responses.

**Method:** queried VIP with no `category_code` filter to enumerate every value
in use (38, including `00XX`–`15XX`, `20IX`, `A`-prefixed annual duplicates, and
aggregate totals). Cross-referenced each code's dollar values — and, critically,
its **month-to-month seasonal swing shape** — against Census's published press
release tables (`pr202412.pdf`, `pr202409.pdf`, Table 2, not seasonally
adjusted) for two months with deliberately different seasonal profiles. Matching
on swing shape rather than single-month magnitude was necessary because several
categories cluster in similar dollar ranges.

**Codes as logged on 2026-08-31:**

| category_code | Category | Confidence as logged | Status after 2026-09-09 |
|---|---|---|---|
| `20IX` | Manufacturing | High — 0.4% deviation | Unchallenged |
| `00XX` | Residential | High — 1.4% deviation | Unchallenged |
| `03XX` | **Commercial** | High — swing +11.7% live vs. +11.3% published | Unchallenged |
| `11XX` | **Power** | High — swing +2.5% vs. +1.2%, both near-flat | Unchallenged |
| `07XX` | Public safety | High | Unchallenged |
| `08XX` | Sewage and waste disposal | High | Unchallenged |
| `09XX` | Transportation | High | Unchallenged |
| `10XX` | Communication | High | Unchallenged |
| `12XX` | Office | High | **CONTRADICTED** — Census indicates Highway and Street |
| `15XX` | Conservation and development | High | Unchallenged |
| `05XX` | Educational | Moderate | Unchallenged |

**Highway and Street — unresolved at the time.** `02XX` matched on December
magnitude, but its live seasonal swing (+3.3%) flatly contradicted Highway's
well-documented swing of roughly 80% between winter and fall (8,361 in December
2024 vs. 15,191 in September 2024). No candidate reproduced it.

**Rejected alternative:** keep testing candidate codes by trial and error.
Rejected because every remaining candidate would have been selected the same way
the wrong ones were — by magnitude proximity — repeating the exact error the
method existed to avoid.

The call at the time: this is a project rather than a live production
database, the problem is identified, so use what is confirmed, send an inquiry,
and move forward.

**Cost accepted:** Highway and Street not landed. Inquiry sent to Census's
Economic Indicator Division.

**AMENDMENT, 2026-09-09 — two sources now conflict.** Census replied indicating
`02XX` is Office and `12XX` is Highway and Street. That contradicts a code logged
above at *High* confidence. **Which one is wrong is not yet known**, and the
evidence does not favour the reply as much as its authority suggests:

- `12XX` was matched to Office because its **live values tracked Office's
  published figures** — under 5% deviation, with a consistent swing across two
  months. If `12XX` actually carried Highway and Street's data, it would show
  Highway's roughly 80% winter-to-fall swing and could not have matched Office.
  The observed behaviour of the series itself contradicts the reply.
- Likewise `02XX` showed a +3.3% swing — inconsistent with Highway, but also
  something to check against Office's published profile.
- The reply was phrased "it looks like," which reads as a support reading of the
  same API rather than a lookup in an internal code table.

Possible explanations, none yet tested: the reply is mistaken; the API's codes
do not map one-to-one onto the press-release categories; or the 2026-08-31
cross-reference contained an error. **Resolving it requires the authoritative
dataset, not a choice between the email and the empirical work.**

What this does establish regardless of outcome: the "High" confidence ratings
above were confidence in a method, not verification against a source of record.
They should be read that way until checked.

The three categories actually landed — Commercial `03XX`, Manufacturing `20IX`,
Power `11XX` — are not directly named in the reply. Verification against the
zipped dataset is still required before relying on any of them. See Open Items #1.

### Census Decision 2 — Build landing objects now; ingest incrementally
**Chosen:** create `RAW.CENSUS_VIP_STAGE` and `RAW.CENSUS_VIP_RAW` immediately.
Fetch and load the three confirmed categories now; load Highway and Street as a
second, incremental load once its code is confirmed.

**Rejected alternative:** wait until all four category codes are confirmed before
creating any landing objects.

**How the decision was reached:** my first instinct was to wait, until I noticed
the ingestion itself could happen later. Those turned out to be two separate
decisions. The landing objects make no claims about content — a `VARIANT` table
accepts three categories or forty without structural change. The category codes
only matter in the **fetch script**, where specific values must be named. So the
infrastructure is safe to build now, and only ingestion is blocked.

**Cost accepted:** Highway and Street arrives in a later load rather than with
the other three. Normal for API-sourced pipelines: landing infrastructure is not
rebuilt each time a new batch arrives.

**Verified:** 378 rows in `RAW.CENSUS_VIP_RAW` — 126 monthly rows each for
Commercial, Power, and Manufacturing (about 10.5 years, matching the
`current_year - 10` fetch window).

### Census Decision 3 — Share `RAW.JSON_FORMAT` across JSON sources
**Chosen:** `RAW.JSON_FORMAT` (created for BLS) is reused for Census rather than
creating a separate `RAW.CENSUS_JSON_FORMAT`.

**Rejected alternative:** a dedicated file format per source, matching the
dedicated-stage and dedicated-table pattern.

**Why:** a file format governs *parsing behaviour* — how to
read bytes into rows — not source data. It never interacts with any source's
data, so sharing it does not violate Stage 3 Decision 2's source-isolation
principle, which exists to keep different sources' *data* from mixing. Shared
keeps parsing behaviour consistent across the project.

**Cost accepted:** a future JSON source needing different parsing options (not
array-wrapped, different compression) would require `RAW.JSON_FORMAT` to branch,
or that source to get its own format then. The decision defers that; it does not
prevent it.

**Carried forward to USGS:** the same principle produced `RAW.CSV_FORMAT` —
named by file *shape*, not by source.

### Census Decision 4 — One generalized upload script, not one per source
**Chosen:** `upload_to_snowflake.py` takes the source name as an argument and
looks up that source's data directory, stage, and table from a small config map.
Replaces `upload_bls_to_snowflake.py`.

**Rejected alternative:** copy the BLS script to `upload_census_vip_to_snowflake.py`
with three constants swapped, matching the existing per-source `fetch_*.py`
pattern.

**Why:** I didn't want a fourth near-duplicate
file. The script was almost entirely generic — connect, `PUT`, `COPY INTO`,
count. Only `DATA_DIR`, `STAGE`, and `TABLE` differed between sources.

**Cost accepted:** one script now carries a source-config map, so a source with
genuinely different upload needs would have to branch inside it. Fetch scripts
stay per-source, since they genuinely differ.

### Census — API behaviours discovered at Stage 4 (findings, not decisions)

Recorded because each cost real time and none is documented where you would look.

- **Authentication failure returns HTTP 200 with an HTML "Invalid Key" page**,
  not a 401 or 403. `raise_for_status()` does not catch it; the response body
  has to be inspected. This is the failure that later produced the payload guard
  in `fetch_usgs_mcs.py`.
- **`time_slot_id` is a required predicate** and must appear in the `get=`
  list. Omitting it returns a 400.
- **`time` is predicate-only** — it must not appear in `get=`; Census returns it
  automatically.
- **One `category_code` per request.** No comma-separated list, so the fetch
  script loops. This is why Census filters at ingest — a constraint the API
  imposes, and the precedent cited in USGS Decision 3.
- **`seasonally_adj=yes` returns HTTP 204** at the individual category level.
  Only not-seasonally-adjusted data is available per category.
- **`program_code`** returns only the dataset abbreviation (`VIP`), not a
  category label — a hypothesis tested and disproven.
- **Working-directory path bug**, found in *both* fetch scripts: a bare relative
  `OUTPUT_DIR` resolved against wherever the script was launched from, silently
  creating duplicate nested data folders. Fixed by anchoring paths on `__file__`.


### USGS Decision 1 — Ingest sequencing: inspect the file before writing landing SQL

**Chosen:** Download and profile the source file first, then write the RAW
landing SQL to match what is actually in it.

**Rejected alternative:** Write the landing SQL first, then fetch to match — the
order used for both BLS and Census.

**Why the order changed:** BLS and Census land into a `VARIANT` column, which
makes no claims about the data's structure and accepts whatever shape arrives.
SQL-first was never a principle; it was a property JSON handed over for free. A
CSV landing table makes explicit claims — column count, order, names, types — and
writing those from a *description* of the file rather than the file itself is
guessing.

**Vindicated immediately:** the pre-existing Stage 2 documentation described two
separate table files and the publisher metadata declared 11 columns. The actual
2026 release is one combined file with 12 columns. SQL written first would have
been written against a structure that no longer exists.

**Cost accepted:** the authoring order for this source diverges from the other
two. Judged not to matter — the operational pattern (RAW landing objects → fetch
script → stage upload → `COPY INTO` → verify) is identical across all three, and
the order in which two files were authored is invisible in the finished repo.

### USGS Decision 2 — All RAW columns typed as TEXT

**Chosen:** Every column in `RAW.USGS_MCS_RAW` is `TEXT`, including `Value` and
`Year`. Typing and casting happen in the RAW → STAGING transform.

**Rejected alternative:** Type `Value` as `NUMBER` and `Year` as `INTEGER` at the
landing table.

**Why:** The RAW layer's job is **fidelity, not correctness** — a faithful,
immutable copy of what the source sent, so that everything downstream can be
rebuilt from it without re-fetching. A typed `COPY INTO` is a validating gate at
the ingest point: a single `W` in a single cell rejects the load, leaving *no*
data rather than imperfect data, and no landed file to diff against.

The `Value` column mixes numbers, over a thousand sentinel values across many
distinct forms (only six of which are documented), and thousands separators.
Typing it at RAW makes an unattended annual load depend on USGS's formatting
choices never changing.

**What is lost, not merely deferred, if this goes the other way:** with a numeric
column, `W` (withheld — the figure exists and is hidden), `NA` (never collected)
and the em dash (a real zero) all become the same NULL. The distinction is
destroyed at parse time, so the table cannot report which NULLs were which, and
the repair cannot even be scoped. Recovery requires the original bytes, which
means re-fetching a publication USGS reissues annually. If the stage were
cleared, that release would be gone.

**The trap worth recording:** U.S. cement rows in the 2026 release contain *zero*
sentinels. Profiling only the filtered slice would support the conclusion that a
numeric column is safe. It is not — USGS withholds figures that would expose a
single company, and a `W` appearing in a cement production cell in a future
release is entirely ordinary. The typed alternative would break on a schedule,
unattended, for reasons unrelated to any code change.

**Related file format choices, all forced by the file:**

| Option | Reason |
|---|---|
| `SKIP_HEADER = 1` | Row 1 is column names |
| `FIELD_OPTIONALLY_ENCLOSED_BY = '"'` | Values are quoted *because* they contain thousands separators (`"91,000"`). Without this the inner comma splits the row and shifts every later column — **silent corruption, not an error** |
| `ENCODING = 'WINDOWS1252'` | File is not UTF-8; 5,773 em dash bytes would fail a UTF-8 read |
| `NULL_IF = ()` | Convert **nothing** to NULL. `W`, `NA`, `E`, `s`, `XX` and em-dash-as-zero each mean something different; collapsing them to NULL at RAW destroys that distinction permanently |
| `TRIM_SPACE = FALSE` | Land bytes as sent |

**Correction to this table, found at Stage 5:** `NULL_IF = ()` does **not** mean
"convert nothing to NULL." A separate option, `EMPTY_FIELD_AS_NULL`, defaults to
`TRUE` and converts empty unquoted fields to NULL independently of `NULL_IF`. The
claim above is therefore overstated. Verified at Stage 5 to have no practical
impact here — the `Value` column contains no empty cells in this release — but
the STAGING view carries an `EMPTY` flag as a guard for future releases.

**Cost accepted:** every downstream consumer must cast explicitly, and the cast
must handle comma-stripping and sentinel routing. That work is real, but it lives
in STAGING where a bad value surfaces as a visible data-quality finding rather
than an ingestion outage.

**Column naming note:** source column names contain spaces (`MCS chapter`, `Is
critical mineral 2025`) and were snake_cased in the landing table. This renames
the *container*, not the *contents* — landed values are byte-identical to the
published file. RAW's immutability promise is about content.

### USGS Decision 3 — Land the full published file; filter downstream

**Chosen:** All 8,886 published rows land in `RAW.USGS_MCS_RAW`. Cement filtering
happens in the RAW → STAGING transform.

**Rejected alternative:** Filter to the 55 U.S. cement rows in the fetch script,
so RAW holds cement only. This was the initial pick, on the reasoning that the
other rows aren't needed and that filtering early would help future releases.

**Why it was reversed:** the future-release argument runs backwards. If a
subsequent release renames the commodity string, splits `Cement` into subtypes,
or alters the section label, an ingest-time filter matches fewer rows, writes a
smaller file, and **the load succeeds**. Row count silently drops and RAW cannot
reveal what is missing, because RAW only ever contained what the filter allowed
through. Recovery requires re-fetching a publication that USGS revises (the 2025
release reached ver. 2.0; the 2026 report is at ver. 1.3).

Filtering downstream turns the same event into a visible row-count change against
data that is still on disk — **loud and recoverable rather than silent and
permanent**.

**Precedent from this project:** Census VIP filters at ingest because its API
accepts only one `category_code` per request. Those codes were inferred, and
Census has since indicated `12XX` is Highway and Street rather than Office —
meaning `CENSUS_VIP_RAW` may hold rows labelled with an assigned category the
source never confirmed, fixable only by re-fetching. USGS imposes no such
constraint; the complete file is already local. Accepting that constraint
voluntarily would have been reproducing a known cost for no benefit.

**Middle position considered:** the stage holds the complete published file
regardless, so fidelity could have lived at the stage while the table held a
narrower scope. Defensible, but rejected in favour of landing everything, since
the file is ~3 MB and the storage argument is worth approximately nothing at this
scale.

**Cost accepted:** the warehouse carries ~8,800 rows nothing currently queries,
and every downstream query must filter on both `Commodity` and `Section`.

### USGS Decision 4 — Release vintage tracked via `source_file`

**Chosen:** `RAW.USGS_MCS_RAW` carries a `source_file` column populated from
`METADATA$FILENAME` during `COPY INTO`.

**Rejected alternative:** match `RAW.BLS_PPI_RAW`, which has only `loaded_at`.

**Why:** USGS republishes annually into the same table, appending rather than
replacing. Without a filename, a 2026-release row and a 2027-release row are
indistinguishable once loaded — and `loaded_at` records when *this pipeline* ran,
not which publication the row came from. Those diverge as soon as a load is
re-run.

**Cost accepted:** a deliberate divergence from the BLS pattern, which must be
documented (this entry) so it reads as intentional rather than as drift.

**Related — fetch script filename policy:** output filenames are timestamped
(`usgs_mcs_YYYYMMDD_HHMMSS.csv`). Snowflake tracks filenames already loaded into
a table and skips repeats by default; a constant filename would make a genuine
reload look like a silent no-op. **The flip side, recorded deliberately:**
timestamping removes that dedup guard, so re-running the fetch and loading the
result produces a duplicate load. Before any future load, the check is the row
count, not the filename.

### USGS Decision 5 — Fetch by item lookup, not hardcoded URL

**Chosen:** `fetch_usgs_mcs.py` queries the ScienceBase item API for the release's
file list and locates the CSV by matching a filename fragment.

**Rejected alternative:** hardcode the file's download URL.

**Why:** ScienceBase download URLs contain an opaque disk path that changes
between releases. A hardcoded URL either 404s next year or — worse — continues
serving the *previous* year's file, which would load cleanly and be wrong.

**Two validation guards, both from failures already encountered in this project:**
- The response body is checked to start with `MCS chapter` before anything is
  written. Census demonstrated that an API failure can return HTTP 200 with an
  HTML body, which `raise_for_status()` does not catch.
- The download uses `response.content` (raw bytes), never `response.text`.
  `.text` decodes using a guessed encoding and re-encodes on write, which would
  corrupt all 5,773 em dashes before Snowflake ever sees the file. Byte-level
  fidelity at fetch time is the same principle as TEXT columns at RAW, applied
  one step earlier.

**Cost accepted:** two HTTP requests instead of one, and a dependency on the
ScienceBase item ID remaining stable. The ID is recorded in Section 3 above, and
a change surfaces as a readable error listing the files actually found.

### Verification performed (Stage 4 — USGS)

| Check | Expected | Result |
|---|---|---|
| `COPY INTO` result | rows_parsed = rows_loaded, 0 errors | 8,886 / 8,886 / 0 ✓ |
| Total rows | 8,886 | ✓ |
| Cement, U.S. salient statistics | 55 | ✓ |
| Grain (rows per year) | 11 for each of 2021–2025 | ✓ |
| Encoding (em dash intact in `Section`) | one clean row, no replacement chars | ✓ |
| Sentinel survival (`NULL_IF = ()` held) | literal `NA`, `—`, `W`, `E`, `s` returned, not NULL | ✓ |

The final check is the one that validates the TEXT decision: had `NULL_IF`
defaulted, every sentinel would have collapsed to NULL and the difference between
*withheld*, *not available*, and *zero* would have been unrecoverable.

---

## Stage 5 — Transform Decisions

**Status:** Complete for USGS, RAW through MART. Not started for BLS or Census.
**Objects built:**
- `STAGING.STG_USGS_MCS_CEMENT` — `sql/05_staging_usgs_mcs_cement.sql`
- `MART.dim_time_annual`, `MART.dim_material`, `MART.dim_source` —
  `sql/06_mart_dimensions.sql`
- `MART.fact_production` — `sql/07_mart_fact_production.sql`

Decisions 1–2 cover STAGING. Decisions 3–8 cover the MART layer. Numbering
matches the references inside the SQL files.

### Decision 1 — STAGING layer implemented as standard views

**Chosen:** The RAW → STAGING transform is a standard view. No stored copy of the
transformed result.

**Rejected alternatives:**
- **Materialized view.** Snowflake maintains it automatically as the base table
  changes, at the cost of continuous background compute credits. Also Enterprise
  Edition and up, and carries SQL restrictions (no joins, limited function set,
  cannot be layered on another view).
- **Table built via CTAS.** Transform runs once, result is stored, reads are
  cheap.

**Why — workload sizing, not preference:** `RAW.USGS_MCS_RAW` holds 8,886 rows
(~3 MB) and changes **once per year**. The filtered cement result is 55 rows. A
materialized view earns its keep on expensive aggregations over high-churn
tables; here the computation is trivially cheap and the churn is annual, so
materialization would mean paying continuously to avoid a read cost that is
already near zero. Wrong tool at any budget, not merely an unaffordable one.

**Why not CTAS — this is the load-bearing reason:** a stored table is a snapshot.
When the next annual release lands in RAW, the table serves the prior year's data
until something rebuilds it, and it does not error while doing so — it is
silently stale. That is the same failure family as an ingest-time filter against a
renamed label: green checkmark, wrong answer. A view reflects new RAW rows on the
next read with nothing to schedule and no maintenance step to forget. For an
annual pipeline, *correct with no orchestration* is worth more than read-time
savings on a 3 MB scan.

**Cost accepted:** every read re-scans RAW and re-applies the casts and sentinel
routing. Negligible at this size; a real cost that grows with volume.

**Boundary condition recorded:** the decision inverts on different numbers. BLS
PPI at monthly grain over fifteen years, with a costly window-function
aggregation read by a dashboard hundreds of times daily, is the case where
materialization is correct. Same reasoning, different sizing.

### Decision 2 — Sentinel routing: three columns, not one

**Chosen:** the STAGING layer splits the RAW `Value` column into three:

| Column | Holds |
|---|---|
| `value_numeric` | the number, where the source asserted one |
| `value_flag` | an explicit category, on every row, never NULL |
| `value_raw` | the original token exactly as landed |

**Rejected alternatives:**
- **`value_numeric` alone.** Every sentinel becomes NULL and the token is
  discarded. This is the same information loss the TEXT-at-RAW decision was made
  to avoid, relocated one layer downstream.
- **`value_numeric` + `value_raw`, no flag.** The reason survives but is only
  recoverable by re-reading the token, so every downstream consumer
  re-implements the codebook — needing to know that `W` means withheld, that `NA`
  and `XX` are different facts, and that the published metadata documents six of
  the twenty-plus codes actually present. The flag column interprets once, at the
  boundary.

**Cost accepted:** the flag mapping is logic this project now owns and maintains.
A future release can introduce a code it has never seen, which is what
`UNKNOWN_SENTINEL` exists to surface.

#### The em dash routes to 0, not NULL

The em dash (U+2014) is the only sentinel mapping to a number, because it is the
only one that *is* a measurement: USGS is asserting the quantity is zero. NULL
would assert the opposite — that nothing was reported — which is a claim the
publisher never made.

Concretely, over five years of a statistic where one year is a real zero: `AVG`
drops the year from its denominator and returns a figure higher than reality;
`COUNT(value_numeric)` reports a gap in a year that has none; `MIN` returns the
wrong year. `SUM` alone is unaffected, which is what makes this dangerous —
whichever aggregate gets spot-checked may be the one that looks correct.

`W` sits on the opposite side of the same line. There the number exists and is
genuinely hidden, so NULL is honest and substituting 0 would invent data.
**Absence of a value is not a value of zero**, and the routing has to distinguish
them in both directions.

#### Clean numbers get flag `VALUE`, not NULL

If ordinary numbers had a NULL flag, a NULL in that column would mean either
"this is a plain number" or "the flag logic failed to fire," with no way to tell
which. Filling it always makes `GROUP BY value_flag` a complete census: the
counts must sum to the row count or there is a bug.

#### Bounds and ranges leave `value_numeric` NULL

`<1,000` does not become 1000 and `500–17,000` does not become a midpoint. A
ceiling and an interval are not measurements, and a number placed in a numeric
column will eventually be summed. Bound-aware analysis stays possible via
`value_raw`, deliberately rather than by accident.

#### Full routing table

| Token(s) | `value_numeric` | `value_flag` |
|---|---|---|
| `"91,000"`, `127.50` | parsed number | `VALUE` |
| em dash (U+2014) | `0` | `ZERO` |
| `W` | NULL | `WITHHELD` |
| `NA` | NULL | `NOT_AVAILABLE` |
| `XX` | NULL | `NOT_APPLICABLE` |
| `>50`, `<1`, `<1,000` … | NULL | `BOUND` |
| `190 - 290`, `500–17,000` … | NULL | `RANGE` |
| `s`, `Small`, `Very small`, `Moderate`, `Moderate to large`, `Large`, `E`, `Variable…` | NULL | `QUALIFIER` |
| NULL or empty string | NULL | `EMPTY` |
| anything unrecognised | NULL | `UNKNOWN_SENTINEL` |

#### How the mapping was verified — and why the obvious check was useless

The cement slice is 55 rows and contains **zero sentinels**. Checks against the
view therefore pass identically whether the routing is correct or entirely
broken; nine of the ten `CASE` clauses never execute. Verification had to apply
the same expression to all 8,886 RAW rows, where the sentinels actually live.

**Recorded as a general rule: when the thing being changed is unreachable in the
data under test, the verification has to target the definition or a wider
population — not the output.** The same rule applied again at the end of this
work, when a `CASE` edit could only be confirmed via `GET_DDL`, because no query
against the 55-row view could reach the clause that changed.

**Final distribution across all 8,886 RAW rows:**

| Flag | Rows |
|---|---|
| VALUE | 7,720 |
| NOT_AVAILABLE | 353 |
| ZERO | 313 |
| WITHHELD | 224 |
| BOUND | 145 |
| QUALIFIER | 104 |
| RANGE | 17 |
| NOT_APPLICABLE | 8 |
| UNKNOWN_SENTINEL | 2 |
| **Total** | **8,886** |

Corrects the prior Stage 4 estimate: rows whose `Value` is not directly castable
number **1,166**, not "approximately 1,000." `EMPTY` returned zero rows.

#### The mapping took three passes to converge

Each pass could only see the tokens the previous pass failed on.

1. **Pass 1** — documented codes plus the em dash. Left 33 unclassified.
2. **Pass 2** — inspecting those 33 by hex produced the three findings below.
   Left 12.
3. **Pass 3** — the remaining 12 were `Small` (6) and `Moderate` (4), plus the 2
   that are genuinely unclassifiable.

This is what iterating against an undocumented source looks like, and
`UNKNOWN_SENTINEL` is the mechanism that made each pass's remaining ignorance
visible instead of silent.

#### Three findings from hex inspection

**1. A non-breaking space made a valid number unparseable.** A cell displaying as
`68` is the bytes `36 38 C2 A0` — the digits, then U+00A0. `TRIM` strips ordinary
spaces only, so the parse returned NULL and pass 1 flagged a real number as an
unknown sentinel. Fixed by passing an explicit character set:
`TRIM(value, ' ' || CHR(160) || CHR(9))`.

The NBSP arrived as *UTF-8* bytes (`C2 A0`) in a file loaded as WINDOWS-1252,
where `A0` alone is already an NBSP. The publisher mixed encodings within one
file. Visible only because RAW preserved the bytes rather than normalizing them.

**2. A third dash character, with a third meaning.** Range separators are
inconsistent — some spaced hyphen-minus (U+002D), some unspaced en dash (U+2013).
With the em dash (U+2014) meaning zero, this file uses three dash characters for
three unrelated purposes. **A generic "normalize the dashes" cleanup step would
have destroyed every zero and merged two distinct meanings.**

**3. `Value` is free text, not a coded field.** The magnitude vocabulary collected
across passes is `s`, `Small`, `Very small`, `Moderate`, `Moderate to large`,
`Large` — six strings for one concept, which is what happens when different
chapter authors write prose into a value column. This reframes the source:
`Value` holds numbers where the author had one and adjectives where they didn't.
It is not a numeric column with a documented sentinel set.

#### Deliberately left unclassified

`?1` and `?10` are hex `3F 31` and `3F 31 30` — a real ASCII question mark, not a
rendering artifact. Most likely a mangled inequality symbol in the publisher's own
export. The published bytes carry no recoverable meaning, so `UNKNOWN_SENTINEL`
is the correct and honest destination rather than a guess.

#### Implementation notes

- `TRY_TO_DECIMAL(..., 38, 6)`, not `TRY_TO_NUMBER(...)`. Default precision and
  scale means **scale 0, which rounds** — a price of `127.50` would have landed
  as `128`, silently. Explicit scale is required, not decorative.
- The em-dash section filter is built as
  `'Salient Statistics' || CHR(8212) || 'United States'` rather than pasting the
  character. The literal works, but a hyphen there matches zero rows and returns
  an empty result rather than an error, and the file is now known to contain three
  dash characters.
- `CREATE OR REPLACE VIEW`, not `CREATE ... IF NOT EXISTS`. Views store no data,
  so replacement destroys nothing, and transform logic is expected to be iterated
  on. `IF NOT EXISTS` would silently no-op on re-run, leaving an edited file and
  an unchanged view.

### Decision 3 — `fact_production` grain: one row per year, one column per statistic

**Chosen:** `fact_production` holds one row per year. Each of the eleven USGS
statistics becomes its own named column, and each column carries exactly one
unit and one additivity rule.

**What the data showed before the decision was made.** The options were first
framed before the actual statistics had been queried, and both initial framings
were flawed. Reading the eleven statistics for one year settled it:

- **"Production" is two rows, not one** — cement (84,000) and clinker (69,000).
  Clinker is the intermediate that is ground into cement, so summing them
  double-counts. USGS never treats clinker as a `Commodity` value anywhere in
  the file; it exists only as a `Statistics_detail` inside the CEMENT chapter.
- **The eleven split three ways on additivity:**

| Statistic | Unit | Additivity |
|---|---|---|
| Cement production, clinker production, shipments, imports ×2, exports, apparent consumption | thousand metric tons | Additive — flows, safe to sum across years |
| Stocks, year-end | thousand metric tons | **Semi-additive** — a balance; summing years is meaningless |
| Employment | headcount | **Semi-additive** |
| Price, average mill unit value | USD per metric ton | **Non-additive** |
| Net import reliance | percent | **Non-additive** |

  Stocks is the trap: same unit as production, so it looks summable.

- **All eleven share one grain** — one value per statistic per year — which is
  what makes a single wide row possible.

**Rejected alternatives:**
- **Narrow — production volume only.** One additive measure, honest to the
  original `production_volume` column. Rejected because it discards the two
  statistics the cross-source analysis depends on: average mill price is the
  natural cross-check against BLS's cement PPI, and apparent consumption is the
  natural pairing for Census construction spend. Also not actually "one row per
  year" until a choice is made between cement and clinker production.
- **Narrow, split into several fact tables** (production, trade, pricing). The
  right pattern when measures belong to different business processes with
  different sources and cadences. Wrong here: all eleven come from one annual
  publication at one grain, and splitting 55 rows into four tables means four
  sets of keys and four joins to reassemble what USGS published as one picture.
- **Long — one row per statistic per year, generic `measure_value` column.**
  Keeps everything, but puts additive and non-additive numbers in one column.
  An unfiltered `SUM(measure_value)` adds tons to dollars to percentages.

**Why:** C keeps every statistic USGS published
available in the MART, each in a column with a single unit and a single
additivity rule, so the price and consumption measures the cross-source analysis
depends on are reachable — and because RAW and STAGING retain the full file,
adding a column for a future statistic is a schema edit, not a data recovery.

The refinement matters: the claim is not that C loses nothing, but that
anything a MART choice leaves out is recoverable from a layer already built.
That is a claim about the design, not the data.

**Cost accepted:** USGS publishes long, so the MART load must pivot to wide. A
new statistic in a future release means a schema change rather than new rows —
the brittleness the long format protected against. Acceptable because the MART
is a derived presentation layer: the change costs an edit, not a re-fetch.

### Decision 4 — MART storage: dimensions as tables, facts as views

**Chosen:** hybrid. Dimension tables are physical tables. Fact tables are views
over STAGING that join to them.

**Rejected alternatives:**
- **Everything as tables (CTAS or INSERT).** Stable keys and cheap reads, but
  the facts become snapshots that go silently stale until something rebuilds
  them — the failure rejected for STAGING in Decision 1.
- **Everything as views.** Always current, but surrogate keys would be computed
  at read time (typically with `ROW_NUMBER()`) and nothing stored could promise
  that `material_key = 1` still means cement on the next read. Every fact row's
  foreign key could silently point at the wrong dimension row.

**Why:** stable surrogate keys are a *prerequisite* for the conformed dimension
in Decision 5. A conformed dimension only conforms if its keys mean the same
thing permanently, which requires them to be stored. Facts have no stored
identity anything depends on, so they can be views and stay current for free.

The same reasoning removes `production_key` from `fact_production`. `schema.md`
gave every fact its own surrogate key, but a view stores nothing, so a generated
key would be recomputed on each read. Nothing references a fact row by key
anyway. The grain `(time_key, material_key)` is the row's identity, enforced by
a verification check.

**The failure mode hybrid introduces:** if a dimension is missing a member, an
`INNER JOIN` from a fact view drops the matching fact rows **silently** — no
error, fewer rows. Guarded two ways: every dimension carries an **unknown
member** at key `-1`, and fact views use `LEFT JOIN` with `COALESCE(key, -1)`,
so unmatched rows land visibly against `Unknown` instead of vanishing. `-1`
rather than `0` so it cannot be mistaken for a legitimate key. An anti-join
check reports any row that lands there.

**Cost accepted:** load order now matters. Dimensions must be populated before
any fact view is queried — the pipeline's first dependency beyond
RAW-before-STAGING.

### Decision 5 — `fact_production` keeps a conformed `material_key`, constant at Cement

**Chosen:** `fact_production` carries `material_key`, although every row
currently resolves to Cement.

**Rejected alternative:** omit it. The table is cement-only, so a key that never
varies filters nothing.

**Why:** `dim_material` is a **conformed
dimension**, shared with `fact_price`. The key is what makes BLS cement price and
USGS cement production comparable *in the model* rather than by convention.
Without it, joining the two means matching on year and trusting both sides are
about cement. With it, the model asserts they are the same material and the join
proves it.

**What separates this from `dim_region`** (Stage 3 Decision 3, dropped):
`dim_region` had no source carrying regional data, so building it was
speculation. Here the axis is real — the landed USGS file holds **127
commodities**, deliberately landed in full by USGS Decision 3. Extending
`fact_production` to lime or gypsum is a one-line change to the STAGING filter:
no re-fetch, no new source. *Do not build a dimension for an axis no source
supports; do carry the key for an axis the source already contains.*

**Schema correction made alongside:** `dim_material` gained a `series_id` column
not present in `schema.md`. `parent_series` is `WPU133` for all six child
materials, so it cannot identify which material a BLS row belongs to. Without
`series_id`, loading `fact_price` would mean joining on material names matched
against BLS series titles — a string join against publisher text, which is what
surrogate keys exist to avoid.

**On the USGS side, the join is on the name** — USGS publishes no other
identifier for a commodity. Made safe by the Decision 4 guard: a mismatch lands
on the `-1` unknown member rather than vanishing, and a rename of `Cement` would
first empty the STAGING view, whose filter matches the same string.

**Cost accepted:** a join that filters nothing today, and a key implying
variability the table does not yet have. Accepted because dropping a key later
is cheap and retrofitting one into queries already written is not.

### Decision 6 — Surrogate keys as explicit literals; the year as the time key

**Chosen:** every dimension key is written as a literal in the `INSERT`
statements of `sql/06_mart_dimensions.sql`. `dim_time_annual.time_key` holds the
calendar year itself.

**Rejected alternatives:**
- **`AUTOINCREMENT` / `IDENTITY`.** The value depends on insertion order and
  history. A rebuild in a different order can reassign keys.
- **A `SEQUENCE`.** Same order-dependence, and it keeps climbing across rebuilds.

**Why:** key values live in version-controlled
SQL, so rebuilding the MART from scratch produces identical keys. The danger
with generated keys is not that a rebuild fails — it is that a rebuild
*succeeds* and every fact row's foreign key now points at a different dimension
row. No error.

**The year needs no surrogate.** Surrogate keys exist to insulate a warehouse
from source identifiers that get renamed, reused, or retired — `'Cement'` could
become `'Cement, hydraulic'`. A calendar year has none of those properties. Time
dimensions are the standard exception: `YYYY` here, `YYYYMM` for
`dim_time_monthly`. A fact row reading `time_key = 2023` is legible without a
join. The column keeps the name `time_key` so the ERD and foreign-key naming
stay valid; `year` is retained alongside it as the documented cross-grain
correlation column shared with `dim_time_monthly`.

**Related implementation choice — `CREATE OR REPLACE TABLE` for dimensions**,
deliberately unlike the RAW scripts' `IF NOT EXISTS`. RAW protects landed data
that cannot be recovered without re-fetching. These tables hold no landed data:
every row is a committed literal, so replacing them reproduces identical content.
The file is the single source of truth for dimension membership; a row added by
hand outside it is destroyed on the next run, by design.

**Platform fact recorded:** Snowflake accepts `PRIMARY KEY` and `FOREIGN KEY`
constraints but **does not enforce them** — only `NOT NULL` is enforced. The
constraints are metadata for readers and hints for the optimizer. Key uniqueness
therefore has to be checked explicitly; in an enforcing database the check would
be redundant.

**Cost accepted:** the MART has two key conventions — meaningful keys for time,
opaque surrogates for everything else. Documented here so it reads as deliberate.

### Decision 7 — Pivot by conditional aggregation, not `PIVOT`

**Chosen:** `MAX(CASE WHEN measure = '...' THEN value_numeric END) AS <name>`,
one line per column.

**Rejected alternatives:**
- **Dynamic `PIVOT ... IN (ANY)`.** Every distinct value automatically becomes a
  column. **Initially chosen, then reversed** — the stated reason for choosing it
  ("easier if we find out a new statistic has been released") was the argument
  against it. With dynamic pivot you *don't* find out: the column appears with no
  code change, no review, and no check firing. Worse, the column names become the
  publisher's text — `Production: Portland, blended, and masonry cement` — so
  every query must quote them exactly, and a USGS rewording makes the old column
  vanish and a new one appear, breaking every consumer. Publisher wording becomes
  the schema. This is the same reasoning as the `series_id` decision: do not let
  publisher-controlled text become your identifiers.
- **Explicit `PIVOT ... IN ('...')`.** Workable, but column names still derive
  from data values and need renaming afterward.

**Why:** column names are what analysts read, so they should be chosen and
documented by this project, not derived from the publisher's copy. And the
per-column unit and additivity documentation Decision 3 requires needs a place
to live — it is attached as a Snowflake column `COMMENT` on each measure in the
view definition, visible to anyone browsing the view in Snowsight.

**Publisher text confined to one place.** A `statistic_map` CTE at the top of
the view translates each USGS `statistic_detail` into a short measure code owned
by this project. The pivot matches on the codes. A rewording is a one-line edit
to the map; the pivot never changes.

**Pivot key is `statistics_detail`, not `statistics`.** `Production` appears
twice per year under `statistics`. Pivoting on it would collapse cement and
clinker into one cell, and `MAX` would silently return 84,000 as "production"
while clinker disappeared.

**What conditional aggregation does *not* solve, stated honestly:** the map
still matches publisher text, so a rewording still makes a measure go NULL for
the new release. What changes is *where* the damage lands — one line in one
file, invisible to consumers — and that it is detected. Two checks:
1. **Unmapped statistics** — any `statistic_detail` in STAGING with no map entry.
2. **Empty measures** — any measure NULL in a row whose
   `non_value_measure_count` is 0, meaning the value was not withheld but simply
   not found.

A rewording trips both at once; a genuinely new statistic trips only the first.

**Cost accepted:** a new statistic is ignored by the view until a line is added
to the map. Made loud by check 1.

### Decision 8 — Sentinel visibility in the MART: one summary column

**Chosen:** `fact_production` carries `non_value_measure_count` — the number of
measures in that row whose source value was not a plain number.

**Rejected alternatives:**
- **Numbers only.** Flags stay in STAGING, one query away. Preserves the
  distinction, but not where analysts look: a future `W` for cement production
  arrives in the MART as a bare NULL, indistinguishable from a value that was
  never collected.
- **A flag column per measure.** Complete, but eleven more columns doubling the
  table's width.

**Why:** it gives a clear view of the data and a NULL cannot
be mistaken for clean data. Zero means every measure in the row is a real
number. Anything else means check `STAGING.STG_USGS_MCS_CEMENT.value_flag`
before trusting a NULL in that row.

This is the MART-layer end of the sentinel design that began with TEXT columns
at RAW (USGS Decision 2) and the three-column routing in STAGING (Decision 2):
the distinction between *withheld*, *not available*, and *zero* is preserved at
every layer, at a cost proportionate to each layer's purpose.

**Cost accepted:** the column says *that* a row has a non-value measure, not
*which* one or *why*. Finding out requires STAGING.

### Decision 9 — BLS release precedence: STAGING keeps every load; `fact_price` takes the latest

**Chosen:** `stg_bls_ppi` holds one row per series per period **per load**.
`fact_price` selects, for each series and month, the whole row with the most
recent `loaded_at` (`ROW_NUMBER() OVER (PARTITION BY series_id, year, month ORDER
BY loaded_at DESC)` with `QUALIFY ... = 1`).

**Rejected alternatives:**
- **Keep only the latest row in STAGING.** Loses the record that a value was
  revised, and STAGING stops being a faithful view of RAW. Revision history is
  one of the few things BLS data can tell you that a snapshot cannot.
- **Aggregate across loads with `MAX` or `AVG` in the fact.** This is the exact
  exposure the USGS pivot carries: one row silently built from figures out of two
  different publications.
- **Truncate and reload RAW on each pull.** Breaks RAW's immutability (Stage 4).

**Why:** BLS revises preliminary figures for up to four months, so overlapping
pulls are the normal case, not an edge case. Unlike USGS, where release
precedence is still open, BLS has a usable ordering: one `loaded_at` per pull,
and every pull carries the whole series. `ROW_NUMBER` picks one complete row —
it cannot mix a value from one load with a value from another.

**Cost accepted:** `loaded_at` orders *loads*, not *publications*. Re-loading an
older file after a newer one would make the older values win. Verification check
5 in `sql/09_mart_fact_price.sql` lists every month covered by more than one
load, so the winners can be inspected. **The rule has been tested only against a
single load** — the `QUALIFY` path that discards an older row has not yet run on
real data. It will first run when a second pull is loaded.

### Decision 10 — `is_preliminary` travels with every `fact_price` row

**Chosen:** `fact_price` carries a boolean `is_preliminary`, TRUE when BLS
footnote code `P` is present.

**Rejected alternatives:**
- **Drop preliminary rows.** Removes the most recent four months of every series —
  the months a price series is most often read for.
- **Leave the footnote in STAGING only.** A consumer of `fact_price` would see an
  index value that looks final and may change.

**Why:** the same principle as Decision 8. A preliminary value and a final one are
indistinguishable as numbers, so the status has to travel with the row. A status
flag on the fact sits in the same family as `non_value_measure_count`.

**Shape finding behind the implementation:** every BLS observation has a
`footnotes` array, but when there is no footnote the array holds **one empty
object** (`[{}]`), not zero elements. Reading `footnotes[0]:code` would have
worked today and failed for a second footnote in position two. The view uses
`FILTER` over the whole array, and also exposes every code as `footnote_codes`
text so a code other than `P` appears as a value to look at instead of being
ignored.

**Cost accepted:** a column that was not in the Stage 3 design.

### Decision 11 — Monthly grain enforced in `fact_price`; STAGING keeps every period

**Chosen:** `stg_bls_ppi` carries `period` exactly as BLS sends it and sets
`month` only when the period is `M01`–`M12` (NULL otherwise). `fact_price`
filters on `month IS NOT NULL`.

**Rejected alternatives:**
- **Filter in STAGING.** A silent drop at the layer that is supposed to be
  faithful — the filter-position argument from USGS Decision 3.
- **Exclude by name: `period <> 'M13'`.** Names one known code and misses
  `S01`/`S02` or anything BLS adds later. A positive definition of what counts as
  a month is stricter than a list of what does not.

**Why:** the fact table is where grain is defined. `M13` is an annual average;
mixing it into monthly rows would corrupt any `AVG` run over them. The profile of
`RAW.BLS_PPI_RAW` found no `M13` in this pull, so the filter excludes nothing
today — and STAGING verification check 4 reports any row it would exclude.

**Cost accepted:** a silent drop in the view, made loud in a check — the same
trade as Decision 7.

### Decision 12 — `dim_time_monthly` generated from fixed bounds; key is `YYYYMM`

**Chosen:** the dimension is populated by `INSERT ... SELECT` over `GENERATOR`
with a fixed start date (2016-01-01) and a fixed `ROWCOUNT` of 132, plus the `-1`
unknown member. `time_key = year * 100 + month`.

**Rejected alternatives:**
- **132 hand-typed literal rows.** Consistent with Decision 6's convention for
  opaque keys, but noise and a typo risk for a key that is a pure function of the
  date.
- **Derive the range from the data (`MIN`/`MAX` of the fact).** Dimension
  membership would then depend on the data, so nothing would catch a month
  missing from the dimension.
- **`AUTOINCREMENT` or a sequence.** History-dependent; rejected in Decision 6.

**Why:** Decision 6 requires that a rebuild reproduce identical keys. A key
computed from a date satisfies that without literals. The range, 2016-01 to
2026-12, covers the BLS history plus the rest of the current year so new monthly
pulls land on existing rows.

**Cost accepted:** the range is hand-maintained — raise `ROWCOUNT` by 12 per
added year. Anti-join check 8 in `sql/09_mart_fact_price.sql` reports any BLS
month outside it. The Census range has **not** been checked against it; that
happens when `fact_spend` is built.

### Decision 13 — Census category derived from the code, not read from the stamped label

**Chosen:** `stg_census_vip` derives `construction_category` from
`category_code` through one map (`category_map`) inside the view. The
`category_label` the fetch script stamped into RAW is kept as
`category_label_raw` for comparison only.

**Rejected alternative:** read `category_label` from the payload, as the RAW row
already carries it.

**Why:** `category_code` is what Census sent. The label is *our interpretation* of
that code, reached by cross-referencing live values against press-release tables
(Census Decision 1), and then written into RAW at fetch time. An interpretation
stored in RAW can only be corrected by re-fetching; the same interpretation held
in a STAGING view is corrected by editing a line. This is the same principle as
sentinel routing in Decision 2: interpretation happens downstream, where it can
change.

This partly retires a line in open item 2 ("any correction requires a re-fetch
and re-verify of `CENSUS_VIP_RAW`"). A *label* correction now costs one edit. A
re-fetch is still needed to land a category that is not yet in RAW (Highway and
Street).

**Guard:** a verification check reports any row where the stamped label
disagrees with the map. After an intended map correction that check will fire
by design, and the stamped label is expected to be stale.

**Cost accepted:** the map is a CTE in the view, so changing it means editing
and redeploying `sql/10_staging_census_vip.sql`. The better home is a small
MART table that the view and its checks both read — worth doing when a second
category forces an edit (see Known debt, Decision 7).

### Decision 14 — `category_verified` travels with every Census row

**Chosen:** `stg_census_vip` and `fact_spend` carry a boolean `category_verified`,
set in the category map. FALSE for all three landed categories.

**Rejected alternatives:**
- **Record the status in documentation only.** Invisible to anyone querying
  `fact_spend`, and a labelled number reads as a fact.
- **Leave unverified categories out.** Would leave `fact_spend` empty; the
  data under each code is real regardless of how the code was named.

**Why:** Census Decision 1 logged the mappings at "High" confidence, and the
2026-09-09 amendment showed that rating was confidence in a **method**, not
verification against a source of record — another code in the same table was
contradicted. The flag makes that distinction part of the data. When a code is
checked against the Census zipped VIP dataset, one flag in the map flips to
TRUE; nothing else changes.

**Scope of the risk:** the contradicted codes (`02XX`, `12XX`) are not landed, so
no row in `fact_spend` depends on the contradicted mapping. The three landed
codes were reached by the same method and are not confirmed either. The flag is
what keeps that from being forgotten.

**Cost accepted:** a status column on the fact that is FALSE on every row today.

### Decision 15 — Fields assumed constant are kept and checked, not dropped

**Chosen:** `data_type_code`, `seasonally_adj`, `us` and `time_slot_id` are
carried through STAGING even though each has one value today (`T`, `no`, `1`,
`0`). A check reports any row that breaks the assumption.

**Rejected alternative:** drop columns that never vary.

**Why:** "every row is national, monthly, unadjusted and type T" is an
assumption `fact_spend`'s grain depends on. If seasonally adjusted rows ever
landed beside unadjusted ones, they would compete for the same
(category, month) slot and the fact would double count or pick one arbitrarily.
Keeping the columns turns the assumption into a one-query check instead of a
belief. The release-precedence rule is otherwise the same as `fact_price`
(Decision 9): latest `loaded_at` wins per category code and month, partitioned
by code rather than the derived name so a map edit cannot merge or split groups.

**Cost accepted:** four columns of nothing in the view. Also inherited from
Decision 9: `loaded_at` orders loads, not publications, and the rule has run on a
single load only.

### Decision 16 — Table storage class: permanent throughout

**Chosen:** every table stays permanent, which is Snowflake's default. No
transient or temporary tables.

**Rejected alternatives:**
- **Transient RAW tables.** Lower storage cost, but no Fail-safe period and at most
  one day of Time Travel.
- **Transient dimension tables.** Defensible because they rebuild from committed
  SQL, but the saving is nil at this size.

**Why:** Snowflake's guidance is that long-lived tables should be permanent and
that transient tables suit short-lived work tables such as ETL staging. This
project has no such tables — STAGING is views. The data is about 3 MB, so the
cost difference is negligible. RAW can only be rebuilt by re-fetching from
publishers who revise or replace their files.

**Cost accepted:** Fail-safe storage on tiny tables. Negligible.

### Decision 17 — `category_verified` standard; amends Decision 14

**Chosen:** a Census category's `category_verified` flag is TRUE when (a) every
settled month of its values is identical to an independent republication of the
Census series, and (b) the unit is confirmed. Flags default to FALSE. The flag
lives in the `category_map` in `sql/10_staging_census_vip.sql`.

**Applied 2026-10-02** to all three landed categories, against FRED's
republication of Census construction spending (Total, not seasonally adjusted,
millions of dollars): Commercial `TLCOMCON`, Power `TLPWRCON`, Manufacturing
`TLMFGCON`. Yearly sums for 2016–2025 and the sum for January–April 2026 are
identical for all three, so 124 of 126 months match in each. The only differences
are May and June 2026, the two newest months at pull time:

| Category | May + June 2026, ours | May + June 2026, FRED now |
|---|---|---|
| Commercial | 10,336 + 10,460 | 10,425 + 10,568 |
| Power | 29,826 combined | 30,296 combined |
| Manufacturing | 29,188 combined | 28,976 combined |

The differences run in both directions, consistent with Census revising recent
months. The cause was not confirmed against a vintage archive.

**Rejected alternatives:**
- **Wait for the Census zipped dataset.** It remains the stricter check and is
  still open for the disputed codes (`02XX`, `12XX`), which are not landed.
- **Leave every flag FALSE.** Would leave a completed check unrecorded and the
  flag meaningless.
- **Rely on the magnitude-and-swing method alone.** That is what Census Decision 1
  did, and its own log called it confidence in a method.

**Why:** a month-for-month match over ten years is far stronger evidence than the
two-month cross-reference in Census Decision 1, and FRED republishes Census
series under Census's own category names and units.

**Limits, stated so they travel with the flag:** FRED is a secondary source. The
check does not address `02XX` or `12XX`. It is not the authoritative code table.
`TRUE` therefore means "verified at the value level against a secondary
source", not "authoritative". The Public and Private variants of each series
carry different numbers; only the Total series were used.

**Cost accepted:** a flag whose meaning needs this paragraph.

### Decision 18 — USGS release precedence: descoped

**Chosen:** no second USGS release will be loaded for this project, so a
precedence rule is not built. The duplicate check (verification check 5 in
`sql/07_mart_fact_production.sql`) stays as the guard, and the limitation is
stated in the README.

**Rejected alternative:** build the rule now. It cannot be tested without a second
release to run it against.

**Why:** this project is a bounded portfolio piece built on one release of one
cement table. Building an untestable rule would add code that has never run.

**What would be built:** latest release wins per year and statistic, ordered by
the release year in the published filename; `fact_production` would replace
`MAX` with `ROW_NUMBER`, as `fact_price` does (Decision 9).

**Cost accepted:** if a second release were loaded, `fact_production` would take
`MAX` across releases until check 5 was run. The guard reports the duplicate; it
does not prevent it.

### Verification performed (Stage 5 — USGS)

| Check | Expected | Result |
|---|---|---|
| Row count | 55 | ✓ |
| Rows per year | 11 for each of 2021–2025 | ✓ |
| Flag census (view) | sums to 55; all `VALUE` | ✓ 55 VALUE |
| Cast integrity | zero rows where flag = `VALUE` and numeric is NULL | ✓ |
| Routing logic (all 8,886 RAW rows) | every category exercised; total = 8,886 | ✓ 9 categories, 8,886 |
| Deployed view matches repo file (`GET_DDL`) | qualifier list current | ✓ |
| **MART** — dimension row counts | 6 / 8 / 4 (each includes `-1`) | ✓ |
| Dimension key uniqueness (PKs not enforced) | zero duplicates | ✓ |
| Every STAGING year has a `dim_time_annual` row | zero missing | ✓ |
| Every STAGING commodity has a `dim_material` row | zero missing | ✓ |
| `fact_production` row count | 5 (2021–2025) | ✓ |
| 2025 spot check against published file | 84000 / 69000 / 110000 / 160 / 21 / 0 | ✓ |
| Conformed join resolves to BLS series | 5 rows, all Cement / `WPU1322` | ✓ |
| Unmapped statistics | zero | ✓ |
| Duplicate STAGING rows per year and statistic | zero | ✓ |

One expected value was wrong, not the data: the dimension row-count check
originally stated `dim_material` should hold 9 rows. It holds 8 — the unknown
member plus seven materials. Resolved by counting the `INSERT`, not by adjusting
the data to meet the assertion. When a check fails, establish which side is
wrong before fixing either.

### Verification performed (Stage 5 — BLS)

| Check | Expected | Result |
|---|---|---|
| RAW matches the sample payload | 7 series × 127 observations, one `loaded_at` | ✓ |
| RAW profile: duplicates, `M13`, non-numeric values | zero | ✓ |
| `stg_bls_ppi` row count | 889 | ✓ |
| `stg_bls_ppi` flag census | all `VALUE`; zero cast failures | ✓ |
| Non-monthly periods (`month IS NULL`) | zero | ✓ |
| Duplicates within a single load | zero | ✓ |
| Preliminary rows | 28 (7 series × latest 4 months) | ✓ |
| Footnote codes other than `P` | zero | ✓ |
| **MART** — dimension row counts | 6 / 133 / 8 / 4 (each includes `-1`) | ✓ |
| Dimension key uniqueness (PKs not enforced) | zero duplicates | ✓ |
| `fact_price` row count | 889 | ✓ |
| `fact_price` grain `(time_key, material_key)` unique | zero duplicates | ✓ |
| Unknown-member rows in `fact_price` | zero | ✓ |
| NULL `price_index` | zero | ✓ |
| Every BLS month has a `dim_time_monthly` row | zero missing | ✓ |
| Every BLS series has a `dim_material` row | zero missing | ✓ |
| Months covered by more than one load | zero (single load) | ✓ |
| Regression value, Cement 2026-07 | 357.489, preliminary | ✓ — from the same pull, so this shows the view reproduces RAW, **not** that RAW matches BLS |
| Cross-grain join, `fact_price` × `fact_production` on `year` | 5 rows, 2021–2025, all Cement | ✓ — avg price index 271.0 → 358.4; production 91,000 → 84,000 thousand t |
| `fact_production` unaffected by the rebuild of the dimensions | 5 rows | ✓ |

**Not yet done:** one BLS value compared by hand against data.bls.gov — the only
check that would independently confirm RAW against the publisher.

### Deployment findings (Stage 5 — BLS)

Two partial deployments occurred, and in each the tool reported success. A third
point records what they changed about process:

1. **Grants:** Snowsight's Run executes only the statement under the cursor
   unless Run All is used. Running a five-statement grant script reported
   success after executing only `USE ROLE`. Detected by re-reading
   `SHOW GRANTS` and finding it unchanged.
2. **`06_mart_dimensions.sql`:** the three original dimensions were recreated but
   `dim_time_monthly` did not exist afterwards — the old version of the file was
   run, or the run stopped before the new block. `09` then failed on the missing
   join target. Detected by `SHOW TABLES` against the catalog.
3. **Consequence for process:** a run result says the statement executed, not
   that the object is the one in the repo. Verify deployments against the
   catalog (`SHOW`, `GET_DDL`, row counts), not against the success message.
   This is the silent-failure pattern again, in deployment instead of ingestion.

### Verification performed (Stage 5 — Census)

| Check | Expected | Result |
|---|---|---|
| RAW profile: categories, months, duplicates, malformed periods, non-numeric values | 3 categories × 126 months; zero problems | ✓ |
| `stg_census_vip` row count | 378 | ✓ |
| Distinct category codes | 3 | ✓ |
| Value flag census | all `VALUE` | ✓ |
| Malformed periods (`month IS NULL`) | zero | ✓ |
| Unmapped category codes | zero | ✓ |
| Map vs. stamped label disagreements | zero | ✓ |
| Assumed-constant fields violated | zero | ✓ |
| Duplicates within a single load | zero | ✓ |
| `category_verified` TRUE rows | zero (nothing verified yet) | ✓ |
| `fact_spend` row count | 378 | ✓ |
| `fact_spend` grain `(time_key, construction_category)` unique | zero duplicates | ✓ |
| Unknown-member rows | zero | ✓ |
| NULL `spend_amount` | zero | ✓ |
| Categories present | 3 | ✓ |
| Months covered vs. `dim_time_monthly` | 201601–202606, none missing | ✓ |
| Regression value, Commercial 2019-01 | 6009 | ✓ — from the same pull; proves the view reproduces RAW, **not** that RAW matches Census |
| Two-fact monthly join, `fact_price` × `fact_spend` on `time_key` | 126 months, 201601–202606 | ✓ — no fan-out (price read with `MAX`, spend summed) |

The join's endpoint values are not a trend: January and June are compared in
unadjusted data, so they differ seasonally.

**Not yet done:**
- One Census value compared by hand against a Census release table.
- Category codes checked against the Census zipped VIP dataset (open item 2).
- The dollar unit is **assumed to be millions of dollars**, taken from the Census
  release tables the codes were cross-referenced against. It is not carried in
  the API payload.

### Verification performed (Stage 5 — independent spot checks, 2026-10-02)

Compared against FRED (Federal Reserve Bank of St. Louis), which republishes BLS
and Census series. **FRED is a secondary source.** A direct comparison against
bls.gov and census.gov is still a manual step.

| Check | Result |
|---|---|
| BLS `WPU1322` identity and units | FRED lists it as "Cement, Hydraulic", Index 1982=100, not seasonally adjusted — consistent with `dim_material` (Cement) |
| BLS `WPU1322` values, 14 months across 2016–2026 | **12 of 14 identical to the thousandth.** The two differences are June and July 2026 (ours 357.838 and 357.489; FRED now 357.572 and 355.665). Both are preliminary (`is_preliminary = TRUE`) in our data. Consistent with BLS revising preliminary values; the cause was **not** confirmed against a vintage archive (ALFRED) |
| Census Commercial (`03XX`) vs. FRED `TLCOMCON`, all 126 months | **124 of 126 identical.** Differences: May 2026 (ours 10,336; FRED 10,425) and June 2026 (ours 10,460; FRED 10,568) — the two most recent months at pull time. Yearly sums for 2016–2025 and January–April 2026 are identical |
| Census Power (`11XX`) vs. FRED `TLPWRCON`, all 126 months | **124 of 126 identical.** Yearly sums for 2016–2025 and Jan–Apr 2026 identical. Differences: May and June 2026 (ours 29,826 combined; FRED now 30,296) |
| Census Manufacturing (`20IX`) vs. FRED `TLMFGCON`, all 126 months | **124 of 126 identical.** Yearly sums for 2016–2025 and Jan–Apr 2026 identical. Differences: May and June 2026 (ours 29,188 combined; FRED now 28,976) |
| Census unit | FRED lists the series in Millions of Dollars, not seasonally adjusted — confirms the assumed unit for the Commercial series |

**What this does and does not establish.** It is strong value-level evidence
that `03XX`, `11XX` and `20IX` are Commercial, Power and Manufacturing total
construction spending, unadjusted, in millions of dollars — far stronger than
the two-month cross-reference in Census Decision 1. It does not address `02XX`
or `12XX` (not landed), and it is not the authoritative code table. Under
Decision 17 all three `category_verified` flags are TRUE.

**Not yet done:** the other six BLS series; USGS cement against the MCS 2026
report; any direct comparison at bls.gov or census.gov; the Census zipped
dataset for the disputed codes.

**Method note for next time.** Compare settled months first. A recent month can
legitimately differ because the publisher revised it after the pull, and the
mismatch is then the pipeline working, not failing.

### Known debt — Stage 5

The `CASE` expression exists in **three places** in
`sql/05_staging_usgs_mcs_cement.sql`: once in the view, once in each of two
commented diagnostic queries. They drifted during this work — a diagnostic was
updated and the view was not, and the diagnostic kept returning correct numbers
from its own copy while the deployed view was stale. Caught by `GET_DDL`. The
production fix is a UDF called by all three; deliberately not done under deadline.

The same pattern recurs, deliberately and visibly, in
`sql/07_mart_fact_production.sql`: the `statistic_map` list exists once in the
view and once in verification check 3, because a CTE cannot be referenced from
outside its view. Flagged in the file itself. The fix is to promote the map to a
small table in the MART schema that both the view and the check read — worth
doing when a second commodity or a rewording forces an edit to the map.

`dim_time_monthly` covers 2016-01 to 2026-12 by a hard-coded `ROWCOUNT`. It needs
raising by 12 each year, and nothing fails when the range runs out except the
`-1` unknown member filling up — caught by anti-join check 8 in
`sql/09_mart_fact_price.sql`. The alternative (deriving the range from the data)
was rejected in Decision 12.

The `fact_price` precedence rule (Decision 9) is untested on real overlapping
loads. It runs correctly on one load, which proves only that it does not damage a
single-load result.

---

## Stage 6 — BI Layer Decisions

### Decision 1 — Annual comparison built as a MART view, not in Power BI

**Chosen:** `MART.rpt_annual_cement_market` aggregates each fact to calendar
year on its own, then joins the yearly results on `year` (a drill-across). Charts
and BI tools read it as one table at year grain.

**Rejected alternative:** load the facts into Power BI and do the annual
comparison in DAX, with a year bridge table relating the monthly and annual
dimensions.

**Why:** the logic sits in version-controlled SQL next to the facts it reads,
any client gets the same numbers, and the BI layer stays thin. It also keeps the
rule from Stage 3 Decision 1 in one place: monthly and annual facts never meet
until each has been reduced to the shared grain. A year bridge inside Power BI
would let a monthly axis repeat an annual USGS figure twelve times.

**Cost accepted:** one BI-shaped object in MART that must be kept in step when
a fact view changes. `is_complete_year` is part of the contract: the current
year is partial on both monthly sources.

### Decision 2 — BI access through a read-only `MART_READER` role

**Chosen:** a role with `USAGE` on the warehouse, database and MART schema, and
`SELECT` on current and future MART tables and views. Nothing on RAW or STAGING.

**Rejected alternative:** connect BI tools with the role that owns the objects.

**Why:** least privilege. A BI tool only reads MART, so a leaked BI credential
exposes published, public-source data and cannot create, drop or load anything.
The fact views read STAGING with their owner's privileges, so the role needs
grants on MART only.

**Cost accepted:** one more role and its grants. Future grants keep new MART
objects visible without re-granting.

### Decision 3 — Charts rendered from committed CSV snapshots, not live from Snowflake

**Chosen:** the two README charts are drawn by `dashboard/render_charts.py` from
CSV snapshots of `rpt_annual_cement_market` and `fact_price`, committed in
`dashboard/data/`.

**Rejected alternatives:** a script that queries Snowflake directly, or an
interactive Power BI report as the first visual layer.

**Why:** anyone who clones the repo can reproduce the images without a Snowflake
account or credentials, and a reader sees the results on the README page with no
software. The data is small (80 rows) and public-source. Power BI stays the next
step, and Decisions 1 and 2 are already the warehouse side of it.

**Cost accepted:** a snapshot goes stale. It must be re-exported after each load,
and nothing enforces that. Before commit, each CSV column's sum was checked
against the same sum computed in Snowflake.

## Open items carried forward

1. **USGS release precedence — descoped (Decision 18).** No second release will
   be loaded for this project. Guard: verification check 5 in
   `sql/07_mart_fact_production.sql` fails the moment a duplicate appears.

2. **Census `category_code` verification — OPEN, deliberately descoped.**
   Census's Economic Indicator Division indicated `02XX` is Office and `12XX` is
   Highway and Street, contradicting the empirically inferred mapping — though
   `12XX`'s own observed data tracked Office's published figures, which is
   evidence against the reply (see Census Decision 1 amendment). The zipped VIP
   dataset at `https://www.census.gov/econ_getzippedfile/?programCode=VIP`
   (index: `https://www.census.gov/econ_datasets/`) is the tiebreaker, not the
   email. **Current effect:** `fact_spend` is built on the three landed categories,
   all `category_verified = FALSE` (Decision 14). Neither disputed code is landed.
   Correcting a *landed* code's label is an edit to the STAGING map, not a
   re-fetch (Decision 13). Highway and Street, once its code is settled, needs one
   map line and one load. `fact_spend` is not a total until then.

   *2026-10-02:* Commercial (`03XX`) matches FRED's republication of the Census
   Commercial series in 124 of 126 months. Strong value-level evidence for
   `03XX`; it does not address `02XX`/`12XX`, which are not landed. Flags left
   FALSE pending a decision on whether this suffices.

   *2026-10-02, Decision 17:* the three landed categories are verified at the
   value level against a republication of the Census series, and their flags are
   TRUE. **Still open:** the disputed codes `02XX` and `12XX` (not landed) and
   the check against Census's zipped dataset, which would be the authoritative
   answer.

3. **Stage 5 transform layer — complete (2026-10-02).** USGS, BLS and Census each
   have a STAGING view and a MART fact view; four dimensions are built. Remaining
   work is verification and documentation, not construction.

4. **Read-only verification role for the AI assistant.** `CLAUDE_MCP_ROLE` is
   read-only: `USAGE` on the database and the `STAGING`, `MART`, `PUBLIC` and
   `RAW` schemas, `SELECT` on `RAW.BLS_PPI_RAW`, and `SELECT` on future views in
   `STAGING` and future tables and views in `MART`. It has no create or write
   privileges, so the assistant can verify objects but every deployment runs
   under my own role. Widen `RAW` access
   one table at a time as each source is built (`CENSUS_VIP_RAW` next).

5. **Publisher verification — partly done.** BLS `WPU1322` and all three Census
   categories were compared against FRED's republication (see "independent spot
   checks"). Remaining: the other six BLS series, USGS against the MCS 2026
   report, and direct comparison at bls.gov and census.gov.

6. **USGS file — likely unchanged, unconfirmed.** `MCS2026_Commodities_Data.csv`
   was loaded 2026-09-08. Its size, 3.04 MiB, matches the file ScienceBase
   currently lists, and its metadata date is 2026-02-06. The USGS data release
   page shows September 18, 2026; what that date means is **not known**. Closed
   by comparing the SHA-256 of a fresh download against the loaded file. If the
   file differs, load nothing until the difference is understood — a changed
   file under the same name would be silently skipped by `COPY INTO`.

**Resolved since the last revision:**
- Table storage class — permanent throughout (Decision 16).
- `fact_production` grain — Decision 3.
- Surrogate key generation strategy — Decision 6.
- Census and USGS landing SQL existing only in Snowsight — exported to
  `sql/03_` and `sql/04_` and committed.
- `schema.md` diverging from the built objects — reconciled in `docs/schema.md`.
- BLS PPI STAGING view, `dim_time_monthly`, `fact_price` — Decisions 9–12.
- Stale "expect 9 rows" comment on `dim_material` in
  `sql/06_mart_dimensions.sql` corrected to 8.
- Census STAGING view and `fact_spend` — Decisions 13–15.
- Census range against `dim_time_monthly` — within range (2016-01 to 2026-06).
