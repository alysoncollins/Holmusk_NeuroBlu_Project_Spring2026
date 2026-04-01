# Identifying Outcome Drivers in Cognitive Decline Using Real World Data

**USI CS483 Capstone — Spring 2026**
**Client:** Holmusk (NeuroBlu Platform)

---

## Project Overview

This project builds a machine learning pipeline to identify which clinical variables — including drugs, lab values, procedures, and demographics — are associated with better or worse cognitive outcomes over time in patients diagnosed with Mild Cognitive Impairment (MCI), Dementia, or Alzheimer's disease.

Data is sourced from the NeuroBlu platform, which uses the OMOP Common Data Model (CDM). The pipeline covers cohort construction, feature engineering, model training, and explainability analysis using SHAP values.

---

## Team

| Name | Role |
|---|---|
| Alyson Collins | Team Lead, Documentation + SQL |
| Evan Schleter | Model Engineer + SQL |
| Eli Gubbins | Model Engineer + SQL |
| Lily Meyer | Research + Documentation |

---

## Research Question

> Which clinical variables (drugs, labs, procedures, demographics) are most predictive of cognitive trajectory — Improved, Stable, or Worse — in patients with MCI, Dementia, or Alzheimer's disease?

---

## Data

This project uses the **OMOP Common Data Model** via the NeuroBlu platform. Key tables include:

| Table | Purpose |
|---|---|
| `person` | Demographics (age, sex, race/ethnicity) |
| `condition_occurrence` | Diagnoses — used to define the patient cohort |
| `measurement` | Cognitive scores (Mini-Cog, MoCA, MMSE) and lab values |
| `measurement_lookup` | Concept definitions for measurement values and units |
| `drug_exposure` | Drug records at ingredient, component, and brand level |
| `drug_lookup` / `drug_product_lookup` | Drug concept mappings |
| `clinical_drug_ingredient_mapping` | Maps drugs to ingredient level |
| `clinical_drug_component_mapping` | Maps drugs to component level |
| `procedure_occurrence` | Procedure records |

### Cohort Definition

- **Inclusion:** Patients with at least one diagnosis of MCI, Dementia, or Alzheimer's disease
- **Index date:** First diagnosis date
- **Requirements:** At least one cognitive score after index date, at least one drug exposure from the target drug list, and at least 6 months of observation after index date

### Target Drugs

- Lecanemab (Leqembi)
- Donanemab (Kisunla)
- Additional drugs as specified in the project outline

Drug exposures are captured at three levels: ingredient, component, and brand.

### Outcome Variable

Cognitive trajectory is classified as **Improved**, **Stable**, or **Worse** based on repeated measurements of:

- **Mini-Cog** (0–5 scale)
- **MoCA** — Montreal Cognitive Assessment
- **MMSE** — Mini-Mental State Examination

### Features

- **Demographics:** Age at index date, sex, race/ethnicity
- **Drugs:** Ingredient, component, and brand-level exposure; rolling windows (0–30 days, 31–90 days, 91–180 days); cumulative days supply
- **Labs:** Most recent values, rolling means, abnormal flags, physiologically plausible range filters
- **Procedures:** Count-based windows

---

## ML Approach

| Item | Detail |
|---|---|
| Models | XGBoost, LightGBM, Random Forest |
| Data Split | Train / Validation / Test |
| Prediction Horizon | 6 or 12 months (TBD) |
| Explainability | SHAP — global feature importance, top 20 variables, summary and dependence plots |
| Outlier Detection | Isolation Forest (used in place of LOF due to memory constraints at large sample sizes) |

---

## Project Timeline

| Phase | Dates | Focus |
|---|---|---|
| 1 — Discovery & Research | Feb 2 – Feb 13 | Literature review, standardization plan, data familiarization |
| 2 — Cohort & Preprocessing | Feb 14 – Mar 6 | Cohort construction, preprocessing, standardization function |
| 3 — Feature Engineering | Mar 7 – Mar 27 | Extract cognitive scores and predictors, build longitudinal dataset |
| 4 — Modeling & Evaluation | Mar 28 – Apr 10 | Train XGBoost, LightGBM, Random Forest |
| 5 — Visualization & Analysis | Apr 11 – Apr 17 | SHAP analysis, boxplots, histograms, interpretation |
| 6 — Finalization | Apr 18 – Apr 24 | Final documentation, presentation, model refinement |


---

## Background

This project is part of a multi-semester research collaboration between USI and Holmusk:

- **Fall 2024 (CS483):** Drug lookup tool, SQL query exploration, OMOP data model research
- **Spring 2025 (CS461/CS483):** ML model to detect and clean invalid `days_supply` values in drug records using Isolation Forest
- **Fall 2025:** Software development iteration, anomaly detection on lab measurements (temperature, BMI, systolic BP, pulse rate)
- **Spring 2026 (CS483):** Identifying outcome drivers in cognitive decline — current semester

---

## Platform Access

- **NeuroBlu coding environment:** [app.neuroblu.ai](https://app.neuroblu.ai)
- **Shared files:** Microsoft Teams / OneDrive — USI-Holmusk NeuroBlu Research group

---

## How to run

Access to the NeuroBlu platform is required to access their data pipeline
-First download the code from the repository and upload the python files to Neuroblu's code studio application
-To run the model, run the `noDFmain.py` if running from a clean state or `Main.py` if you are loading in a pre-existing dataframe
