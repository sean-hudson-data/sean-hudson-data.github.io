"""
02_tract_shapes.py -- Pennsylvania 2020 tract shapes for the web map.

Builds tract polygons by dissolving the same TIGER/Line 2025 block file OS-FARA
already caches, so the map uses exactly the blocks behind every number on the
page and no second download is needed. Water-only tracts (99xxxx) are dropped.

Output, in ../data/:
    pa_tracts.geojson   tract_geoid + simplified geometry (WGS84)

Run with the Python you use for OS-FARA (needs geopandas, pyogrio):
    python projects/food-store-definitions/_analysis/02_tract_shapes.py
"""

from __future__ import annotations

import os
from pathlib import Path

import geopandas as gpd

OSFARA_ROOT = Path(os.environ.get("OSFARA_ROOT", Path.home() / "osfara"))
BLOCK_ZIP = OSFARA_ROOT / "cache" / "tiger" / "tl_2025_42_tabblock20.zip"
OUT = Path(__file__).resolve().parents[1] / "data" / "pa_tracts.geojson"

# Simplification tolerance in degrees (~40 m). Small enough that Philadelphia's
# tracts keep their shape, large enough to keep the file light for a browser.
TOLERANCE = 0.0004

blocks = gpd.read_file(BLOCK_ZIP, columns=["GEOID20"], engine="pyogrio")
blocks["tract_geoid"] = blocks["GEOID20"].str[:11]
blocks = blocks.loc[blocks["tract_geoid"].str[5:7] != "99"]

tracts = blocks.dissolve(by="tract_geoid", as_index=False)[["tract_geoid", "geometry"]]
tracts = tracts.to_crs(4326)
tracts["geometry"] = tracts.geometry.simplify(TOLERANCE, preserve_topology=True)

tracts.to_file(OUT, driver="GeoJSON", COORDINATE_PRECISION=4)
print(f"{len(tracts):,} tracts -> {OUT} ({OUT.stat().st_size / 1e6:.1f} MB)")
