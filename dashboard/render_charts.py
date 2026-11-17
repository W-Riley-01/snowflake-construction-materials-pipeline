"""Render the README charts from the MART snapshot CSVs.

What this does, in two sentences: reads the two CSV snapshots in
dashboard/data/ (exported from MART.rpt_annual_cement_market and
MART.fact_price) and draws two static PNGs into dashboard/charts/.
It reads CSVs rather than Snowflake so anyone who clones the repo can
reproduce the charts without an account or credentials.

Run from the repo root:  python dashboard/render_charts.py
Needs: matplotlib  (pip install matplotlib)
"""

import csv
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "charts")

# Validated categorical order (blue, orange, aqua, yellow, magenta, green).
# Hues are assigned in this fixed order, never cycled.
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300"]
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
GRID = "#e6e5e1"

SOURCE_OVERVIEW = ("Sources: BLS Producer Price Index; Census Value of Construction Put in Place, "
                   "not seasonally adjusted; USGS Mineral Commodity Summaries 2026.\n"
                   "Complete calendar years only. Modelled in Snowflake: MART.rpt_annual_cement_market.")
SOURCE_PRICES = ("Source: BLS Producer Price Index, cement (WPU1322) and concrete products (WPU1331-WPU1335).\n"
                 "Complete calendar years only. Modelled in Snowflake: MART.fact_price.")


def read_csv(name):
    # Header names are lower-cased: a Snowsight CSV download uses upper case.
    with open(os.path.join(DATA, name), newline="", encoding="utf-8-sig") as fh:
        return [{k.strip().lower(): v for k, v in row.items()} for row in csv.DictReader(fh)]


def num(value):
    return float(value) if value not in ("", None) else None


def style_axes(ax, title=None, unit=None):
    ax.set_facecolor(SURFACE)
    if title:
        ax.set_title(title, loc="left", fontsize=11.5, color=INK, fontweight="bold", pad=22)
    if unit:
        ax.text(0, 1.02, unit, transform=ax.transAxes, fontsize=9, color=INK_2, va="bottom")
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color("#b9b8b2")
    ax.tick_params(colors=INK_2, labelsize=9, length=0)


def line(ax, xs, ys, color, label=None, end_label=True, fmt="{:,.0f}"):
    pts = [(x, y) for x, y in zip(xs, ys) if y is not None]
    px, py = zip(*pts)
    ax.plot(px, py, color=color, linewidth=2.2, marker="o", markersize=5.5,
            markeredgecolor=SURFACE, markeredgewidth=1.2, solid_capstyle="round", zorder=3)
    if end_label:
        text = f"{label}  {fmt.format(py[-1])}" if label else fmt.format(py[-1])
        ax.annotate(text, (px[-1], py[-1]), xytext=(8, 0), textcoords="offset points",
                    va="center", fontsize=9, color=INK)


def market_overview(rows):
    years = [int(r["year"]) for r in rows]
    col = lambda k: [num(r[k]) for r in rows]  # noqa: E731

    fig, axes = plt.subplots(2, 2, figsize=(13, 8.6), facecolor=SURFACE)
    fig.subplots_adjust(left=0.06, right=0.88, top=0.86, bottom=0.12, hspace=0.62, wspace=0.42)
    fig.suptitle("U.S. cement & concrete market, 2016–2025", x=0.06, y=0.975, ha="left",
                 fontsize=15, fontweight="bold", color=INK)
    fig.text(0.06, 0.925, "Prices climbed while domestic cement production fell; "
             "imports made up most of the difference and factory construction boomed.",
             fontsize=10.5, color=INK_2)

    # (a) Cement price index
    ax = axes[0, 0]
    ppi = col("cement_ppi_avg")
    base, last = ppi[years.index(2020)], ppi[-1]
    style_axes(ax, f"Cement prices up {round(100 * (last - base) / base)}% since 2020",
               "BLS PPI, cement (WPU1322), annual average of monthly index")
    line(ax, years, ppi, SERIES[0], fmt="{:,.1f}")
    ax.annotate(f"{base:,.1f}", (2020, base), xytext=(0, -16), textcoords="offset points",
                ha="center", fontsize=9, color=INK)

    # (b) Construction spend by category, $B
    ax = axes[0, 1]
    style_axes(ax, "Manufacturing construction nearly tripled, 2021–2024",
               "Census VIP spend, $ billions per year (3 of 4 planned categories)")
    for i, (key, name) in enumerate([("spend_manufacturing_musd", "Manufacturing"),
                                     ("spend_power_musd", "Power"),
                                     ("spend_commercial_musd", "Commercial")]):
        line(ax, years, [v / 1000 for v in col(key)], SERIES[i], label=name)

    # (c) Consumption vs production vs imports, Mt (2021-2025)
    ax = axes[1, 0]
    style_axes(ax, "Imports make up most of the gap between use and production",
               "USGS, U.S. cement, million metric tons")
    for i, (key, name) in enumerate([("apparent_consumption_kt", "Consumption"),
                                     ("cement_production_kt", "Production"),
                                     ("imports_cement_kt", "Imports")]):
        line(ax, years, [v / 1000 if v is not None else None for v in col(key)], SERIES[i],
             label=name, fmt="{:,.1f}")
    ax.set_ylim(0, 125)

    # (d) Average mill price
    ax = axes[1, 1]
    mill = [v for v in col("avg_mill_price_usd_per_t") if v is not None]
    style_axes(ax, f"Average mill price up {round(100 * (mill[-1] - mill[0]) / mill[0])}% since 2021",
               "USGS, U.S. dollars per metric ton")
    line(ax, years, col("avg_mill_price_usd_per_t"), SERIES[0], fmt="${:,.0f}")

    for ax in axes.flat:
        ax.set_xlim(2015.5, 2025.5)
        ax.set_xticks(range(2016, 2026, 1))
        ax.set_xticklabels([str(y) if y % 2 == 0 or y == 2025 else "" for y in range(2016, 2026)])
    for ax in axes[1, :]:
        ax.set_xlim(2020.6, 2025.4)
        ax.set_xticks(range(2021, 2026))
        ax.set_xticklabels([str(y) for y in range(2021, 2026)])

    fig.text(0.06, 0.03, SOURCE_OVERVIEW, fontsize=8, color=INK_2, va="bottom")
    fig.savefig(os.path.join(OUT, "01_market_overview.png"), dpi=150, facecolor=SURFACE)
    plt.close(fig)


def price_by_product(rows):
    by_name = {}
    for r in rows:
        if r["series_id"] == "WPU133":  # parent aggregate; the chart shows its components
            continue
        by_name.setdefault(r["material_name"], []).append((int(r["year"]), float(r["ppi_avg"])))

    rebased = {}
    for name, pts in by_name.items():
        pts.sort()
        base = dict(pts)[2020]
        rebased[name] = [(y, 100 * v / base) for y, v in pts]
    # Legend and color order follow the 2025 value, highest first, so the
    # legend reads top to bottom in the same order as the line ends.
    order = sorted(rebased, key=lambda n: rebased[n][-1][1], reverse=True)
    low, high = rebased[order[-1]][-1][1] - 100, rebased[order[0]][-1][1] - 100

    fig, ax = plt.subplots(figsize=(13, 6.6), facecolor=SURFACE)
    fig.subplots_adjust(left=0.06, right=0.70, top=0.86, bottom=0.15)
    fig.suptitle("Every cement and concrete price index rose "
                 f"{round(low)}–{round(high)}% from 2020 to 2025",
                 x=0.06, y=0.965, ha="left", fontsize=15, fontweight="bold", color=INK)
    fig.text(0.06, 0.895, "BLS Producer Price Index, annual average of monthly values, "
             "each series rebased so 2020 = 100", fontsize=10.5, color=INK_2)
    style_axes(ax)
    ax.axhline(100, color="#b9b8b2", linewidth=1, zorder=1)
    for i, name in enumerate(order):
        xs, ys = zip(*rebased[name])
        ax.plot(xs, ys, color=SERIES[i], linewidth=2.2, marker="o", markersize=5,
                markeredgecolor=SURFACE, markeredgewidth=1.2, zorder=3,
                label=f"{name}  +{ys[-1] - 100:.0f}%")
    ax.set_xlim(2015.6, 2025.4)
    ax.set_xticks(range(2016, 2026))
    leg = ax.legend(loc="center left", bbox_to_anchor=(1.02, 0.55), frameon=False, fontsize=10,
                    title="Change, 2020 to 2025", title_fontsize=10, labelcolor=INK)
    leg.get_title().set_color(INK_2)
    leg._legend_box.align = "left"
    fig.text(0.06, 0.03, SOURCE_PRICES, fontsize=8, color=INK_2, va="bottom")
    fig.savefig(os.path.join(OUT, "02_price_by_product.png"), dpi=150, facecolor=SURFACE)
    plt.close(fig)


def main():
    os.makedirs(OUT, exist_ok=True)
    market_overview(read_csv("annual_market.csv"))
    price_by_product(read_csv("annual_ppi_by_product.csv"))
    print(f"Wrote charts to {OUT}")


if __name__ == "__main__":
    main()
