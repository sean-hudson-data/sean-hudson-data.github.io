"""
03_validation.py -- Does the block-based measure reproduce USDA's numbers?

Compares step 5 of the ladder (every SNAP retailer except farmers markets, the
same store universe as USDA's SRAM) with SRAM's published Pennsylvania figures,
then bounds the one approximation the method makes.

Three checks:

A. Tract flags. Low-access and LILA flags at all three thresholds, against
   SRAM's published flags (agreement, Cohen's kappa, precision, recall).
   Step 1 is included for contrast: its disagreement with SRAM is the
   definition at work, not error.

B. People beyond each distance. SRAM publishes, for every tract, how many
   people live more than 1/2, 1, 10 and 20 miles from a store. This compares
   our tract counts and shares with SRAM's, distance by distance, on the tracts
   where that distance is the one USDA applies (1/2 and 1 mile: urban tracts;
   10 and 20 miles: rural tracts).

C. The block internal-point approximation. Everyone in a block is assigned the
   distance from the block's internal point. A block is "ambiguous" when the
   threshold falls within its effective radius (the radius of a circle with the
   block's land area), so part of it could sit on either side. Counting every
   ambiguous block as inside, then as beyond, gives a lower and upper bound on
   the number of low-access tracts.

Inputs: ./cache/block_distances.parquet (from 01_ladder.py) and OS-FARA's SRAM
files. Outputs, in ../data/ (read when the page renders; not copied to the
site):
    validation_flags.csv     check A
    validation_shares.csv    check B, summary
    validation_tracts.csv    check B, tract-level (for the scatter plot)
    approximation_bounds.csv check C

Run after 01_ladder.py, with the Python you use for OS-FARA:
    python projects/food-store-definitions/_analysis/03_validation.py
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd

OSFARA_ROOT = Path(os.environ.get("OSFARA_ROOT", Path.home() / "osfara"))
sys.path.insert(0, str(OSFARA_ROOT))

from osfara import aggregate_tracts as agt  # noqa: E402
from osfara import sram  # noqa: E402

STATE = "42"
HERE = Path(__file__).resolve().parent
OUT_DIR = HERE.parent / "data"
SRAM_DIR = OSFARA_ROOT / "cache" / "sram"
M_PER_MI = agt.METRES_PER_MILE
STEP_LABELS = {1: "Large grocery retailers", 5: "All SNAP retailers"}

blocks = pd.read_parquet(HERE / "cache" / "block_distances.parquet")

chars = sram.load_characteristics(SRAM_DIR)
chars = chars.loc[chars["tract_geoid"].str[:2] == STATE]
urban_by_tract = chars.set_index("tract_geoid")["Urban"]
low_income_by_tract = chars.set_index("tract_geoid")["LowIncomeTracts"]

sl = sram.load_distance(SRAM_DIR, "straight_line")
sl = sl.loc[sl["tract_geoid"].str[:2] == STATE].copy().set_index("tract_geoid")

blocks["urban"] = blocks["tract_geoid"].map(urban_by_tract).fillna(0).astype(int)


# ---- A. Tract flags ---------------------------------------------------------
flag_rows = []
for variant, (urban_mi, rural_mi) in agt.THRESHOLD_VARIANTS.items():
    pub = sram.published_flags(sl.reset_index(), variant=variant).set_index("tract_geoid")
    for step in (5, 1):
        agg = agt.add_low_access(
            agt.aggregate(blocks, f"dist_{step}", urban_by_tract, urban_mi, rural_mi),
            low_income_by_tract,
        ).set_index("tract_geoid")
        both = agg.join(pub, how="inner")
        for ours, ref, measure in (("low_access", "sram_la", "Low access"),
                                   ("lila", "sram_lila", "Low income, low access")):
            c = agt.confusion(both[ours], both[ref])
            flag_rows.append({"variant": variant, "step": step,
                              "definition": STEP_LABELS[step], "measure": measure,
                              **{k: c[k] for k in ("n", "ours_flagged", "reference_flagged",
                                                   "agreement", "kappa", "precision",
                                                   "recall")}})
flags = pd.DataFrame(flag_rows)


# ---- B. People beyond each distance -----------------------------------------
DISTANCES = {"half": 0.5, "1": 1.0, "10": 10.0, "20": 20.0}
tract_pop = blocks.groupby("tract_geoid")["pop"].sum()
share_rows, tract_cols = [], {}
for key, miles in DISTANCES.items():
    beyond = blocks["dist_5"].to_numpy() > miles * M_PER_MI
    ours = (blocks.assign(b=np.where(beyond, blocks["pop"], 0))
            .groupby("tract_geoid")["b"].sum())
    cmp = pd.DataFrame({
        "pop": tract_pop,
        "ours": ours,
        "sram": sl[f"SD_SRAM_lapop{key}"],
        "sram_share": sl[f"SD_SRAM_lapop{key}share"] / 100,
        "urban": urban_by_tract,
    }).dropna()
    cmp = cmp.loc[cmp["pop"] > 0]
    cmp["ours_share"] = cmp["ours"] / cmp["pop"]
    tract_cols[f"ours_share_{key}"] = cmp["ours_share"]
    tract_cols[f"sram_share_{key}"] = cmp["sram_share"]

    # Score each distance on the tracts where USDA applies it
    applies = cmp.loc[cmp["urban"] == (1 if miles <= 1 else 0)]
    diff = (applies["ours_share"] - applies["sram_share"]).abs()
    share_rows.append({
        "distance_mi": miles,
        "tracts": "Urban" if miles <= 1 else "Rural",
        "n_tracts": len(applies),
        "pop_beyond_ours": int(applies["ours"].sum()),
        "pop_beyond_sram": int(applies["sram"].sum()),
        "pop_ratio": (applies["ours"].sum() / applies["sram"].sum()
                      if applies["sram"].sum() > 0 else np.nan),
        "share_r": (applies["ours_share"].corr(applies["sram_share"])
                    if applies["sram_share"].std() > 0 else np.nan),
        "mean_abs_diff_pp": diff.mean() * 100,
        "within_5pp": (diff <= 0.05).mean(),
        "within_10pp": (diff <= 0.10).mean(),
    })
shares = pd.DataFrame(share_rows)
tract_cmp = pd.DataFrame(tract_cols).join(urban_by_tract.rename("urban")).reset_index()


# ---- C. Internal-point approximation ----------------------------------------
thresh_m = np.where(blocks["urban"] == 1, 1.0, 10.0) * M_PER_MI
bound_rows = []
for step in (1, 5):
    d = blocks[f"dist_{step}"].to_numpy()
    r = blocks["eff_radius_m"].to_numpy()
    point = d > thresh_m
    surely_beyond = d - r > thresh_m      # whole block beyond the threshold
    maybe_beyond = d + r > thresh_m       # some of the block could be beyond
    ambiguous = maybe_beyond & ~surely_beyond & (blocks["pop"].to_numpy() > 0)

    counts, people = {}, {}
    for name, beyond in (("point", point), ("min", surely_beyond), ("max", maybe_beyond)):
        people[name] = int(blocks["pop"].to_numpy()[beyond].sum())
        agg = (blocks.assign(b=np.where(beyond, blocks["pop"], 0))
               .groupby("tract_geoid", as_index=False)
               .agg(pop_total=("pop", "sum"), pop_beyond=("b", "sum")))
        agg["share_beyond"] = np.where(agg["pop_total"] > 0,
                                       agg["pop_beyond"] / agg["pop_total"].replace(0, np.nan), 0)
        counts[name] = int(agt.add_low_access(agg)["low_access"].sum())

    bound_rows.append({
        "step": step, "definition": STEP_LABELS[step],
        "pop_ambiguous": int(blocks.loc[ambiguous, "pop"].sum()),
        "share_pop_ambiguous": blocks.loc[ambiguous, "pop"].sum() / blocks["pop"].sum(),
        "tracts_la": counts["point"], "tracts_la_min": counts["min"],
        "tracts_la_max": counts["max"],
        "pop_beyond": people["point"], "pop_beyond_min": people["min"],
        "pop_beyond_max": people["max"],
    })
bounds = pd.DataFrame(bound_rows)


# ---- Write ------------------------------------------------------------------
flags.to_csv(OUT_DIR / "validation_flags.csv", index=False)
shares.to_csv(OUT_DIR / "validation_shares.csv", index=False)
tract_cmp.to_csv(OUT_DIR / "validation_tracts.csv", index=False)
bounds.to_csv(OUT_DIR / "approximation_bounds.csv", index=False)

pd.set_option("display.width", 160)
print(flags.loc[flags["step"] == 5, ["variant", "measure", "ours_flagged",
                                      "reference_flagged", "agreement", "kappa"]]
      .to_string(index=False))
print(shares.round(3).to_string(index=False))
print(bounds.to_string(index=False))
