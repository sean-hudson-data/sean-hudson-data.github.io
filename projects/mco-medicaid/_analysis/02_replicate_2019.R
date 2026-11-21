# 02_replicate_2019.R ----------------------------------------------------------
# Reproduces the 2019 estimate (-$432.7, p = 0.08) from the original panel and
# shows what changes when the specification is fixed, one step at a time.
#
# The 2019 Stata model was:
#   areg per_enrollee MCO_state medicaid_enrollees medicaid_expendatures year,
#        a(state) cluster(state)
# i.e. state fixed effects, a linear year trend (not year fixed effects),
# controls for enrollment and total spending (the outcome's own denominator and
# numerator), nominal dollars, SEs clustered by state.
#
# Run with the working directory set to projects/mco-medicaid/.

library(tidyverse)
library(fixest)

orig <- read_csv("data/original_2019/Medicaid_Panel_Data2.csv", show_col_types = FALSE) %>%
  mutate(across(c(per_enrolee, medicaid_enrollees, medicaid_expendatures),
                ~ parse_number(as.character(.x))))   # stored as "5,209"

steps <- list(
  "2019 model"            = per_enrolee ~ MCO_state + medicaid_enrollees + medicaid_expendatures + year | State,
  "Drop outcome controls" = per_enrolee ~ MCO_state + year | State,
  "Year fixed effects"    = per_enrolee ~ MCO_state | State + year
)
replication <- map(steps, ~ feols(.x, data = orig, cluster = ~State))
etable(replication, keep = "MCO_state", headers = names(steps))

dir.create("results", showWarnings = FALSE)
imap_dfr(replication, ~ tibble(spec = .y,
                               est  = coef(.x)[["MCO_state"]],
                               se   = fixest::se(.x)[["MCO_state"]],
                               p    = fixest::pvalue(.x)[["MCO_state"]])) %>%
  write_csv("results/replication_2019.csv")
