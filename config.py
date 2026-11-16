import os

DATA_DIR   = r"data/real_data"
# Each run can write to its own folder. I set RCA_OUTPUT_DIR in the job script.
OUTPUT_DIR = os.environ.get("RCA_OUTPUT_DIR", r"outputs/real_data_severity")

ACTIVITY_MIN_FREQUENCY = 0.10
TOP_N_DRUGS            = 15
TOP_N_PROCEDURES       = 15

AR_MIN_STABLE      = 1
AR_MAX_STABLE      = 3
AR_MIN_FLEXIBLE    = 1
AR_MIN_SUPPORT_PCT = 0.05
AR_MIN_CONFIDENCE  = 0.7

UPLIFT_MAX_DEPTH    = 3
UPLIFT_MIN_LEAF_PCT = 0.05
UPLIFT_MIN_MAX_ITE  = -1.0

# Severity at admission. These columns come from rca_adm_features.csv, which
# sql/rca_dataset.sql exports. I add them to the uplift trees as covariates.
# With RCA_NO_SEVERITY=1 the trees are fitted without them.
SEVERITY_COLS = ([] if os.environ.get('RCA_NO_SEVERITY') == '1'
                 else ['ed_arrival', 'ideation_dx', 'attempt_dx'])

# The columns I join from rca_adm_features.csv, if the file is in DATA_DIR.
# Only the ones in SEVERITY_COLS go into the models.
ADMISSION_FEATURE_COLS = ['ed_arrival', 'ideation_dx', 'attempt_dx',
                          'is_first_admission', 'died_by_day30', 'admission_no']

# Process history: how many MDD admissions the patient had before this one
# (admission_no - 1, at most 5). Repeat admissions are readmitted about twice
# as often, so this is a strong confounder. I add it to the trees and to the
# doubly robust check. With RCA_NO_HISTORY=1 it is left out.
HISTORY_COLS = [] if os.environ.get('RCA_NO_HISTORY') == '1' else ['prior_admissions']

# The models for the propensity and the outcome in the doubly robust check:
#   logit  logistic regression. This is the default and gives the main results.
#   gbm    gradient boosting. It can also learn interactions and curves.
# I set RCA_DR_LEARNER=gbm in the job script for the sensitivity run.
DR_LEARNER = os.environ.get('RCA_DR_LEARNER', 'logit')
