# 01_build_panel.R -------------------------------------------------------------
# Builds the state-year panel used by every other script.
#
# Inputs : data/cms_residence/*.CSV   CMS State Health Expenditure Accounts by
#                                     state of residence, 1991-2020
#          data/idd_mco_adoption_years.csv
# Outputs: data/panel.csv                          one row per state-year
#          data/medicaid_per_enrollee_by_category.csv
#
# Run with the working directory set to projects/mco-medicaid/.

library(tidyverse)

# Every CMS file has the same layout: one row per state x item, one column per
# year (Y1991 ... Y2020). Filter to states, pivot the years long, strip the "Y".
# starts_with("Y") rather than column positions because the private insurance
# files only cover 2001-2020.
tidy_state_file <- function(file, value_name, code = NULL) {
  d <- read_csv(file.path("data/cms_residence", file), show_col_types = FALSE) %>%
    filter(Group == "State")
  if (!is.null(code)) d <- filter(d, Code == code)
  d %>%
    select(State = State_Name, starts_with("Y")) %>%
    pivot_longer(cols = starts_with("Y"), names_to = "year", values_to = value_name) %>%
    mutate(year = as.integer(str_remove(year, "Y")))
}

# Code 1  = Personal Health Care (total)
# Code 10 = Other Health, Residential, and Personal Care, where Medicaid HCBS
#           waiver and residential I/DD spending is counted ("I/DD category")
sources <- list(
  list("MEDICAID_PER_ENROLLEE20.CSV", "mcd_pe_total",    1),   # $ per enrollee
  list("MEDICAID_PER_ENROLLEE20.CSV", "mcd_pe_idd",      10),
  list("MEDICAID_AGGREGATE20.CSV",    "mcd_spend_total", 1),   # $ millions
  list("MEDICAID_AGGREGATE20.CSV",    "mcd_spend_idd",   10),
  list("MEDICAID_ENROLLMENT20.CSV",   "mcd_enroll",      NULL),# thousands
  list("US_POPULATION20.CSV",         "pop",             NULL),# thousands
  list("MEDICARE_PER_ENROLLEE20.CSV", "mcr_pe_total",    1),
  list("MEDICARE_AGGREGATE20.CSV",    "mcr_spend_total", 1),
  list("MEDICARE_ENROLLMENT20.CSV",   "mcr_enroll",      NULL),
  list("PHI_PER_ENROLLEE20.CSV",      "phi_pe_total",    NULL),# 2001-2020 only
  list("PHI_ENROLLMENT20.CSV",        "phi_enroll",      NULL)
)

panel <- sources %>%
  map(~ tidy_state_file(.x[[1]], .x[[2]], .x[[3]])) %>%
  reduce(left_join, by = c("State", "year"))

# Treatment ---------------------------------------------------------------------
# Only states coded use_as_treated == "yes" count as adopters (drops pilots,
# voluntary programs, and non-I/DD programs). Tennessee is "flag": partial.
adoption <- read_csv("data/idd_mco_adoption_years.csv", show_col_types = FALSE) %>%
  filter(use_as_treated == "yes") %>%
  select(State = state, adoption_year)

panel <- panel %>%
  left_join(adoption, by = "State") %>%
  mutate(
    adopted   = as.integer(!is.na(adoption_year) & year >= adoption_year),
    # Sun-Abraham cohort: never-adopters get 10000 (fixest convention)
    cohort    = if_else(is.na(adoption_year), 10000, adoption_year),
    rel_year  = if_else(is.na(adoption_year), NA_real_, year - adoption_year),
    mcd_spend_non_idd = mcd_spend_total - mcd_spend_idd,
    mcd_enroll_rate   = 100 * mcd_enroll / pop,          # % of residents
    across(c(mcd_pe_total, mcd_pe_idd, mcd_spend_total, mcd_spend_idd,
             mcd_spend_non_idd, mcd_enroll, mcr_pe_total, mcr_spend_total,
             mcr_enroll, phi_pe_total),
           log, .names = "log_{.col}")
  ) %>%
  arrange(State, year)

# Checks
stopifnot(n_distinct(panel$State) == 51,
          all(count(panel, State)$n == 30),
          # per enrollee = spending / enrollment (CMS rounding aside)
          with(panel, all(abs(mcd_spend_idd * 1000 / mcd_enroll / mcd_pe_idd - 1) < 0.05)))

write_csv(panel, "data/panel.csv")

# Per-enrollee spending in all ten Medicaid categories, long -------------------
read_csv("data/cms_residence/MEDICAID_PER_ENROLLEE20.CSV", show_col_types = FALSE) %>%
  filter(Group == "State") %>%
  select(State = State_Name, Code, Item, starts_with("Y")) %>%
  pivot_longer(cols = starts_with("Y"), names_to = "year", values_to = "value") %>%
  mutate(year     = as.integer(str_remove(year, "Y")),
         category = Item %>% str_remove("^Medicaid/") %>% str_remove(" \\(\\$\\)$")) %>%
  select(State, year, Code, category, value) %>%
  left_join(select(panel, State, year, adopted), by = c("State", "year")) %>%
  write_csv("data/medicaid_per_enrollee_by_category.csv")
