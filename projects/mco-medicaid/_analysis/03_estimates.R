# 03_estimates.R ---------------------------------------------------------------
# Main estimates, robustness checks, and figures for the refresh.
#
# Input  : data/panel.csv, data/medicaid_per_enrollee_by_category.csv (01_build_panel.R)
# Outputs: results/*.csv (estimates for the write-up), figures/*.png
#
# Run with the working directory set to projects/mco-medicaid/.
# Packages: tidyverse, fixest, scales

library(tidyverse)
library(fixest)
library(scales)

dir.create("results", showWarnings = FALSE)
dir.create("figures", showWarnings = FALSE)

panel  <- read_csv("data/panel.csv", show_col_types = FALSE)
cat_pe <- read_csv("data/medicaid_per_enrollee_by_category.csv", show_col_types = FALSE)

end_year <- 2020                                   # 2019 version is a robustness row
main     <- filter(panel, year <= end_year)
es_data  <- filter(main, State != "Arizona")       # adopted 1988: no pre-period

# Shared look for figures ------------------------------------------------------
col_focus <- "#eb6834"    # I/DD category / adopters
col_main  <- "#2a78d6"
col_alt   <- "#343a40"
theme_mco <- theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(), plot.title.position = "plot",
        legend.position = "top", legend.title = element_blank())
save_fig <- function(p, name, w = 9, h = 5.5) {
  ggsave(file.path("figures", paste0(name, ".png")), p, width = w, height = h,
         dpi = 200, bg = "white")
  p
}

# Event-study coefficients (Sun-Abraham, aggregated by relative year) as a tibble
es_tidy <- function(model, label) {
  ct <- fixest::coeftable(model)
  keep <- grepl("::", rownames(ct))
  tibble(series = label,
         rel = as.integer(sub(".*::", "", rownames(ct)[keep])),
         est = ct[keep, "Estimate"], se = ct[keep, "Std. Error"]) %>%
    bind_rows(tibble(series = label, rel = -1L, est = 0, se = 0)) %>%   # reference year
    arrange(rel)
}

plot_es <- function(es, title, y_lab, dollars = FALSE) {
  ggplot(es, aes(rel, est, colour = series)) +
    geom_hline(yintercept = 0, colour = "grey60") +
    geom_vline(xintercept = -0.5, colour = "grey60", linetype = "dashed") +
    geom_errorbar(aes(ymin = est - 1.96 * se, ymax = est + 1.96 * se),
                  width = 0, alpha = 0.6, position = position_dodge(width = 0.4)) +
    geom_point(size = 1.8, position = position_dodge(width = 0.4)) +
    scale_colour_manual(values = c(col_focus, col_main, col_alt)) +
    scale_y_continuous(labels = if (dollars) label_dollar() else waiver()) +
    labs(title = title, x = "Years since adoption", y = y_lab) +
    theme_mco
}


# ---- 1. Raw spending paths ----------------------------------------------------
adopt_info <- main %>%
  filter(!is.na(adoption_year)) %>%
  distinct(State, adoption_year) %>%
  arrange(adoption_year) %>%
  mutate(label = factor(paste0(State, " (", adoption_year, ")")))
adopt_info$label <- factor(adopt_info$label, levels = adopt_info$label)
adopt_cols <- setNames(c("#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4",
                         "#008300", "#6250d6")[seq_len(nrow(adopt_info))],
                       levels(adopt_info$label))

band <- main %>%
  filter(is.na(adoption_year)) %>%
  group_by(year) %>%
  summarise(lo = quantile(mcd_pe_idd, 0.25), mid = median(mcd_pe_idd),
            hi = quantile(mcd_pe_idd, 0.75), .groups = "drop")

adopt_lines <- inner_join(main, adopt_info, by = c("State", "adoption_year"))
adopt_vlines <- filter(adopt_info, adoption_year >= min(main$year))

p_paths <- ggplot(adopt_lines, aes(year, mcd_pe_idd)) +
  geom_ribbon(data = band, aes(year, ymin = lo, ymax = hi), inherit.aes = FALSE,
              fill = "grey60", alpha = 0.25) +
  geom_line(data = band, aes(year, mid), inherit.aes = FALSE,
            colour = "grey55", linewidth = 2, alpha = 0.35) +
  geom_vline(data = adopt_vlines, aes(xintercept = adoption_year, colour = label),
             linetype = "dashed", show.legend = FALSE) +
  geom_line(aes(colour = label), linewidth = 0.9, show.legend = FALSE) +
  facet_wrap(~label) +
  scale_colour_manual(values = adopt_cols) +
  scale_y_continuous(labels = label_dollar()) +
  scale_x_continuous(breaks = c(1995, 2005, 2015)) +
  labs(title = "Medicaid I/DD-category spending per enrollee, adopting states",
       subtitle = paste("Grey band: middle 50% of states that never adopt (wide line = median).",
                        "Dashed line: adoption year.", sep = "\n"),
       x = NULL, y = NULL) +
  theme_mco
save_fig(p_paths, "01_spending_paths", w = 10, h = 7)


# ---- 2. Static TWFE -------------------------------------------------------------
static <- feols(c(mcd_pe_total, mcd_pe_idd) ~ adopted | State + year,
                data = main, cluster = ~State)
static_2019 <- feols(c(mcd_pe_total, mcd_pe_idd) ~ adopted | State + year,
                     data = filter(main, year <= 2019), cluster = ~State)
etable(static, static_2019)

tidy_adopted <- function(models, sample) {
  map_dfr(models, function(m) {
    tibble(outcome = as.character(formula(m))[2], sample = sample,
           est = coef(m)[["adopted"]], se = fixest::se(m)[["adopted"]], p = fixest::pvalue(m)[["adopted"]],
           n = nobs(m))
  })
}
bind_rows(tidy_adopted(as.list(static), paste0("1991-", end_year)),
          tidy_adopted(as.list(static_2019), "1991-2019")) %>%
  write_csv("results/static_twfe.csv")


# ---- 3. Event studies (Sun-Abraham) -------------------------------------------
sa_idd_pe <- feols(mcd_pe_idd ~ sunab(cohort, year) | State + year,
                   data = es_data, cluster = ~State)
summary(sa_idd_pe, agg = "ATT")
p_es_pe <- plot_es(es_tidy(sa_idd_pe, "I/DD category, per enrollee"),
                   "I/DD-category spending per enrollee around adoption",
                   "Change vs. year before adoption", dollars = TRUE) +
  theme(legend.position = "none")
save_fig(p_es_pe, "02_event_study_idd_per_enrollee")

# Spending vs. enrollment: is the per-enrollee drop a spending drop?
sa_spend  <- feols(log_mcd_spend_idd ~ sunab(cohort, year) | State + year,
                   data = es_data, cluster = ~State)
sa_enroll <- feols(log_mcd_enroll ~ sunab(cohort, year) | State + year,
                   data = es_data, cluster = ~State)
p_es_split <- plot_es(bind_rows(es_tidy(sa_spend,  "Log I/DD-category spending"),
                                es_tidy(sa_enroll, "Log Medicaid enrollment")),
                      "Spending falls at adoption; enrollment doesn't",
                      "Log points vs. year before adoption")
save_fig(p_es_split, "03_event_study_spending_vs_enrollment")

bind_rows(es_tidy(sa_idd_pe, "mcd_pe_idd"), es_tidy(sa_spend, "log_mcd_spend_idd"),
          es_tidy(sa_enroll, "log_mcd_enroll")) %>%
  write_csv("results/event_studies.csv")


# ---- 4. Balanced window -----------------------------------------------------------
# Keep adopters observed across the whole window so every point averages the
# same states (-7 to +3 keeps MI, WI, NC, KS, IA).
win <- c(-7, 3)
balanced_states <- es_data %>%
  filter(!is.na(adoption_year)) %>%
  group_by(State) %>%
  summarise(first_rel = min(rel_year), last_rel = max(rel_year), .groups = "drop") %>%
  filter(first_rel <= win[1], last_rel >= win[2]) %>%
  pull(State)
win_data <- es_data %>%
  filter(is.na(adoption_year) | (State %in% balanced_states & between(rel_year, win[1], win[2])))

sa_win <- feols(mcd_pe_idd ~ sunab(cohort, year) | State + year,
                data = win_data, cluster = ~State)
summary(sa_win, agg = "ATT")
p_es_win <- plot_es(es_tidy(sa_win, "Balanced window"),
                    paste0("Balanced window (", paste(balanced_states, collapse = ", "), ")"),
                    "Change vs. year before adoption", dollars = TRUE) +
  theme(legend.position = "none")
save_fig(p_es_win, "04_event_study_balanced_window")

# Aggregated ATT (average over post-adoption years) for the write-up
att_row <- function(model, label) {
  ct <- fixest::coeftable(summary(model, agg = "ATT"))
  tibble(model = label, est = ct["ATT", "Estimate"], se = ct["ATT", "Std. Error"],
         p = ct["ATT", "Pr(>|t|)"])
}
bind_rows(att_row(sa_idd_pe, "all_years"), att_row(sa_win, "balanced_window")) %>%
  write_csv("results/sunab_att.csv")
write_csv(es_tidy(sa_win, "balanced_window"), "results/event_study_balanced_window.csv")


# ---- 5. Randomization inference --------------------------------------------------
set.seed(2019)
ri_data    <- filter(main, State != "Arizona")
real_years <- adopt_info %>% filter(State != "Arizona") %>% pull(adoption_year)
all_states <- unique(ri_data$State)
twfe_est   <- function(df) coef(feols(mcd_pe_idd ~ adopted | State + year,
                                      data = df, notes = FALSE))[["adopted"]]
obs_est  <- twfe_est(ri_data)
perm_est <- replicate(1000, {
  fake <- tibble(State = sample(all_states, length(real_years)),
                 fake_year = sample(real_years))
  ri_data %>%
    left_join(fake, by = "State") %>%
    mutate(adopted = as.integer(!is.na(fake_year) & year >= fake_year)) %>%
    twfe_est()
})
ri_p <- mean(abs(perm_est) >= abs(obs_est))
write_csv(tibble(obs_est, ri_p, n_perm = length(perm_est)), "results/randomization_inference.csv")

p_ri <- ggplot(tibble(est = perm_est), aes(est)) +
  geom_histogram(bins = 40, fill = "grey70") +
  geom_vline(xintercept = obs_est, colour = col_focus, linewidth = 1) +
  scale_x_continuous(labels = label_dollar()) +
  labs(title = "Actual estimate vs. 1,000 random adoption assignments",
       subtitle = paste0("Orange = actual; share of placebos as large: ",
                         if (ri_p == 0) "< 0.001" else ri_p),
       x = "Placebo TWFE estimate (I/DD category, per enrollee)", y = NULL) +
  theme_mco
save_fig(p_ri, "05_randomization_inference", h = 4.5)


# ---- 6. Enrollment, placebos, and reshuffling -------------------------------------
# Enrollment as an outcome and the spending/enrollment decomposition:
# log(per enrollee) = log(spending) - log(enrollment)
decomp <- feols(c(log_mcd_pe_idd, log_mcd_spend_idd, log_mcd_enroll, mcd_enroll_rate,
                  log_mcd_spend_non_idd, log_mcd_spend_total,
                  log_mcr_spend_total, log_mcr_pe_total, log_phi_pe_total) ~ adopted |
                  State + year, data = main, cluster = ~State)
etable(decomp)
tidy_adopted(as.list(decomp), paste0("1991-", end_year)) %>%
  write_csv("results/decomposition_and_placebos.csv")
# Note: private insurance (log_phi_pe_total) only covers 2001+, so Michigan and
# Wisconsin have no pre-period in that model.

# Enrollment rate as a control (robustness)
ctrl <- feols(mcd_pe_idd ~ adopted + sw0(mcd_enroll_rate, log_mcr_pe_total) | State + year,
              data = main, cluster = ~State)
etable(ctrl)

# Where did the money go? Effect in each Medicaid category (per enrollee).
# The nine service categories sum to Personal Health Care.
cat_est <- cat_pe %>%
  filter(year <= end_year) %>%
  group_split(Code) %>%
  map_dfr(function(d) {
    m <- feols(value ~ adopted | State + year, data = d, cluster = ~State)
    tibble(Code = d$Code[1], category = d$category[1],
           est = coef(m)[["adopted"]], se = fixest::se(m)[["adopted"]])
  }) %>%
  mutate(role = case_when(Code == 1  ~ "Total (Personal Health Care)",
                          Code == 10 ~ "I/DD category",
                          TRUE       ~ "Other categories"),
         category = fct_reorder(category, est))
write_csv(cat_est, "results/category_effects.csv")

p_cat <- ggplot(cat_est, aes(est, category, colour = role)) +
  geom_vline(xintercept = 0, colour = "grey60") +
  geom_errorbar(aes(xmin = est - 1.96 * se, xmax = est + 1.96 * se), width = 0.25) +
  geom_point(size = 2.8) +
  scale_colour_manual(values = c("Total (Personal Health Care)" = col_alt,
                                 "I/DD category" = col_focus,
                                 "Other categories" = col_main)) +
  scale_x_continuous(labels = label_dollar()) +
  labs(title = "Effect of adoption on Medicaid spending per enrollee, by category",
       subtitle = "Reclassification within Medicaid would show other categories rising to offset the I/DD drop",
       x = "Change in spending per enrollee (95% CI, state-clustered)", y = NULL) +
  theme_mco
save_fig(p_cat, "06_category_effects", w = 10, h = 5.5)
