"""
Concrete & Cement Materials Market Pipeline
ONE-OFF DIAGNOSTIC -- not part of the pipeline itself.

What this does, in two sentences: pulls September 2024 (a high-highway-
spending month) values for the four still-ambiguous candidate codes and
compares each against its own December 2024 value already collected.
Highway and Street has a huge, distinctive seasonal swing (+82% Dec->Sep
per Census's own published figures) that no other category shares --
whichever code shows that same swing is confirmed as Highway and Street.

Usage (run from repo root, same .env as the other scripts):
    python seasonal_fingerprint.py
"""

import os
import sys

import requests
from dotenv import load_dotenv

VIP_ENDPOINT = "https://api.census.gov/data/timeseries/eits/vip"

# Already-known December 2024 live values, from the prior diagnostic run.
DEC_2024_LIVE = {
    "02XX": 9295,
    "03XX": 10395,
    "05XX": 10679,
    "11XX": 13990,
}

# Published NSA September 2024 figures, for reference (pr202409.pdf, Table 2)
PUBLISHED_SEP_2024 = {
    "Commercial": 10972,
    "Educational": 11269,
    "Power": 12466,
    "Highway and street": 15191,
}


def main():
    load_dotenv()
    api_key = os.environ.get("CENSUS_API_KEY")
    if not api_key:
        sys.exit("CENSUS_API_KEY not set.")

    print(f"{'Code':7s} {'Dec 2024':>10s} {'Sep 2024':>10s} {'Change %':>9s}  Best fingerprint match")
    print("-" * 80)

    for code, dec_val in DEC_2024_LIVE.items():
        params = {
            "get": "cell_value,category_code,time_slot_id",
            "for": "us",
            "time": "2024-09",
            "category_code": code,
            "data_type_code": "T",
            "seasonally_adj": "no",
            "key": api_key,
        }
        response = requests.get(VIP_ENDPOINT, params=params, timeout=30)
        if response.status_code != 200:
            print(f"{code:7s} ERROR {response.status_code} -- {response.text[:80]}")
            continue

        rows = response.json()
        header, data_rows = rows[0], rows[1:]
        val_idx = header.index("cell_value")
        if not data_rows:
            print(f"{code:7s} (no rows)")
            continue

        sep_val = float(data_rows[0][val_idx])
        change_pct = (sep_val - dec_val) / dec_val * 100

        # Which known category's Dec->Sep swing does this most resemble?
        best_guess = min(
            PUBLISHED_SEP_2024,
            key=lambda label: abs(sep_val - PUBLISHED_SEP_2024[label])
        )

        print(f"{code:7s} {dec_val:>10,.0f} {sep_val:>10,.0f} {change_pct:>8.1f}%  {best_guess}")


if __name__ == "__main__":
    main()