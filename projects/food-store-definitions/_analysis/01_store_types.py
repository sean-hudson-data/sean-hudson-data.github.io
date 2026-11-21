"""
01_store_types.py -- Which stores count? Every combination of store types, Pennsylvania.

Splits SNAP-authorized retailers into eight store types, finds each census
block's nearest store of each type, and from those works out low-access status
for every tract under every combination of types (127 of them) and all three
USDA distance thresholds. The distance to the nearest store in a combination is
just the smallest of its types' distances, so one nearest-store search per type
covers every combination.

Store types (mutually exclusive; farmers markets are left out, as in SRAM):

    supermarket   Supermarkets and super stores (USDA's labels for these two
                  overlap at the brand level, so they're combined)
    grocery       Grocery stores
    dollar        Dollar stores           \\  identified by store name, from
    pharmacy      Chain pharmacies        /   OS-FARA's chain_flag
    convenience   Convenience stores
    specialty     Specialty stores
    other         Everything else: stores USDA labels "Other", plus Restaurant
                  Meals Program restaurants (none are authorized in PA)

Supermarkets + grocery stores is FARA/LRAM's large-retailer definition; all
seven is SRAM's. The page's ladder adds types in this order:

    1  Large grocery retailers  (supermarket + grocery)
    2  + dollar stores
    3  + chain pharmacies
    4  + convenience stores
    5  + everything else        (all seven = SRAM)

Inputs (from the OS-FARA pipeline):
    <OSFARA_ROOT>/data/blocks/state=42/blocks.parquet
    <OSFARA_ROOT>/data/retailers/retailers.parquet
    <OSFARA_ROOT>/cache/sram/SRAM General Tract Characteristics Data.csv

Outputs (aggregated, safe to publish), in ../data/:
    store_types.csv      the seven types, with store counts
    ladder_summary.csv   one row per threshold x ladder step
    tract_combos.csv     one row per tract; low-access status under every
                         combination, packed as a 32-character hex string per
                         threshold (bit c = combination c, bit g of c = type g)
    combo_summary.csv    statewide totals for every threshold x combination
                         (tracts, people beyond the threshold, people in
                         low-access and LILA tracts)
    impact_who.csv       who lives in tracts that lose their designation when
                         the definition widens from large grocery to all SNAP
    impact_nearest.csv   people beyond the threshold under large grocery but
                         not under all SNAP, by the type of store that now
                         puts them within reach
Also caches block-level distances in ./cache/ (gitignored) for 03 and 04.

Run with the Python you use for OS-FARA (needs pandas, pyarrow, scikit-learn):
    python projects/food-store-definitions/_analysis/01_store_types.py
Set OSFARA_ROOT if the OS-FARA project isn't at ~/osfara.
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

from osfara import aggregate_tracts as agt  # noqa: E402
from osfara import sram  # noqa: E402
from osfara.compute_distances import EARTH_RADIUS_M  # noqa: E402
from osfara.extract_retailers import SRAM_EXCLUDED_TYPES  # noqa: E402

STATE = "42"  # Pennsylvania
OUT_DIR = Path(__file__).resolve().parents[1] / "data"
OUT_DIR.mkdir(exist_ok=True)
CACHE = Path(__file__).resolve().parent / "cache"
CACHE.mkdir(exist_ok=True)

# Expected results from the OS-FARA method note (1-and-10-mile thresholds):
# large grocery and all SNAP are the two definitions it compared.
EXPECTED = {1: (1018, 220), 5: (486, 36)}


# ---- Load ------------------------------------------------------------------
blocks = pd.read_parquet(
    OSFARA_ROOT / "data" / "blocks" / f"state={STATE}" / "blocks.parquet",
    columns=["geoid", "tract_geoid", "intptlat", "intptlon", "pop", "eff_radius_m"],
)
retailers = pd.read_parquet(OSFARA_ROOT / "data" / "retailers" / "retailers.parquet")
retailers = retailers.loc[retailers["usable_for_distance"]].reset_index(drop=True)

chars = sram.load_characteristics(OSFARA_ROOT / "cache" / "sram")
chars = chars.loc[chars["tract_geoid"].str[:2] == STATE]
urban_by_tract = chars.set_index("tract_geoid")["Urban"]
low_income_by_tract = chars.set_index("tract_geoid")["LowIncomeTracts"]

print(f"{len(blocks):,} blocks, population {blocks['pop'].sum():,}; "
      f"{len(retailers):,} usable retailers nationally")


# ---- Store types -----------------------------------------------------------
st = retailers["store_type"]
chain = retailers["chain_flag"]
dollar = chain.eq("dollar_store").fillna(False).to_numpy()
pharmacy = chain.eq("pharmacy").fillna(False).to_numpy()
no_chain = chain.isna().to_numpy()
supermarket = st.isin(["Supermarket", "Super Store"]).to_numpy()
grocery = st.eq("Grocery Store").to_numpy()
large = supermarket | grocery

# (key, label, mask). Order matters: it sets each type's bit in the combos.
TYPES = [
    ("supermarket", "Supermarkets and super stores", supermarket),
    ("grocery", "Grocery stores", grocery),
    ("dollar", "Dollar stores", dollar & ~large),
    ("pharmacy", "Chain pharmacies", pharmacy & ~large & ~dollar),
    ("convenience", "Convenience stores", st.eq("Convenience Store").to_numpy() & no_chain),
    ("specialty", "Specialty stores", st.eq("Specialty Store").to_numpy() & no_chain),
    ("other", "Other SNAP retailers",
     st.isin(["Other", "Restaurant Meals Program"]).to_numpy() & no_chain),
]
masks = np.column_stack([m for _, _, m in TYPES])
all_snap = ~st.isin(SRAM_EXCLUDED_TYPES).to_numpy()
assert (masks.sum(axis=1) <= 1).all(), "store types overlap"
assert (masks.any(axis=1) == all_snap).all(), "store types don't add up to all SNAP retailers"

BIT = {key: 1 << g for g, (key, _, _) in enumerate(TYPES)}
LADDER = [
    (1, "Large grocery retailers", BIT["supermarket"] | BIT["grocery"]),
    (2, "+ Dollar stores", BIT["supermarket"] | BIT["grocery"] | BIT["dollar"]),
    (3, "+ Chain pharmacies", BIT["supermarket"] | BIT["grocery"] | BIT["dollar"] | BIT["pharmacy"]),
    (4, "+ Convenience stores", BIT["supermarket"] | BIT["grocery"] | BIT["dollar"]
     | BIT["pharmacy"] | BIT["convenience"]),
    (5, "+ All other SNAP retailers", 127),
]


# ---- Nearest store of each type, for every block -------------------------------
def radians(lat, lon) -> np.ndarray:
    return np.deg2rad(np.column_stack([np.asarray(lat, "float64"), np.asarray(lon, "float64")]))


query = radians(blocks["intptlat"], blocks["intptlon"])
in_state = retailers["state"].eq("PA").to_numpy()
D = np.empty((len(blocks), len(TYPES)), dtype="float64")
type_rows = []
for g, (key, label, mask) in enumerate(TYPES):
    rows = np.flatnonzero(mask)
    nn = NearestNeighbors(n_neighbors=1, algorithm="ball_tree", metric="haversine")
    nn.fit(radians(retailers["lat"].to_numpy()[rows], retailers["lon"].to_numpy()[rows]))
    dist, _ = nn.kneighbors(query)
    D[:, g] = dist[:, 0] * EARTH_RADIUS_M
    type_rows.append({"bit": g, "key": key, "label": label,
                      "stores_pa": int((mask & in_state).sum()), "stores_us": int(mask.sum())})
    print(f"{label:32s} {mask.sum():>7,} stores ({(mask & in_state).sum():,} in PA)")
types = pd.DataFrame(type_rows)


def combo_distance(c: int) -> np.ndarray:
    cols = [g for g in range(len(TYPES)) if c >> g & 1]
    return D[:, cols].min(axis=1)


# ---- Low access for every combination -------------------------------------------
tract_codes, tract_ids = pd.factorize(blocks["tract_geoid"])
pop = blocks["pop"].to_numpy()
tract_pop = np.bincount(tract_codes, weights=pop)
urban = pd.Series(tract_ids).map(urban_by_tract).fillna(0).to_numpy()
low_income = pd.Series(tract_ids).map(low_income_by_tract).fillna(0).astype(bool).to_numpy()
urban_block = urban[tract_codes] == 1
share_den = np.where(tract_pop > 0, tract_pop, np.nan)

ALL = (1 << len(TYPES)) - 1
combos = range(1, ALL + 1)
la = {}  # (variant, combo) -> bool array over tracts
combo_rows = []
for variant, (urban_mi, rural_mi) in agt.THRESHOLD_VARIANTS.items():
    thresh = np.where(urban_block, urban_mi, rural_mi) * agt.METRES_PER_MILE
    for c in combos:
        beyond = np.bincount(tract_codes, weights=np.where(combo_distance(c) > thresh, pop, 0),
                             minlength=len(tract_ids))
        share = np.nan_to_num(beyond / share_den)
        flag = (beyond >= sram.LA_MIN_COUNT) | (share >= sram.LA_MIN_SHARE)
        la[(variant, c)] = flag
        combo_rows.append({
            "variant": variant, "combo": c,
            "tracts_low_access": int(flag.sum()),
            "tracts_lila": int((flag & low_income).sum()),
            "pop_beyond": int(beyond.sum()),
            "pop_in_low_access_tracts": int(tract_pop[flag].sum()),
            "pop_in_lila_tracts": int(tract_pop[flag & low_income].sum()),
        })
combo_summary = pd.DataFrame(combo_rows)

# Adding a store type can only shorten distances, so it can never add a tract.
for variant in agt.THRESHOLD_VARIANTS:
    for c in combos:
        for g in range(len(TYPES)):
            if not c >> g & 1:
                assert not (la[(variant, c | 1 << g)] & ~la[(variant, c)]).any(), \
                    f"adding type {g} to combo {c} added a low-access tract"


# ---- Ladder summary (same numbers as the OS-FARA aggregation module) ----------
summary_rows = []
for variant, (urban_mi, rural_mi) in agt.THRESHOLD_VARIANTS.items():
    for step, label, c in LADDER:
        blocks["_d"] = combo_distance(c)
        agg = agt.add_low_access(agt.aggregate(blocks, "_d", urban_by_tract, urban_mi, rural_mi),
                                 low_income_by_tract)
        agt.validate(agg)
        # The fast path above must agree with the reference implementation.
        fast = pd.Series(la[(variant, c)], index=tract_ids)
        assert (agg.set_index("tract_geoid")["low_access"] == fast.reindex(agg["tract_geoid"])
                .to_numpy()).all(), f"fast path disagrees at {variant} step {step}"
        in_combo = np.isin(np.arange(len(TYPES)), [g for g in range(len(TYPES)) if c >> g & 1])
        summary_rows.append({
            "variant": variant, "urban_mi": urban_mi, "rural_mi": rural_mi, "step": step,
            "combo": c, **agt.summarize(agg, label=label),
            "retailers_pa": int(types.loc[in_combo, "stores_pa"].sum()),
            "retailers_us": int(types.loc[in_combo, "stores_us"].sum()),
        })
blocks = blocks.drop(columns="_d")
summary = pd.DataFrame(summary_rows)

main = summary.loc[summary["variant"] == "1And10"].set_index("step")
for step, (n_la, n_lila) in EXPECTED.items():
    got = (int(main.loc[step, "tracts_low_access"]), int(main.loc[step, "tracts_lila"]))
    assert got == (n_la, n_lila), f"step {step}: expected {(n_la, n_lila)}, got {got}"
print("matches the method note (large grocery and all SNAP)")


# ---- Tract table: every combination, packed as hex -------------------------------
def pack(bits: list[np.ndarray]) -> np.ndarray:
    """Bit c of the result = bits[c]; 128 bits -> 32 hex characters (bit 0 first)."""
    arr = np.column_stack(bits).astype(np.uint8)            # tracts x 128
    nibbles = arr.reshape(len(arr), -1, 4) @ np.array([1, 2, 4, 8], dtype=np.uint8)
    return np.array(["".join("0123456789abcdef"[n] for n in row) for row in nibbles])


tracts = pd.DataFrame({
    "tract_geoid": tract_ids,
    "county": pd.Series(tract_ids).map(chars.set_index("tract_geoid")["County20"]).to_numpy(),
    "pop2020": tract_pop.astype(int),
    "urban": urban.astype(int),
    "low_income": low_income.astype(int),
})
for variant in agt.THRESHOLD_VARIANTS:
    none_selected = np.ones(len(tract_ids), dtype=bool)   # combo 0: no stores at all
    tracts[f"la_{variant}"] = pack([none_selected] + [la[(variant, c)] for c in combos])

# ---- Who the change affects: large grocery (LRAM) -> all SNAP (SRAM) -----------
LARGE, ALL_SNAP = LADDER[0][2], LADDER[-1][2]
# SRAM's TractLOWI (low-income population) is left out: for Pennsylvania it sums
# to 71% of residents, even in tracts with poverty rates under 5%, which doesn't
# match any low-income definition, so it isn't usable as published.
COUNTS = {"POP2020": "Residents", "TractKids": "Children (0-17)", "TractSeniors": "Seniors (65+)",
          "OHU2020": "Households", "TractSNAP": "Households receiving SNAP",
          "TractHUNV": "Households without a vehicle"}
char_counts = chars.set_index("tract_geoid")[list(COUNTS)].reindex(tract_ids).fillna(0)
who_rows = []
for variant in agt.THRESHOLD_VARIANTS:
    lose_la = la[(variant, LARGE)] & ~la[(variant, ALL_SNAP)]
    lose_lila = lose_la & low_income
    for group, mask in (("Pennsylvania", np.ones(len(tract_ids), bool)),
                        ("Lose low-access status", lose_la),
                        ("Lose low-income, low-access status", lose_lila)):
        row = {"variant": variant, "group": group, "tracts": int(mask.sum())}
        row.update({label: int(char_counts.loc[mask, col].sum()) for col, label in COUNTS.items()})
        who_rows.append(row)
impact_who = pd.DataFrame(who_rows)

# People beyond the threshold with large grocery only but within it with every
# SNAP retailer, by the type of the store now nearest to them.
nearest_type = np.argmin(D, axis=1)
near_rows = []
for variant, (urban_mi, rural_mi) in agt.THRESHOLD_VARIANTS.items():
    thresh = np.where(urban_block, urban_mi, rural_mi) * agt.METRES_PER_MILE
    moved = (combo_distance(LARGE) > thresh) & (combo_distance(ALL_SNAP) <= thresh)
    for g, (key, label, _) in enumerate(TYPES):
        near_rows.append({"variant": variant, "key": key, "label": label,
                          "people": int(pop[moved & (nearest_type == g)].sum())})
impact_nearest = pd.DataFrame(near_rows)
assert (impact_nearest.query("key in ['supermarket', 'grocery']")["people"] == 0).all()

types.to_csv(OUT_DIR / "store_types.csv", index=False)
combo_summary.to_csv(OUT_DIR / "combo_summary.csv", index=False)
impact_who.to_csv(OUT_DIR / "impact_who.csv", index=False)
impact_nearest.to_csv(OUT_DIR / "impact_nearest.csv", index=False)
summary.to_csv(OUT_DIR / "ladder_summary.csv", index=False)
tracts.to_csv(OUT_DIR / "tract_combos.csv", index=False)

# Block-level cache for 03_validation.py and 04_illustration.py. Parquet is
# gitignored: block-level rows stay off GitHub and the site.
cache = blocks[["geoid", "tract_geoid", "intptlat", "intptlon", "pop", "eff_radius_m"]].copy()
for step, _, c in LADDER:
    cache[f"dist_{step}"] = combo_distance(c).astype("float32")
cache.to_parquet(CACHE / "block_distances.parquet", index=False)

print(summary.loc[summary["variant"] == "1And10",
                  ["step", "label", "retailers_pa", "tracts_low_access", "tracts_lila"]]
      .to_string(index=False))
print(impact_who.query("variant == '1And10'").to_string(index=False))
print(impact_nearest.query("variant == '1And10'").to_string(index=False))
print(f"wrote store_types, ladder_summary, tract_combos, combo_summary, impact_who, "
      f"impact_nearest to {OUT_DIR}")
