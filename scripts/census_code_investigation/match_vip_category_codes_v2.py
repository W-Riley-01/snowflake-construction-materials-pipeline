"""
Concrete & Cement Materials Market Pipeline
ONE-OFF DIAGNOSTIC -- not part of the pipeline itself.

What this does, in two sentences: (1) tests whether 20IX is actually
Manufacturing's code (a hypothesis from the previous run's mismatch),
and (2) re-matches 00XX-15XX against the CORRECT label set -- dropping
Manufacturing (it doesn't belong in this range) and adding Residential
(which does).

Usage (run from repo root, same .env as the other scripts):
    python match_vip_category_codes_v2.py
"""

import os
import sys

import requests
from dotenv import load_dotenv

VIP_ENDPOINT = "https://api.census.gov/data/timeseries/eits/vip"

# Published NOT-SEASONALLY-ADJUSTED monthly figures, December 2024,
# from Census's own press release (pr202412.pdf, Table 2).
PUBLISHED_DEC_2024_NSA = {
    "Residential": 66481,
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
    # Manufacturing deliberately excluded -- being tested separately as 20IX
}
MANUFACTURING_PUBLISHED = 20406

CANDIDATE_CODES = [f"{i:02d}XX" for i in range(16)]  # 00XX through 15XX


def fetch(code, api_key):
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
        return None, f"ERROR {response.status_code} -- {response.text[:100]}"
    rows = response.json()
    header, data_rows = rows[0], rows[1:]
    val_idx = header.index("cell_value")
    if not data_rows:
        return None, "(no rows)"
    try:
        return float(data_rows[0][val_idx]), None
    except ValueError:
        return None, "(non-numeric)"


def main():
    load_dotenv()
    api_key = os.environ.get("CENSUS_API_KEY")
    if not api_key:
        sys.exit("CENSUS_API_KEY not set.")

    # --- Test 1: is 20IX Manufacturing? ---
    val_20IX, err = fetch("20IX", api_key)
    print("=== Testing 20IX against Manufacturing (20,406) ===")
    if val_20IX is not None:
        diff_pct = abs(val_20IX - MANUFACTURING_PUBLISHED) / MANUFACTURING_PUBLISHED * 100
        verdict = "MATCH" if diff_pct < 5 else "no match"
        print(f"20IX live value: {val_20IX:,.0f}  vs published Manufacturing: {MANUFACTURING_PUBLISHED:,}  ({diff_pct:.1f}% diff) -- {verdict}")
    else:
        print(f"20IX: {err}")

    # --- Test 2: re-match 00XX-15XX with corrected label set ---
    print("\n=== Re-matching 00XX-15XX (Manufacturing removed, Residential added) ===")
    live_values = {}
    for code in CANDIDATE_CODES:
        val, err = fetch(code, api_key)
        if val is not None:
            live_values[code] = val
        else:
            print(f"{code}: {err}")

    print(f"\n{'Code':7s} {'Live value':>11s}  {'Best match':30s} {'Published':>10s} {'Diff %':>7s}")
    print("-" * 75)

    unmatched_labels = dict(PUBLISHED_DEC_2024_NSA)
    for code, live_val in sorted(live_values.items()):
        if not unmatched_labels:
            break
        best_label = min(unmatched_labels, key=lambda lbl: abs(unmatched_labels[lbl] - live_val))
        published_val = unmatched_labels[best_label]
        diff_pct = abs(published_val - live_val) / published_val * 100
        flag = "" if diff_pct < 5 else "  <-- CHECK, large diff"
        print(f"{code:7s} {live_val:>11,.0f}  {best_label:30s} {published_val:>10,} {diff_pct:>6.1f}%{flag}")
        del unmatched_labels[best_label]

    if unmatched_labels:
        print(f"\nUnmatched labels: {list(unmatched_labels.keys())}")


if __name__ == "__main__":
    main()