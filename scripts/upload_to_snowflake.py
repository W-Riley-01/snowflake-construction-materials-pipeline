"""
Concrete & Cement Materials Market Pipeline
Stage 4: Prototype -- upload a local source JSON file into Snowflake's
named internal stage for that source, then load it into that source's
RAW table.

What this does, in two sentences: looks up the stage/table/data
directory for whichever source you name on the command line, runs PUT
to physically copy the most recent local JSON file for that source
into its named stage, then runs the matching COPY INTO so raw_data
gets the JSON and loaded_at gets its real DEFAULT timestamp. This
replaces upload_to_snowflake.py -- one generalized script instead
of a near-duplicate file per source, since the only thing that ever
changed between them was which stage/table/folder to point at.

Usage:
    pip install -r requirements.txt
    python scripts/upload_to_snowflake.py bls
    python scripts/upload_to_snowflake.py census_vip
    (optionally pass a specific file path as a second argument to
    override "most recent file in that source's data folder")
"""

import glob
import os
import sys

import snowflake.connector
from dotenv import load_dotenv

# Anchor to this script's own location, not the working directory --
# makes this work the same whether you run it from the project root,
# from scripts/, or from PyCharm's default run configuration.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)

# Everything that differs between sources lives here, and only here.
# Adding USGS later means adding one entry to this dict -- nothing
# else in this script changes.
SOURCES = {
    "bls": {
        "data_dir": os.path.join(PROJECT_ROOT, "data", "bls_ppi"),
        "stage": "RAW.BLS_PPI_STAGE",
        "table": "RAW.BLS_PPI_RAW",
    },
    "census_vip": {
        "data_dir": os.path.join(PROJECT_ROOT, "data", "census_vip"),
        "stage": "RAW.CENSUS_VIP_STAGE",
        "table": "RAW.CENSUS_VIP_RAW",
    },
}

# Shared across every JSON-shaped source -- see Stage 4 decision in
# data_sources.md on why this isn't split per source.
FILE_FORMAT = "RAW.JSON_FORMAT"


def latest_file(data_dir, source_name):
    files = sorted(glob.glob(os.path.join(data_dir, "*.json")), key=os.path.getmtime)
    if not files:
        sys.exit(f"No JSON files found in {data_dir} -- run the fetch script for {source_name} first.")
    return files[-1]


def main():
    load_dotenv()

    if len(sys.argv) < 2 or sys.argv[1] not in SOURCES:
        available = ", ".join(SOURCES.keys())
        sys.exit(f"Usage: python upload_to_snowflake.py <source> [file_path]\nAvailable sources: {available}")

    source_name = sys.argv[1]
    config = SOURCES[source_name]

    local_path = sys.argv[2] if len(sys.argv) > 2 else latest_file(config["data_dir"], source_name)
    local_path = os.path.abspath(local_path).replace("\\", "/")
    print(f"Source: {source_name}")
    print(f"Uploading: {local_path}")

    required = ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_PASSWORD",
                "SNOWFLAKE_WAREHOUSE", "SNOWFLAKE_DATABASE", "SNOWFLAKE_SCHEMA"]
    missing = [key for key in required if not os.environ.get(key)]
    if missing:
        sys.exit(f"Missing from .env: {', '.join(missing)}")

    conn = snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        database=os.environ["SNOWFLAKE_DATABASE"],
        schema=os.environ["SNOWFLAKE_SCHEMA"],
    )

    try:
        cursor = conn.cursor()
        stage = config["stage"]
        table = config["table"]

        print(f"Running PUT into @{stage} ...")
        cursor.execute(f"PUT file://{local_path} @{stage} AUTO_COMPRESS=TRUE OVERWRITE=TRUE")
        for row in cursor.fetchall():
            print("  ", row)

        print(f"Running COPY INTO {table} ...")
        cursor.execute(
            f"COPY INTO {table} (raw_data) "
            f"FROM @{stage} "
            f"FILE_FORMAT = (FORMAT_NAME = '{FILE_FORMAT}')"
        )
        for row in cursor.fetchall():
            print("  ", row)

        cursor.execute(f"SELECT COUNT(*) FROM {table}")
        count = cursor.fetchone()[0]
        print(f"Done. {table} now has {count} total row(s).")

    finally:
        conn.close()


if __name__ == "__main__":
    main()