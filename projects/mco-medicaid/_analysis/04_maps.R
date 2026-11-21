# 04_maps.R --------------------------------------------------------------------
# Framing maps for the I/DD managed care piece:
#   1. Which states adopted I/DD managed care, and when
#   2. Quintile choropleths of Medicaid spending per enrollee, early vs. late
#      year, with adopting states outlined
# Saves PNGs to figures/.
#
# Run with the working directory set to projects/mco-medicaid/.
# Packages: tidyverse, sf, tigris, scales

library(tidyverse)
library(sf)
library(tigris)      # Census boundaries; install.packages("tigris") if needed
library(scales)
options(tigris_use_cache = TRUE)
dir.create("figures", showWarnings = FALSE)

# ---- Shapes ------------------------------------------------------------------
# Cartographic boundary file (generalized for mapping); shift_geometry() moves
# Alaska and Hawaii below the lower 48 and projects to an equal-area CRS.
states_sf <- states(cb = TRUE, resolution = "20m", year = 2022) %>%
  filter(STUSPS %in% c(state.abb, "DC")) %>%
  shift_geometry() %>%
  select(State = NAME, abbr = STUSPS)   # geometry column is kept automatically

# Label positions. The smallest Northeast states get labels offshore with a
# leader line (offsets in meters).
offshore <- tribble(
  ~abbr,  ~dx,     ~dy,
  "RI",   190000, -100000,
  "CT",   150000, -190000,
  "NJ",   170000,  -40000,
  "DE",   160000,  -80000,
  "MD",   250000, -180000,
  "DC",   240000, -300000
)

# Label at a point inside each state's largest piece (keeps Michigan's label on
# the Lower Peninsula rather than the Upper)
largest_piece <- states_sf %>%
  st_cast("POLYGON", warn = FALSE) %>%
  mutate(area = as.numeric(st_area(.))) %>%
  group_by(State) %>%
  slice_max(area, n = 1, with_ties = FALSE) %>%
  ungroup()

# Centroid when it falls inside the shape, otherwise a guaranteed-inside point
cent    <- st_centroid(st_geometry(largest_piece))
inside  <- lengths(st_intersects(cent, largest_piece)) > 0 &
  mapply(function(i) st_intersects(cent[i], st_geometry(largest_piece)[i], sparse = FALSE)[1, 1],
         seq_along(cent))
label_geom <- cent
label_geom[!inside] <- st_point_on_surface(st_geometry(largest_piece)[!inside])
label_xy <- st_coordinates(label_geom)
label_pts <- largest_piece %>%
  st_drop_geometry() %>%
  mutate(x = label_xy[, 1], y = label_xy[, 2]) %>%
  select(State, abbr, x, y) %>%
  left_join(offshore, by = "abbr") %>%
  mutate(offshore = !is.na(dx),
         lx = if_else(offshore, x + dx, x),
         ly = if_else(offshore, y + dy, y))

map_theme <- theme_void(base_size = 12) +
  theme(plot.title.position = "plot",
        plot.title    = element_text(face = "bold"),
        plot.subtitle = element_text(colour = "grey35"),
        legend.position = "bottom",
        legend.title  = element_blank())

# ---- Adoption data -----------------------------------------------------------
adoption <- read_csv("data/idd_mco_adoption_years.csv", show_col_types = FALSE) %>%
  select(State = state, adoption_year, use_as_treated)

status_levels <- c("Before 1991", "1998-2000", "2013-2019",
                   "Partial (new enrollees only)", "Not adopted by 2019")
status_cols <- c("#0d366b", "#2a78d6", "#86b6ef", "#f2b880", "#e6e6e6")

status_sf <- states_sf %>%
  left_join(adoption, by = "State") %>%
  mutate(status = case_when(
           use_as_treated == "yes" & adoption_year < 1991 ~ status_levels[1],
           use_as_treated == "yes" & adoption_year < 2010 ~ status_levels[2],
           use_as_treated == "yes"                        ~ status_levels[3],
           use_as_treated == "flag"                       ~ status_levels[4],
           TRUE                                           ~ status_levels[5]),
         status = factor(status, levels = status_levels))

status_labels <- label_pts %>%
  left_join(st_drop_geometry(status_sf) %>% select(State, status, adoption_year,
                                                   use_as_treated),
            by = "State") %>%
  mutate(text = if_else(use_as_treated %in% c("yes", "flag"),
                        paste0(abbr, "\n", adoption_year), abbr),
         # white text on the two darkest fills, dark text elsewhere
         ink  = if_else(status %in% status_levels[1:2] & !offshore, "white", "grey15"))

# ---- 1. Adoption map ---------------------------------------------------------
p_status <- ggplot() +
  geom_sf(data = status_sf, aes(fill = status), colour = "white", linewidth = 0.3) +
  geom_segment(data = filter(status_labels, offshore),
               aes(x = x, y = y, xend = lx, yend = ly),
               colour = "grey55", linewidth = 0.25) +
  geom_text(data = status_labels, aes(lx, ly, label = text, colour = ink),
            size = 2.6, lineheight = 0.85, fontface = "bold") +
  scale_fill_manual(values = setNames(status_cols, status_levels), drop = FALSE) +
  scale_colour_identity() +
  labs(title = "States that moved I/DD long-term services into managed care",
       subtitle = "Year of adoption under each adopting state") +
  map_theme
p_status
ggsave("figures/07_map_adoption_status.png", p_status, width = 10, height = 6.5, dpi = 200, bg = "white")

# ---- 2. Spending per enrollee choropleths ------------------------------------
per_enrollee_all <- read_csv("data/cms_residence/MEDICAID_PER_ENROLLEE20.CSV", show_col_types = FALSE) %>%
  filter(Group == "State") %>%
  select(State = State_Name, Code, Item, starts_with("Y")) %>%
  pivot_longer(cols = starts_with("Y"), names_to = "year", values_to = "value") %>%
  mutate(year = as.integer(str_remove(year, "Y")))

quintile_labels <- c("Bottom 20%", "20-40%", "Middle 20%", "60-80%", "Top 20%")
quintile_cols   <- c("#cde2fb", "#86b6ef", "#3987e5", "#1c5cab", "#0d366b")

# Quintiles are computed within each year, so each panel shows where a state
# ranked that year (dollar ranges for each panel go in the caption).
map_quintiles <- function(code, years = c(1991, 2019)) {
  d <- per_enrollee_all %>%
    filter(Code == code, year %in% years) %>%
    group_by(year) %>%
    mutate(quintile = factor(quintile_labels[ntile(value, 5)], levels = quintile_labels)) %>%
    ungroup()

  item <- unique(d$Item) %>% str_remove("^Medicaid/") %>% str_remove(" \\(\\$\\)$")

  ranges <- d %>%
    group_by(year, quintile) %>%
    summarise(lo = min(value), hi = max(value), .groups = "drop") %>%
    group_by(year) %>%
    summarise(txt = paste0(first(year), " fifths: ",
                           paste(dollar(lo), "-", dollar(hi), collapse = "  |  ")),
              .groups = "drop")

  map_d <- states_sf %>% inner_join(d, by = "State")
  adopters <- status_sf %>% filter(use_as_treated == "yes") %>%
    select(State) %>% crossing(year = years) %>% st_as_sf()

  ggplot() +
    geom_sf(data = map_d, aes(fill = quintile), colour = "white", linewidth = 0.25) +
    geom_sf(data = adopters, fill = NA, colour = "#eb6834", linewidth = 0.9) +
    facet_wrap(~year, ncol = 2) +
    scale_fill_manual(values = setNames(quintile_cols, quintile_labels)) +
    labs(title = paste("Medicaid", tolower(item), "spending per enrollee"),
         subtitle = "States ranked into fifths each year. Orange outline = adopted I/DD managed care by 2019",
         caption = paste(ranges$txt, collapse = "\n")) +
    map_theme +
    theme(strip.text = element_text(face = "bold", size = 13),
          plot.caption = element_text(hjust = 0, colour = "grey40", size = 8))
}

p_total <- map_quintiles(code = 1)    # total personal health care
p_idd   <- map_quintiles(code = 10)   # other health, residential & personal care (I/DD services)
p_total
p_idd
ggsave("figures/08_map_per_enrollee_total.png", p_total, width = 13, height = 5.5, dpi = 200, bg = "white")
ggsave("figures/09_map_per_enrollee_idd.png", p_idd,   width = 13, height = 5.5, dpi = 200, bg = "white")

# Other year pairs: e.g. map_quintiles(10, c(1997, 2019)) for just before the
# first in-panel adopters (Michigan 1998).
