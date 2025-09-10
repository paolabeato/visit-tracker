# Visit Tracker Macro (`%visit_tracker`)

## 📌 Overview

`%visit_tracker` is a **generalized SAS macro** for monitoring visit compliance in longitudinal studies.

-   Builds an **expected schedule** of visits (interval-based or lookup-based)

-   Applies **visit windows** (fixed, symmetric, or lag policies)

-   Performs **greedy matching** of actual vs expected visits

-   Flags **on-time, early, late, missed** visits

-   Produces **participant-level roll-ups, site-level summaries, and pending visit lists**

-   Generates **plots of completion rates** (with optional target lines)

-   Originally developed for clinical research cohorts, it is generalized here for **any longitudinal visit-based study or trial**.

## 🌐 Live Report

View the full SAS demo report (with tables and plots) here:\
👉 [Visit Tracker Report](https://paolabeato.github.io/visit-tracker/)

## ⚙️ Macro Parameters

| Parameter | Description |
|--------------------------|----------------------------------------------|
| **in_ds** | Input dataset (long format: one row per actual visit) |
| **id_var** | Participant ID variable |
| **visit_date_var** | Visit date variable |
| **site_var** | Site variable (optional) |
| **schedule_type** | `INTERVAL` (baseline + intervals) or `LOOKUP` (per-ID schedule) |
| **baseline_date_var** | Baseline date (required if `INTERVAL`) |
| **interval_days** | Space-separated offsets from baseline (e.g., `0 30 90 180`) |
| **lookup_ds** | Lookup dataset with per-ID targets (required if `LOOKUP`) |
| **lookup_id_var** | ID variable in lookup_ds |
| **lookup_visit_var** | Visit name variable in lookup_ds |
| **lookup_target_date_var** | Target date variable in lookup_ds |
| **lookup_order_var** | (Optional) numeric order variable in lookup_ds |
| **order_map_ds** | (Optional) mapping dataset: `visit_name` → `visit_ord` |
| **window_def** | `FIXED`, `SYMMETRIC`, or `LAG` policy |
| **window_pre** / **window_post** | Window bounds (days) |
| **early_thresh** / **late_thresh** | Thresholds for early/late flags |
| **max_gap_days** | Defines long-term gap (if needed) |
| **out_matched** | Output: expected × actual matches |
| **out_unmatched** | Output: actuals not matched to any window |
| **out_summary** | Output: visit/site summary |
| **out_participant** | Output: participant roll-up |
| **out_pending** | Output: expected but not yet completed |
| **make_plots** | `Y/N`: create completion plots |
| **debug** | `Y/N`: keep temp tables |

## 📊 Example Outputs

1.  **Matched visits (`&out_matched`)**\
    Expected vs actual, with window boundaries, differences, and status.

2.  **Unmatched visits (`&out_unmatched`)**\
    Actual visits outside of any defined window.

3.  **Summary (`&out_summary`)**\
    Visit-level/site-level completion rates, on-time/early/late/missed counts.

4.  **Participant roll-up (`&out_participant`)**\
    Per-person totals and rates.

5.  **Pending (`&out_pending`)** Visits due or overdue as of today.

## 🚀 Quick Start

### Interval-based schedule (semiannual)

```         
%visit_tracker(
  in_ds=work.visits_long,
  id_var=participant_id,
  visit_date_var=visit_dt,
  site_var=site_id,
  schedule_type=INTERVAL,
  baseline_date_var=baseline_dt,
  interval_days=0 180 360 540,
  window_def=FIXED,
  window_pre=0, window_post=90,
  out_summary=vt_summary
);

proc print data=vt_summary; run;
```

### Lookup-based schedule (custom targets per ID)

```         
%visit_tracker(
  in_ds=work.visits_lookup,
  id_var=participant_id,
  visit_date_var=visit_dt,
  site_var=site_id,
  schedule_type=LOOKUP,
  lookup_ds=work.lookup_schedule,
  lookup_id_var=participant_id,
  lookup_visit_var=visit_name,
  lookup_target_date_var=target_dt,
  order_map_ds=work.visit_order_map,   /* optional */
  window_def=FIXED,
  window_pre=2, window_post=5,
  out_summary=vt_summary
);

proc print data=vt_summary; run;
```

## 🧪 Demo Scripts

This repo includes **synthetic examples** to illustrate use cases:

- [**Example 1 — Semiannual visits for 18 months**](https://paolabeato.github.io/visit-tracker/#ex1)
- [**Example 2 — Dense early schedule (Day 7, Day 14, etc.)**](https://paolabeato.github.io/visit-tracker/#ex2)
- [**Example 3 — Per-ID lookup schedule with custom names**](https://paolabeato.github.io/visit-tracker/#ex3)
- [**Example 4 — Asymmetric post-window (LAG policy)**](https://paolabeato.github.io/visit-tracker/#ex4)
- [**Example 5 — Weekly follow-ups (8 weeks)**](https://paolabeato.github.io/visit-tracker/#ex5)

Each demo script produces a sample dataset, runs the macro, and prints/plots the outputs.

## 📈 Plotting Completion Rates

By default, `make_plots=Y` produces **site-stratified summaries**.\
When aggregating across sites, use:

```         
proc sql;
  create table vt_summary_overall as
  select visit_ord, visit_name,
         sum(on_time)+sum(early)+sum(late) as completed,
         sum(total) as total,
         calculated completed / calculated total as completion_rate format=percent8.1
  from vt_summary
  group by visit_ord, visit_name;
quit;

proc sgplot data=vt_summary_overall;
  vbar visit_name / response=completion_rate datalabel;
  yaxis grid label="Completion Rate" values=(0 to 1 by 0.1) valuesformat=percent8.0;
  xaxis discreteorder=data label="Visit";
  refline 0.80 / axis=y lineattrs=(pattern=shortdash) label="Target 80%";
run;
```

## Availability

The visit tracking macro was developed by Outlier Analytics LLC to support longitudinal research and program evaluation.  
Because this framework is proprietary, the full source code is not publicly available.  

Custom implementations and adaptations can be made available **upon request through Outlier Analytics LLC**.  
📩 Contact: info@outlieranalytics.info
🌐 [outlieranalytics.info](https://outlieranalytics.info)

## 🙌 Acknowledgments

This macro was inspired by operational needs in longitudinal research studies, then generalized for open-source use.
