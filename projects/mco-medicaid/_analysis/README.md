# MCO refresh: analysis code

Code for revisiting my 2019 analysis of Medicaid managed care for people with
intellectual and developmental disabilities (I/DD). The write-up isn't done yet;
this folder holds the reproducible pieces. Folders starting with `_` are never
rendered by Quarto.

## Run order

Set the working directory to `projects/mco-medicaid/`, then:

| Script | What it does | Writes |
| --- | --- | --- |
| `01_build_panel.R` | Tidies the CMS files into one state-year panel (1991–2020) and joins adoption years | `data/panel.csv`, `data/medicaid_per_enrollee_by_category.csv` |
| `02_replicate_2019.R` | Reproduces the 2019 estimate (−$432.7) and shows what changes as the specification is fixed | `results/replication_2019.csv` |
| `03_estimates.R` | Static TWFE, Sun–Abraham event studies, balanced window, randomization inference, enrollment decomposition, placebos, category effects | `results/*.csv`, `figures/01`–`06` |
| `04_maps.R` | Adoption map and per-enrollee quintile maps (1991 vs. 2019) | `figures/07`–`09` |

Packages: tidyverse, fixest, scales, sf, tigris.

## Data

- `data/cms_residence/`: CMS Office of the Actuary, State Health Expenditure
  Accounts by state of residence, 1991–2020
  ([source](https://www.cms.gov/data-research/statistics-trends-and-reports/national-health-expenditure-data/state-residence)).
  Public data. Private insurance files cover 2001–2020 only.
- `data/idd_mco_adoption_years.csv`: year each state moved I/DD long-term
  services into managed care, with sources. `use_as_treated == "yes"` marks the
  states counted as adopters.
- `data/original_2019/Medicaid_Panel_Data2.csv`: the panel behind the 2019
  analysis (earlier CMS release, 1991–2014).

## Key definitions

- Main outcome: Medicaid "Other Health, Residential, and Personal Care" spending
  per enrollee (CMS code 10), where HCBS waiver and residential I/DD spending is
  counted. Total personal health care (code 1) is the secondary outcome.
- Adopters: AZ 1988, MI 1998, WI 2000, NC 2013, KS 2014, IA 2016, AR 2019.
  Arizona has no pre-period in the panel and is dropped from event studies.
- Main sample 1991–2020; 1991–2019 as a robustness check.
