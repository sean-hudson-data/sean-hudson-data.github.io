# Food store definitions: analysis pipeline

Builds the data behind `../index.qmd` from the OS-FARA pipeline's Pennsylvania
outputs. Quarto never renders this folder (it starts with `_`).

| Script | What it does | Output (`../data/`) |
|---|---|---|
| `01_store_types.py` | Splits SNAP retailers into seven store types, finds every PA block's nearest store of each type, and works out low-access status for every tract under all 127 combinations of types and all three distance thresholds. Checks large grocery and all SNAP against the OS-FARA method note. Caches block distances in `cache/` (gitignored). Also counts the people the definition moves: statewide totals for every combination, who lives in tracts that lose their designation, and which store type now puts people within reach. | `store_types.csv`, `ladder_summary.csv`, `tract_combos.csv`, `combo_summary.csv`, `impact_who.csv`, `impact_nearest.csv` |
| `02_tract_shapes.py` | Dissolves the cached TIGER/Line 2025 blocks into 2020 tracts and simplifies them for the web map. | `pa_tracts.geojson` |
| `03_validation.py` | Compares the all-SNAP definition (same stores as USDA's SRAM) with SRAM's published tract flags and people-beyond-distance counts, and bounds the block internal-point approximation. | `validation_flags.csv`, `validation_shares.csv`, `validation_tracts.csv`, `approximation_bounds.csv` |
| `04_illustration.py` | Block points, nearest-store lines, and stores around one Allegheny County tract, for the "how the measure works" figure. | `illustration_blocks.csv`, `illustration_stores.csv` |

## Run

Use the Python you run OS-FARA with (Anaconda base works):

```bash
python projects/food-store-definitions/_analysis/01_store_types.py   # ~2 min
python projects/food-store-definitions/_analysis/02_tract_shapes.py  # ~1 min
python projects/food-store-definitions/_analysis/03_validation.py    # seconds
python projects/food-store-definitions/_analysis/04_illustration.py  # seconds
```

`03` and `04` read the cache `01` writes. All four read from `~/osfara` by
default; set `OSFARA_ROOT` to point elsewhere. They need the OS-FARA block
extract, retailer table, and SRAM files for Pennsylvania
(`data/blocks/state=42/`, `data/retailers/`, `cache/sram/`,
`cache/tiger/tl_2025_42_tabblock20.zip`).

## Rendering the page

The page's Python runs through reticulate in the same Python. The figure in
"How the measure works" draws an OpenStreetMap basemap with `contextily`
(`conda install -c conda-forge contextily`; conda-forge avoids GDAL clashes on
Windows), toned to grey. Without it, or offline, the figure renders without
the basemap. The interactive map loads Leaflet and OpenStreetMap tiles in the
reader's browser, greyed with CSS. Neither needs an API key. (CARTO's tiles now
require one; if you switch to them, use a key made for this site and restricted
to its domain, since anything on the page is public.)

## Store types

| Bit | Type | Notes |
|---|---|---|
| 0 | Supermarkets and super stores | USDA's two labels overlap at the brand level, so combined |
| 1 | Grocery stores | 0 + 1 = FARA/LRAM's large-retailer definition |
| 2 | Dollar stores | identified by store name (OS-FARA `chain_flag`) |
| 3 | Chain pharmacies | identified by store name |
| 4 | Convenience stores | |
| 5 | Specialty stores | |
| 6 | Other SNAP retailers | USDA's "Other" plus Restaurant Meals Program (none in PA) |

All seven = SRAM's definition (farmers markets are excluded, as in SRAM).

`tract_combos.csv` packs each tract's low-access status under every combination
into a 32-character hex string per threshold: bit `c` is combination `c`, and
bit `g` of `c` is store type `g`. The page's map decodes it in the browser.

## Publishing rules

Only tract-level aggregates are published; the files the map reads are listed
in `scripts/published-data.txt`. The `validation_*`, `impact_*`,
`approximation_bounds.csv` and `illustration_*` files are read by Python when the page renders and are not
copied to the site. Block-level distances stay in the gitignored `cache/`.
