# Power BI report — U.S. Cement & Concrete Market

A three-page Power BI report on the MART layer. It answers the question in the
original project plan: how cement and concrete prices, construction demand and
domestic production move relative to each other.

![Market overview](screenshots/01_market_overview.png)
![Price indices](screenshots/02_price_indices.png)
![Construction spend](screenshots/03_construction_spend.png)

The `.pbix` file is not published. In Import mode it embeds the Snowflake account
host in its query definitions, and this repo publishes no account identifiers.
The model and every measure are documented below, so the report can be rebuilt
from this page.

## Pages

| Page | Grain | Source objects | What it shows |
|---|---|---|---|
| Market overview | Annual | `rpt_annual_cement_market` | Headline changes; production vs imports vs mill price |
| Price indices | Monthly | `fact_price`, `dim_material`, `dim_time_monthly` | Seven BLS PPI series, 2016 onward |
| Construction spend | Monthly + annual | `fact_spend`, `dim_time_monthly`, `rpt_annual_cement_market` | Commercial, Manufacturing and Power spend |

## Data model

**Connection:** native Snowflake connector, **Import** mode, role **`MART_READER`**
(read-only on MART; see `sql/12_mart_reporting.sql`).

**Tables loaded:** `DIM_MATERIAL`, `DIM_TIME_MONTHLY`, `FACT_PRICE`, `FACT_SPEND`,
`RPT_ANNUAL_CEMENT_MARKET`.

**Relationships** (all one-to-many, single-direction filtering):

| From (one) | To (many) | Key |
|---|---|---|
| `DIM_TIME_MONTHLY` | `FACT_PRICE` | `TIME_KEY` |
| `DIM_TIME_MONTHLY` | `FACT_SPEND` | `TIME_KEY` |
| `DIM_MATERIAL` | `FACT_PRICE` | `MATERIAL_KEY` |

`RPT_ANNUAL_CEMENT_MARKET` has **no relationships**, deliberately. It is already
at year grain. Relating it to the monthly dimension would let a monthly axis
repeat an annual USGS figure twelve times, the same fan-out the warehouse
prevents by keeping `dim_time_annual` and `dim_time_monthly` apart.

**Calculated column** on `DIM_TIME_MONTHLY`, for a continuous date axis. The
unknown member (`TIME_KEY = -1`) gets a blank date instead of an error:

```DAX
Month Start =
IF (
    DIM_TIME_MONTHLY[TIME_KEY] > 0,
    DATE ( DIM_TIME_MONTHLY[YEAR], DIM_TIME_MONTHLY[MONTH], 1 )
)
```

## Measures

Each headline measure captures the comparison year in a variable before
`CALCULATE`. Referencing a measure inside a `CALCULATE` filter would be
evaluated per row through context transition and return the wrong year.

```DAX
Avg Price Index = AVERAGE ( FACT_PRICE[PRICE_INDEX] )

Spend ($M) = SUM ( FACT_SPEND[SPEND_AMOUNT] )

Latest Complete Year =
CALCULATE (
    MAX ( RPT_ANNUAL_CEMENT_MARKET[YEAR] ),
    RPT_ANNUAL_CEMENT_MARKET[IS_COMPLETE_YEAR] = TRUE ()
)

Latest Production Year =
CALCULATE (
    MAX ( RPT_ANNUAL_CEMENT_MARKET[YEAR] ),
    NOT ISBLANK ( RPT_ANNUAL_CEMENT_MARKET[CEMENT_PRODUCTION_KT] )
)

Cement PPI Change vs 2020 =
VAR LatestYear = [Latest Complete Year]
VAR Base =
    CALCULATE ( MAX ( RPT_ANNUAL_CEMENT_MARKET[CEMENT_PPI_AVG] ), RPT_ANNUAL_CEMENT_MARKET[YEAR] = 2020 )
VAR Latest =
    CALCULATE ( MAX ( RPT_ANNUAL_CEMENT_MARKET[CEMENT_PPI_AVG] ), RPT_ANNUAL_CEMENT_MARKET[YEAR] = LatestYear )
RETURN
    DIVIDE ( Latest - Base, Base )

Manufacturing Spend Change vs 2021 =
VAR LatestYear = [Latest Complete Year]
VAR Base =
    CALCULATE ( MAX ( RPT_ANNUAL_CEMENT_MARKET[SPEND_MANUFACTURING_MUSD] ), RPT_ANNUAL_CEMENT_MARKET[YEAR] = 2021 )
VAR Latest =
    CALCULATE ( MAX ( RPT_ANNUAL_CEMENT_MARKET[SPEND_MANUFACTURING_MUSD] ), RPT_ANNUAL_CEMENT_MARKET[YEAR] = LatestYear )
RETURN
    DIVIDE ( Latest - Base, Base )

Cement Production Change vs 2021 =
VAR LatestYear = [Latest Production Year]
VAR Base =
    CALCULATE ( MAX ( RPT_ANNUAL_CEMENT_MARKET[CEMENT_PRODUCTION_KT] ), RPT_ANNUAL_CEMENT_MARKET[YEAR] = 2021 )
VAR Latest =
    CALCULATE ( MAX ( RPT_ANNUAL_CEMENT_MARKET[CEMENT_PRODUCTION_KT] ), RPT_ANNUAL_CEMENT_MARKET[YEAR] = LatestYear )
RETURN
    DIVIDE ( Latest - Base, Base )

Net Import Reliance (Latest) =
VAR LatestYear = [Latest Production Year]
RETURN
    CALCULATE ( MAX ( RPT_ANNUAL_CEMENT_MARKET[NET_IMPORT_RELIANCE_PCT] ), RPT_ANNUAL_CEMENT_MARKET[YEAR] = LatestYear ) / 100
```

Format the four "Change" and "Reliance" measures as **Percentage, 0 decimals**.
`2020` is the base for prices because it is the last full year before the
2021–2024 run-up. `2021` is the base for spend and production because USGS
coverage starts there.

## Rebuilding the report

### 1. Prerequisites

- Run `sql/12_mart_reporting.sql` in Snowsight (as the role that owns MART).
  It creates `rpt_annual_cement_market` and the `MART_READER` role.
- Power BI Desktop, current release (the Microsoft Store version updates itself).
  Key-pair sign-in needs a build from late 2025 or newer.

### 2. Connect

1. **Get data → Snowflake.**
2. **Server:** `<orgname>-<account_name>.snowflakecomputing.com`
   **Warehouse:** `CONCRETE_PIPELINE_WH`
3. **Advanced options → Role name:** `MART_READER`
4. **Data connectivity mode:** Import.
5. **Sign in.** Try **Snowflake** (user name and password) first. Trial accounts
   are exempt from Snowflake's MFA enforcement, so a password alone may work. If it
   is refused for MFA, use key-pair sign-in (below).
6. **Navigator:** `CONCRETE_PIPELINE` → `MART` → tick the five tables listed under
   *Data model* → **Load**.

### 3. Key-pair sign-in (only if the password is refused)

Generate an encrypted key **outside this repo**. Git for Windows ships OpenSSL.

```powershell
$ossl = "C:\Program Files\Git\usr\bin\openssl.exe"
New-Item -ItemType Directory -Force "$env:USERPROFILE\.snowflake" | Out-Null
cd "$env:USERPROFILE\.snowflake"
& $ossl genrsa -out rsa_key_plain.pem 2048
& $ossl pkcs8 -topk8 -v2 aes-256-cbc -in rsa_key_plain.pem -out rsa_key.p8   # prompts for a passphrase
& $ossl rsa -in rsa_key.p8 -pubout -out rsa_key.pub                         # prompts for it again
Remove-Item rsa_key_plain.pem
Get-Content rsa_key.pub
```

Register the public key in Snowsight. Paste the body of `rsa_key.pub` **without**
the `-----BEGIN/END PUBLIC KEY-----` lines and without line breaks:

```sql
ALTER USER <your_user> SET RSA_PUBLIC_KEY = '<public key body>';
```

In Power BI, choose the **Key Pair** tab. Enter the user name, paste the **full**
contents of `rsa_key.p8` (including its `BEGIN`/`END` lines; the text, not the
file path), and the passphrase.

### 4. Model

1. **Model view:** create the three relationships in the table above. Delete any
   relationship Power BI auto-detected for `RPT_ANNUAL_CEMENT_MARKET`.
2. Add the `Month Start` column to `DIM_TIME_MONTHLY`. In **Column tools**, set it
   to **Date**.
3. Add the measures. **Home → New measure**, one per block above.

### 5. Visuals

**Page 1 — Market overview**
- Four **Card** visuals: the four Change and Reliance measures.
- **Line and clustered column chart:** X-axis `RPT…[YEAR]`. Columns:
  `CEMENT_PRODUCTION_KT`, `IMPORTS_CEMENT_KT`. Line: `AVG_MILL_PRICE_USD_PER_T`.
  Visual filter: `CEMENT_PRODUCTION_KT` *is not blank*.
- **Line chart:** X-axis `YEAR`. Y: `CEMENT_PPI_AVG`, `READY_MIX_PPI_AVG`.
  Visual filter: `IS_COMPLETE_YEAR` = True.

**Page 2 — Price indices**
- **Line chart:** X-axis `DIM_TIME_MONTHLY[Month Start]`, Y `[Avg Price Index]`,
  Legend `DIM_MATERIAL[MATERIAL_NAME]`. Visual filter: `MATERIAL_NAME` is not `Unknown`.
- **Slicer** on `MATERIAL_NAME`. **Slicer** on `Month Start` (Between).

**Page 3 — Construction spend**
- **Line chart:** X-axis `Month Start`, Y `[Spend ($M)]`, Legend
  `FACT_SPEND[CONSTRUCTION_CATEGORY]`.
- **Clustered column chart:** X-axis `RPT…[YEAR]`. Y: the three
  `SPEND_*_MUSD` columns. Visual filter: `IS_COMPLETE_YEAR` = True.
- **Text box:** *Three of four planned Census categories, not seasonally
  adjusted. Not total construction spending.*

Footer text box on every page: *Sources: BLS Producer Price Index; Census Value
of Construction Put in Place; USGS Mineral Commodity Summaries 2026. Modelled in
Snowflake; MART layer.*

### 6. Export

**File → Export → Export to PDF**, saved as `dashboard/concrete_cement_market.pdf`.
The page images above are rendered from that PDF.
