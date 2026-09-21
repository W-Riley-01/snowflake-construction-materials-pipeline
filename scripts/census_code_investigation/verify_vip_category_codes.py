"""
Concrete & Cement Materials Market Pipeline
ONE-OFF DIAGNOSTIC -- not part of the pipeline itself.

What this does, in two sentences: pulls VIP's own reported values for
four CANDIDATE category_codes (guessed from list-position in Census's
published category ordering, NOT yet confirmed) and prints them next
to the real, published NSA dollar figures from FRED for the same
categories and months. If they match, the candidate codes are
confirmed by hard evidence rather than list-position pattern-matching.

Usage (run from repo root, same .env as the other scripts):
    python verify_vip_category_codes.py
"""

import os
import sys

import requests
from dotenv import load_dotenv

VIP_ENDPOINT = "https://api.census.gov/data/timeseries/eits/vip"

# (candidate_code, human guess, month to test, known NSA value from FRED, FRED series)
CANDIDATES = [
    ("02XX", "Commercial",         "2026-01", 9335,  "TLCOMCON"),
    ("11XX", "Highway and Street", "2026-01", 7437,  "TLHWYCON"),
    ("10XX", "Power",              "2025-12", 13226, "TLPWRCON"),
    ("15XX", "Manufacturing",      "2025-12", 17015, "TLMFGCON"),
]


def main():
    load_dotenv()

    api_key = os.environ.get("CENSUS_API_KEY")
    if not api_key:
        sys.exit(
            "CENSUS_API_KEY not set. Copy .env.example to .env at the repo "
            "root and fill in your registered Census API key."
        )

    print(f"{'Candidate':10s} {'Guess':22s} {'Month':9s} {'API value':>10s} {'FRED value':>11s} {'Match?'}")
    print("-" * 80)

    for code, guess_label, month, fred_value, fred_series in CANDIDATES:
        params = {
            "get": "cell_value,category_code,data_type_code,seasonally_adj,time_slot_id",
            "for": "us",
            "time": month,
            "category_code": code,
            "data_type_code": "T",
            "seasonally_adj": "no",
            "key": api_key,
        }
        response = requests.get(VIP_ENDPOINT, params=params, timeout=30)

        if response.status_code != 200:
            print(f"{code:10s} {guess_label:22s} {month:9s}  ERROR: {response.status_code} -- {response.text[:100]}")
            continue

        rows = response.json()
        header, data_rows = rows[0], rows[1:]
        val_idx = header.index("cell_value")

        if not data_rows:
            print(f"{code:10s} {guess_label:22s} {month:9s}  (no rows returned)")
            continue

        api_value = data_rows[0][val_idx]
        try:
            api_value_num = float(api_value)
            match = "YES" if abs(api_value_num - fred_value) < 1 else "no"
        except ValueError:
            match = "?"

        print(f"{code:10s} {guess_label:22s} {month:9s} {api_value:>10s} {fred_value:>11,} {match} (FRED: {fred_series})")


if __name__ == "__main__":
    main()