"""
Concrete & Cement Materials Market Pipeline
Stage 4: Prototype -- fetch BLS PPI series via API v2

What this does, in two sentences: POSTs the seven WPU133-family
series IDs to the BLS Public Data API v2 endpoint and writes the
raw JSON response to a local file, unmodified. That file is what
gets uploaded into RAW.BLS_PPI_STAGE in Snowsight -- this script
does not touch Snowflake at all, it only talks to BLS.

Usage:
    Copy .env.example to .env at the repo root and fill in
    BLS_API_KEY with your registered key, then:
        pip install -r requirements.txt
        python scripts/fetch_bls_ppi.py
"""

import json
import os
import sys
from datetime import datetime

import requests
from dotenv import load_dotenv

# Series selected in data_sources.md -- full WPU133 "Concrete products" family.
SERIES_IDS = [
    "WPU133",    # Concrete products (parent index)
    "WPU1322",   # Cement
    "WPU1331",   # Concrete block and brick
    "WPU1332",   # Concrete pipe
    "WPU1333",   # Ready-mixed concrete
    "WPU1334",   # Precast concrete products
    "WPU1335",   # Prestressed concrete products
]

BLS_ENDPOINT = "https://api.bls.gov/publicAPI/v2/timeseries/data/"

# Anchored to this script's own location, not the working directory --
# same fix applied to fetch_census_vip.py and upload_to_snowflake.py.
# A bare relative string here resolves against whatever directory you
# happened to launch the script from, which is why a second, wrong
# data/bls_ppi/ folder ended up nested inside scripts/.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "data", "bls_ppi")


def main():
    load_dotenv()  # reads .env at the repo root into environment variables

    api_key = os.environ.get("BLS_API_KEY")
    if not api_key:
        sys.exit(
            "BLS_API_KEY not set. Copy .env.example to .env at the repo root "
            "and fill in your registered BLS API v2 key."
        )

    current_year = datetime.now().year
    payload = {
        "seriesid": SERIES_IDS,
        "startyear": str(current_year - 10),
        "endyear": str(current_year),
        "registrationkey": api_key,
    }

    response = requests.post(BLS_ENDPOINT, json=payload, timeout=30)
    response.raise_for_status()
    data = response.json()

    if data.get("status") != "REQUEST_SUCCEEDED":
        sys.exit(f"BLS API did not succeed: {data.get('status')} -- {data.get('message')}")

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    out_path = os.path.join(
        OUTPUT_DIR, f"bls_ppi_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    )
    with open(out_path, "w") as f:
        json.dump(data["Results"]["series"], f, indent=2)

    print(f"Wrote {len(data['Results']['series'])} series to {out_path}")
    print("Next: upload this file into RAW.BLS_PPI_STAGE via Snowsight, then run the COPY INTO.")


if __name__ == "__main__":
    main()