"""
Concrete & Cement Materials Market Pipeline
ONE-OFF DIAGNOSTIC -- not part of the pipeline itself.

What this does, in two sentences: queries the Census VIP timeseries
endpoint for a single recent month with NO category_code filter, so
the API returns every category it has, each carrying its own real
category_code value AND (we're testing) its human-readable name via
program_code. We read the output to find the four literal codes that
correspond to Commercial, Manufacturing, Power, and Highway and
Street -- resolving the open item in data_sources.md.

Usage (run from repo root, same .env as the other scripts):
    python resolve_vip_category_codes.py
"""

import os
import sys

import requests
from dotenv import load_dotenv

VIP_ENDPOINT = "https://api.census.gov/data/timeseries/eits/vip"


def main():
    load_dotenv()

    api_key = os.environ.get("CENSUS_API_KEY")
    if not api_key:
        sys.exit(
            "CENSUS_API_KEY not set. Copy .env.example to .env at the repo "
            "root and fill in your registered Census API key."
        )

    params = {
        # program_code added -- documented across this EITS dataset family
        # (hv, ftd, etc.) as "Component Name". Testing whether it gives us
        # the human-readable label for each category_code.
        "get": "cell_value,category_code,program_code,data_type_code,seasonally_adj,time_slot_id",
        "for": "us",
        "time": "2024-06",  # arbitrary recent month with data -- just enumerating categories
        "key": api_key,
    }

    response = requests.get(VIP_ENDPOINT, params=params, timeout=30)

    # --- Diagnostic block: see what actually came back before assuming JSON ---
    print(f"Status code: {response.status_code}")
    print(f"Content-Type header: {response.headers.get('Content-Type')}")
    print("First 500 characters of raw response body:")
    print("-" * 60)
    print(response.text[:500])
    print("-" * 60)
    # ---------------------------------------------------------------------

    response.raise_for_status()  # still checked, but only after we've seen the body

    rows = response.json()

    header, data_rows = rows[0], rows[1:]
    cat_idx = header.index("category_code")
    prog_idx = header.index("program_code")

    # Distinct (category_code, program_code) pairs seen in this pull.
    distinct_pairs = sorted(set((row[cat_idx], row[prog_idx]) for row in data_rows))

    print(f"\nFound {len(distinct_pairs)} distinct (category_code, program_code) pairs:\n")
    for code, label in distinct_pairs:
        print(f"  {code:8s} -> {label}")

    print(
        "\nLook for the four rows matching Commercial, Manufacturing, Power, "
        "and Highway and Street. Paste this output back and we'll lock the "
        "mapping into data_sources.md."
    )


if __name__ == "__main__":
    main()