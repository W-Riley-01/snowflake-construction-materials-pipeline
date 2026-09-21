"""
Concrete & Cement Materials Market Pipeline
Stage 4: Prototype -- fetch Census VIP series via API

What this does, in two sentences: makes one GET request per confirmed
category_code (the VIP API only accepts one category per call, unlike
BLS which accepts a list), then combines all categories' rows into a
single list and writes ONE timestamped JSON file -- keeping the
operational shape identical to fetch_bls_ppi.py (one script run, one
output file, one upload, one COPY INTO) even though the request shape
underneath had to differ.

Usage:
    Copy .env.example to .env at the repo root and fill in
    CENSUS_API_KEY with your registered key, then:
        pip install -r requirements.txt
        python scripts/fetch_census_vip.py
"""

import json
import os
import sys
from datetime import datetime

import requests
from dotenv import load_dotenv

# Category codes confirmed in data_sources.md (Stage 4) via live API
# cross-referencing against Census's own published press release tables.
# Highway and Street is deliberately NOT included -- its category_code
# is unresolved (inquiry sent to Census, see data_sources.md open items).
# This dict is category-agnostic to add to: once Highway and Street's
# code is confirmed, it gets one more line here, nothing else changes.
CATEGORY_CODES = {
    "03XX": "Commercial",
    "11XX": "Power",
    "20IX": "Manufacturing",
}

VIP_ENDPOINT = "https://api.census.gov/data/timeseries/eits/vip"

# Anchored to this script's own location, not the working directory --
# same fix already applied in upload_to_snowflake.py. A bare relative
# string here resolves against whatever directory you happened to launch
# the script from, which silently created a second, wrong data/ folder
# nested inside scripts/ when this script was run from PyCharm.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "data", "census_vip")


def fetch_category(code, label, api_key, start_year):
    """One API call for one category_code. Returns a list of row dicts."""
    params = {
        # "time" deliberately NOT in this list -- it's a predicate-only
        # variable (a filter, set below), not a selectable output column.
        # Census returns it automatically regardless.
        "get": "cell_value,category_code,data_type_code,seasonally_adj,time_slot_id",
        "for": "us",
        "category_code": code,
        "data_type_code": "T",
        "seasonally_adj": "no",
        "time": f"from {start_year}",
        "key": api_key,
    }
    response = requests.get(VIP_ENDPOINT, params=params, timeout=30)

    if response.status_code != 200:
        sys.exit(
            f"Census API request for {label} ({code}) failed: "
            f"{response.status_code} -- {response.text[:200]}"
        )

    rows = response.json()
    header, data_rows = rows[0], rows[1:]

    # Convert each [value, value, ...] row into a labeled dict using the
    # header row -- easier to work with downstream than positional lists,
    # and adds our own category_label for traceability without altering
    # any of the source's own returned fields.
    records = []
    for row in data_rows:
        record = dict(zip(header, row))
        record["category_label"] = label  # our own annotation, not from Census
        records.append(record)

    return records


def main():
    load_dotenv()

    api_key = os.environ.get("CENSUS_API_KEY")
    if not api_key:
        sys.exit(
            "CENSUS_API_KEY not set. Copy .env.example to .env at the repo "
            "root and fill in your registered Census API key."
        )

    current_year = datetime.now().year
    start_year = current_year - 10

    all_records = []
    for code, label in CATEGORY_CODES.items():
        records = fetch_category(code, label, api_key, start_year)
        print(f"Fetched {len(records)} rows for {label} ({code})")
        all_records.extend(records)

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    out_path = os.path.join(
        OUTPUT_DIR, f"census_vip_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    )
    with open(out_path, "w") as f:
        json.dump(all_records, f, indent=2)

    print(f"\nWrote {len(all_records)} total rows across {len(CATEGORY_CODES)} categories to {out_path}")
    print("Next: upload this file into RAW.CENSUS_VIP_STAGE via the upload script, then run the COPY INTO.")
    print("Highway and Street is NOT included -- pending category_code confirmation from Census.")


if __name__ == "__main__":
    main()