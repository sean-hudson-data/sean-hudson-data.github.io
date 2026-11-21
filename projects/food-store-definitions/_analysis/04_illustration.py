"""
04_illustration.py -- Data for the "how the measure works" figure.

Picks one urban tract and the area around it, and records each block's internal
point, its population, and the nearest store under two definitions (large
grocery retailers, and every SNAP retailer), plus the stores themselves. The
page draws the block points, a line from each to its nearest store, and the
stores.

The default tract (42003509400, Allegheny County) was chosen because nearly
everyone in it is more than a mile from a large grocery store but almost no one
is more than a mile from some SNAP retailer, so the two panels differ.

Outputs, in ../data/ (read when the page renders; not copied to the site):
    illustration_blocks.csv   blocks in the window, with nearest-store lines
    illustration_stores.csv   stores in the window (location and type only)

Run after 01_store_types.py:
    python projects/food-store-definitions/_analysis/04_illustration.py
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.neighbors import NearestNeighbors

OSFARA_ROOT = Path(os.environ.get("OSFARA_ROOT", Path.home() / "osfara"))
sys.path.insert(0, str(OSFARA_ROOT))

from osfara.compute_distances import EARTH_RADIUS_M  # noqa: E402
from osfara.extract_retailers import SRAM_EXCLUDED_TYPES  # noqa: E402

TRACT = os.environ.get("ILLUSTRATION_TRACT", "42003509400")
PAD_KM = 2.5  # window around the tract
HERE = Path(__file__).resolve().parent
OUT_DIR = HERE.parent / "data"

blocks = pd.read_parquet(HERE / "cache" / "block_distances.parquet")
retailers = pd.read_parquet(OSFARA_ROOT / "data" / "retailers" / "retailers.parquet")
retailers = retailers.loc[retailers["usable_for_distance"]
                          & ~retailers["store_type"].isin(SRAM_EXCLUDED_TYPES)]
retailers = retailers.assign(
    large=retailers["store_type"].isin(["Supermarket", "Super Store", "Grocery Store"]))

# Window: the tract's blocks plus PAD_KM on every side
t = blocks.loc[blocks["tract_geoid"] == TRACT]
assert len(t), f"tract {TRACT} not found"
lat0 = t["intptlat"].mean()
dlat = PAD_KM / 111.0
dlon = PAD_KM / (111.0 * np.cos(np.deg2rad(lat0)))
box = dict(lat=(t["intptlat"].min() - dlat, t["intptlat"].max() + dlat),
           lon=(t["intptlon"].min() - dlon, t["intptlon"].max() + dlon))


def in_box(df, lat="lat", lon="lon"):
    return df[lat].between(*box["lat"]) & df[lon].between(*box["lon"])


win = blocks.loc[in_box(blocks, "intptlat", "intptlon") & (blocks["pop"] > 0)].copy()


def radians(lat, lon):
    return np.deg2rad(np.column_stack([np.asarray(lat, "float64"), np.asarray(lon, "float64")]))


# Nearest store for each block in the window, under each definition. Searched
# against all stores nationally, like the main pipeline.
for name, stores in (("large", retailers.loc[retailers["large"]]), ("all", retailers)):
    nn = NearestNeighbors(n_neighbors=1, algorithm="ball_tree", metric="haversine")
    nn.fit(radians(stores["lat"], stores["lon"]))
    dist, idx = nn.kneighbors(radians(win["intptlat"], win["intptlon"]))
    win[f"dist_{name}_m"] = dist[:, 0] * EARTH_RADIUS_M
    win[f"store_lat_{name}"] = stores["lat"].to_numpy()[idx[:, 0]]
    win[f"store_lon_{name}"] = stores["lon"].to_numpy()[idx[:, 0]]

# Same distances as the main pipeline (dist_1 = large grocery, dist_5 = all SNAP)
assert np.allclose(win["dist_large_m"], win["dist_1"], rtol=1e-4)
assert np.allclose(win["dist_all_m"], win["dist_5"], rtol=1e-4)

win["in_tract"] = (win["tract_geoid"] == TRACT).astype(int)
win = win.rename(columns={"intptlat": "lat", "intptlon": "lon"})
win[["geoid", "tract_geoid", "in_tract", "lat", "lon", "pop",
     "dist_large_m", "store_lat_large", "store_lon_large",
     "dist_all_m", "store_lat_all", "store_lon_all"]].to_csv(
    OUT_DIR / "illustration_blocks.csv", index=False)

stores = retailers.loc[in_box(retailers), ["lat", "lon", "large", "store_type", "chain_flag"]]
stores.to_csv(OUT_DIR / "illustration_stores.csv", index=False)

print(f"tract {TRACT}: {len(win):,} populated blocks in window "
      f"({win['in_tract'].sum()} in the tract), {len(stores)} stores "
      f"({stores['large'].sum()} large grocery)")
