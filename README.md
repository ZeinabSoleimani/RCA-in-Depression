# Causal Validation of Action Rules for Root Cause Analysis in Psychiatric Care

This is the code for our case study *Causal Validation of Action Rules for
Root Cause Analysis in Psychiatric Care Processes* (Z. Soleimani and
M. Weske), submitted to the PODS4H workshop.

The pipeline looks for antidepressant treatments in the hospital that lower
the risk of a readmission within 30 days after an inpatient depression stay.
It follows the two-stage approach of Bozorgi et al. (2020) and adds a third
stage:

1. **Action rules** propose candidate treatments for patient subgroups.
2. **Uplift trees** (CausalML) estimate the effect of each treatment. The
   leaf effects come from the half of the data that did not choose the
   splits. This is the `honesty` option of CausalML.
3. **A doubly robust check** (AIPW with cross-fitting) tests every rule in
   its own subgroup and adjusts for all covariates at once. The p-values are
   corrected with Holm's method.

A positive control on simulated data with confounding shows that Stage 3
finds known effects.

## What is in the repository

```
sql/rca_dataset.sql       cohort, stays, outcome, event log and attributes
                          (OMOP CDM, SAP HANA)
config.py                 all thresholds and settings
main.py                   runs the full pipeline (steps 1 to 9)
compute_lift.py           lift of each rule in its subgroup
src/
  preprocessing.py        turns the event log into one row per admission
  lift_rules.py           Stage 1: action rule mining
  uplift.py               Stage 2: uplift trees
  causal_rules.py         joins the rules with the tree effects
  dr_validation.py        Stage 3: doubly robust check (AIPW) and balance
  eda.py                  summary of the event log
test_dr_simulation.py     positive control for Stage 3 (simulated data)
test_synthetic.py         test of the full pipeline on a synthetic event log
jobs/run_paper_minerva.lsf  all runs of the paper (LSF cluster)
data/synthetic_test/      synthetic event log, no patient data
data/real_data/           place for the real CSV exports (not included)
```

## Installation

I used Python 3.10.

```bash
python3.10 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Keep `causalml` at version 0.15.5. Version 0.18 changed the tree format, and
`src/uplift.py` would no longer find the leaf effects.

## Try it without patient data

```bash
python test_dr_simulation.py                  # positive control
python test_dr_simulation.py --coverage 100   # interval coverage over 100 simulations
python test_synthetic.py                      # full pipeline on the synthetic log
```

## Run it on real data

1. Run `sql/rca_dataset.sql` on an OMOP CDM database, block by block from
   the top. `work_schema` stands for a schema you can write to, and `cdmphi`
   is the OMOP schema at Mount Sinai. Replace both with your own schema
   names. The header of the script defines the cohort, the stays, the
   outcome and every attribute.
2. Run the three main export blocks at the end of the script. Save the files
   in `data/real_data/`. Their names are in `data/real_data/README.md`.
3. Run the pipeline:

```bash
python main.py
```

The results go to the folder in `RCA_OUTPUT_DIR`
(default `outputs/real_data_severity`).

### Settings

These are environment variables. Set them in front of the command or in the
job script.

| Variable | Effect |
|---|---|
| `RCA_OUTPUT_DIR` | the output folder |
| `RCA_FIRST_ONLY=1` | keep only each patient's first admission |
| `RCA_EXCLUDE_DEATHS=1` | drop admissions with a death by day 30 |
| `RCA_NO_SEVERITY=1` | fit the trees without the severity markers |
| `RCA_NO_HISTORY=1` | fit the trees without the number of earlier admissions |
| `RCA_DR_LEARNER=gbm` | use gradient boosting in Stage 3, not logistic regression |

All other settings are in `config.py`: the support and confidence of the
rules, the tree depth and the minimum leaf size.

### Reproduce the paper

`jobs/run_paper_minerva.lsf` runs the positive control and the four analyses
of the paper: all admissions, all admissions with gradient boosting in
Stage 3, first admissions only, and without deaths by day 30. Submit it from
the repository folder:

```bash
bsub < jobs/run_paper_minerva.lsf
```

## Output files

| File | Content |
|---|---|
| `eda_summary.txt` | summary of the event log |
| `action_rules.txt` | the rules of Stage 1 |
| `tree_breakdowns.csv` | the tree nodes of Stage 2. `ite` is the leaf effect in the estimation half. `ite_split_half` is the stored score from the split half. |
| `causal_rules.csv` | the rules with their tree effects |
| `causal_rules_with_lift.csv` | the rules with the lift and the untreated rate in the subgroup |
| `dr_effects.csv` | the Stage 3 effect of each drug, overall and by subgroup |
| `balance.csv` | covariate balance of treated and untreated admissions, before and after weighting |
| `rule_validation.csv` | the Stage 3 effect, interval, Holm p-value and verdict of each rule |

## Data and privacy

The patient data come from the Mount Sinai Health System. I cannot share
them. This repository holds no patient data and no results from real data.
`.gitignore` blocks CSV files and output folders, except the synthetic test
data.

## Credits

Ayan Aslanli wrote the first version of the action rule and uplift tree
pipeline in a master's seminar project at the Hasso Plattner Institute
([original repository](https://github.com/aynamiii/causal-process-mining-psychiatry)).

## License

The code is under the MIT License. See the `LICENSE` file.

## References

- Bozorgi, Z. D., Teinemaa, I., Dumas, M., La Rosa, M., Polyvyanyy, A.:
  Process Mining Meets Causal Machine Learning: Discovering Causal Rules
  from Event Logs. ICPM 2020. https://doi.org/10.1109/ICPM49681.2020.00028
- Athey, S., Imbens, G.: Recursive partitioning for heterogeneous causal
  effects. PNAS 113(27), 2016.
- Chernozhukov, V. et al.: Double/debiased machine learning for treatment
  and structural parameters. The Econometrics Journal 21(1), 2018.
