"""
Concrete & Cement Materials Market Pipeline
ONE-OFF DIAGNOSTIC -- not part of the pipeline itself.

What this does, in two sentences: pulls VIP's live Not-Seasonally-
Adjusted Total ("T") values for every 00XX-15XX category_code for
December 2024, then matches each returned dollar figure against
Census's own PUBLISHED Table 2 (NSA) values for that same month
(from pr202412.pdf) by nearest value -- not by code position.

Usage (run from repo root, same .env as the other scripts):
    python match_vip_category_codes.py
"""

import os
import sys

import requests
from dotenv import load_dotenv

VIP_ENDPOINT = "https://api.census.gov/data/timeseries/eits/vip"

# Published NOT-SEASONALLY-ADJUSTED monthly figures, December 2024,
# from Census's own press release (pr202412.pdf, Table 2) -- ground truth.
PUBLISHED_DEC_2024_NSA = {
    "Lodging": 1891,
    "Office": 8266,
    "Commercial": 9860,
    "Health care": 5578,
    "Educational": 9792,
    "Religious": 355,
    "Public safety": 1511,
    "Amusement and recreation": 3224,
    "Transportation": 5473,
    "Communication": 2714,
    "Power": 12323,
    "Highway and street": 8361,
    "Sewage and waste disposal": 3536,
    "Water supply": 2555,
    "Conservation and development": 954,
    "Manufacturing": 20406,
}

CANDIDATE_CODES = [f"{i:02d}XX" for i in range(16)]  # 00XX through 15XX


def main():
    load_dotenv()

    api_key = os.environ.get("CENSUS_API_KEY")
    if not api_key:
        sys.exit(
            "CENSUS_API_KEY not set. Copy .env.example to .env at the repo "
            "root and fill in your registered Census API key."
        )

    live_values = {}  # category_code -> cell_value (float)

    for code in CANDIDATE_CODES:
        params = {
            "get": "cell_value,category_code,time_slot_id",
            "for": "us",
            "time": "2024-12",
            "category_code": code,
            "data_type_code": "T",
            "seasonally_adj": "no",
            "key": api_key,
        }
        response = requests.get(VIP_ENDPOINT, params=params, timeout=30)
        if response.status_code != 200:
            print(f"{code}: ERROR {response.status_code} -- {response.text[:100]}")
            continue

        rows = response.json()
        header, data_rows = rows[0], rows[1:]
        val_idx = header.index("cell_value")
        if data_rows:
            try:
                live_values[code] = float(data_rows[0][val_idx])
            except ValueError:
                pass

    print(f"Pulled {len(live_values)} live values. Matching against published NSA figures:\n")
    print(f"{'Code':7s} {'Live value':>11s}  {'Best match':30s} {'Published':>10s} {'Diff %':>7s}")
    print("-" * 75)

    unmatched_labels = dict(PUBLISHED_DEC_2024_NSA)
    for code, live_val in sorted(live_values.items()):
        if not unmatched_labels:
            break
        best_label = min(
            unmatched_labels,
            key=lambda lbl: abs(unmatched_labels[lbl] - live_val)
        )
        published_val = unmatched_labels[best_label]
        diff_pct = abs(published_val - live_val) / published_val * 100
        flag = "" if diff_pct < 5 else "  <-- CHECK, large diff"
        print(f"{code:7s} {live_val:>11,.0f}  {best_label:30s} {published_val:>10,} {diff_pct:>6.1f}%{flag}")
        del unmatched_labels[best_label]  # each label used once

    if unmatched_labels:
        print(f"\nUnmatched labels (no close live value found): {list(unmatched_labels.keys())}")


if __name__ == "__main__":
    main()