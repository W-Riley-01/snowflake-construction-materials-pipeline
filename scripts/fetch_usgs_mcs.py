"""
Concrete & Cement Materials Market Pipeline
Stage 4: Prototype -- fetch USGS Mineral Commodity Summaries data release

What this does, in two sentences: asks the ScienceBase catalog for the
MCS data release item, finds the combined commodities CSV in its file
list, and downloads it byte-for-byte to a local timestamped file. That
file is what gets uploaded into RAW.USGS_MCS_STAGE in Snowsight -- this
script does not touch Snowflake at all, it only talks to ScienceBase.

No API key and no authentication: USGS publishes this as open data
(CC0-1.0 public domain). That is why there is no .env handling here,
unlike fetch_bls_ppi.py and fetch_census_vip.py.

Usage:
    pip install -r requirements.txt
    python scripts/fetch_usgs_mcs.py
"""

import os
import sys
from datetime import datetime

import requests

# ScienceBase child item holding "Commodity Salient U.S. and World Statistics".
# The PARENT item (doi:10.5066/P1WKQ63T) is a container and holds no data files;
# the files hang off the child items. The other child holds the report's figure
# CSVs (Fig1..Fig13), which are chart-backing data, not our source.
SCIENCEBASE_ITEM_ID = "69837e43b66b01367d7ec7c7"
SCIENCEBASE_ITEM_URL = (
    f"https://www.sciencebase.gov/catalog/item/{SCIENCEBASE_ITEM_ID}?format=json"
)

# Matched case-insensitively against the item's file list rather than
# hardcoded in full, so the year in the filename does not have to be
# edited by hand for each annual release.
TARGET_FILE_FRAGMENT = "commodities_data.csv"

# Anchored to this script's own location, NOT the working directory the
# script happens to be launched from. A bare relative path silently
# created a duplicate data/ folder inside scripts/ for both other sources.
OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "usgs"
)


def find_csv_download_url(item_json):
    """Locate the combined commodities CSV in the ScienceBase item's file list."""
    files = item_json.get("files", [])
    if not files:
        sys.exit(
            "ScienceBase item returned no file list. The item ID may have changed "
            "or the release may have been restructured -- open the item in a "
            "browser and check its Attached Files section."
        )

    for f in files:
        name = f.get("name", "")
        if TARGET_FILE_FRAGMENT in name.lower():
            return f.get("downloadUri") or f.get("url"), name

    available = ", ".join(f.get("name", "?") for f in files)
    sys.exit(
        f"No file matching '{TARGET_FILE_FRAGMENT}' found in the item.\n"
        f"Files present: {available}\n"
        "The release may have renamed the combined CSV -- update "
        "TARGET_FILE_FRAGMENT after checking the item in a browser."
    )


def main():
    # --- Step 1: ask ScienceBase what files this release contains -----------
    meta_response = requests.get(SCIENCEBASE_ITEM_URL, timeout=30)
    meta_response.raise_for_status()

    try:
        item_json = meta_response.json()
    except ValueError:
        sys.exit(
            "ScienceBase returned a non-JSON body (likely an HTML error or "
            "block page) despite an HTTP 200. Same failure mode seen with the "
            "Census API -- raise_for_status() does not catch it."
        )

    download_url, source_name = find_csv_download_url(item_json)
    print(f"Found: {source_name}")

    # --- Step 2: download the file itself ------------------------------------
    file_response = requests.get(download_url, timeout=120)
    file_response.raise_for_status()

    # .content, NOT .text. The published file is Windows-1252, and .text would
    # decode it using requests' guessed encoding and then re-encode on write --
    # mangling all 5,773 em dash bytes before Snowflake ever sees the file.
    # Writing raw bytes keeps the local copy byte-identical to what USGS
    # published, which is what RAW's fidelity promise depends on.
    payload = file_response.content

    # --- Step 3: validate before writing -------------------------------------
    # An HTTP 200 carrying an HTML error page is a real failure mode (Census).
    # The published file starts with its header row, so check that directly.
    if not payload.startswith(b"MCS chapter"):
        preview = payload[:120]
        sys.exit(
            "Downloaded file does not start with the expected header row.\n"
            f"First bytes: {preview!r}\n"
            "This usually means an error or redirect page was served instead "
            "of the CSV. Nothing was written."
        )

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Timestamped filename. Snowflake tracks which filenames it has already
    # loaded into a table and SKIPS repeats by default -- reusing a constant
    # filename would make a genuine reload look like a silent no-op.
    out_path = os.path.join(
        OUTPUT_DIR, f"usgs_mcs_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    )
    with open(out_path, "wb") as f:
        f.write(payload)

    # Line count is a cheap smoke test: the 2026 release is 8,886 data rows
    # plus one header. A wildly different number means the release changed
    # shape and the landing table should be re-checked before loading.
    line_count = payload.count(b"\n")
    print(f"Wrote {len(payload):,} bytes (~{line_count:,} lines) to {out_path}")
    print("Next: upload this file into RAW.USGS_MCS_STAGE via Snowsight "
          "(Ingestion -> Add Data -> Load files into a stage), then run the COPY INTO.")


if __name__ == "__main__":
    main()