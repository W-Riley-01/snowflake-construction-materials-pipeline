"""
ONE-OFF DIAGNOSTIC -- checking whether multiple rows (revision vintages)
are being returned per category/month, which would explain why we've
been silently grabbing an inconsistent row via data_rows[0].
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
        sys.exit("CENSUS_API_KEY not set.")

    for code, month in [("02XX", "2024-09"), ("02XX", "2024-12"), ("03XX", "2024-09")]:
        params = {
            "get": "cell_value,category_code,time_slot_id,data_type_code,seasonally_adj",
            "for": "us",
            "time": month,
            "category_code": code,
            "data_type_code": "T",
            "seasonally_adj": "no",
            "key": api_key,
        }
        response = requests.get(VIP_ENDPOINT, params=params, timeout=30)
        rows = response.json()
        print(f"\n{code} @ {month} -- {len(rows) - 1} row(s) returned:")
        for row in rows:
            print(" ", row)


if __name__ == "__main__":
    main()