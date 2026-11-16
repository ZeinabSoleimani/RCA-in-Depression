from __future__ import annotations
import os
import re
import pandas as pd
try:
    from airms_connect.connection import airms_connection
except ImportError:
    airms_connection = None
from config import ACTIVITY_MIN_FREQUENCY, TOP_N_DRUGS, ADMISSION_FEATURE_COLS

STABLE_EVENT_TYPES = {'CONDITION'}


def _sanitize(name: str) -> str:
    name = re.sub(r'[^a-z0-9]+', '_', str(name).lower().strip())
    return name.strip('_')[:60]


def _onehot_activities(event_log, event_types, prefix, case_col, min_count, top_n=None):
    subset = event_log[event_log['event_type'].str.upper().isin(event_types)]
    if subset.empty:
        return pd.DataFrame()
    pivot = subset.groupby([case_col, 'activity']).size().unstack(fill_value=0).clip(upper=1)
    freq = pivot.sum().sort_values(ascending=False)
    if top_n is not None:
        pivot = pivot[freq[freq >= min_count].head(top_n).index]
    else:
        pivot = pivot[freq[freq >= min_count].index]
    pivot.columns = [f'{prefix}__{_sanitize(c)}' for c in pivot.columns]
    pivot.columns.name = None
    return pivot.astype(int)


# This is the same query as the event log export in sql/rca_dataset.sql.
# It only runs when data_dir has no event_log_sample.csv yet. To use it,
# first replace work_schema with your own schema, and your_login_host
# further down with the login host of your cluster.
_EVENT_LOG_SQL = """
SELECT
    e.PERSON_ID,
    e.INDEX_VISIT_OCCURRENCE_ID,
    e.ACTIVITY,
    e.EVENT_DATETIME,
    e.EVENT_TYPE,
    YEAR(c.admission_date) - p.YEAR_OF_BIRTH        AS age_at_admission,
    p.GENDER_CONCEPT_ID                              AS gender,
    DAYS_BETWEEN(c.admission_date, c.discharge_date) AS length_of_stay,
    COALESCE(rf.readmitted, 0)                       AS readmitted
FROM work_schema.RCA_log e
INNER JOIN work_schema.depression_inpatient_cohort c
    ON c.index_visit_occurrence_id = e.INDEX_VISIT_OCCURRENCE_ID
INNER JOIN CDMPHI.PERSON p
    ON p.PERSON_ID = e.PERSON_ID
LEFT JOIN work_schema.readmission_flag rf
    ON rf.index_visit_occurrence_id = e.INDEX_VISIT_OCCURRENCE_ID
WHERE e.INDEX_VISIT_OCCURRENCE_ID IN (SELECT case_id FROM work_schema.case_sample)
ORDER BY e.INDEX_VISIT_OCCURRENCE_ID, e.EVENT_DATETIME
"""


def _fetch_event_log(data_dir: str) -> pd.DataFrame:
    cache_path = os.path.join(data_dir, 'event_log_sample.csv')
    if os.path.exists(cache_path):
        print(f"  Loading cached event log from {cache_path}")
        return pd.read_csv(cache_path, parse_dates=['event_datetime'], low_memory=False)

    if airms_connection is None:
        raise RuntimeError(
            f"No cached event log found at {cache_path} and airms_connect is not installed."
        )
    print("  Connecting to AIRMS/CDMPHI...")
    airms = airms_connection()
    airms.on_minerva(login_host_name="your_login_host")
    airms.connect()

    event_log = airms.conn.sql(_EVENT_LOG_SQL).collect()
    event_log.columns = event_log.columns.str.lower()

    os.makedirs(data_dir, exist_ok=True)
    event_log.to_csv(cache_path, index=False)
    print(f"  Saved event log to {cache_path}")
    return event_log


def _load_admission_features(data_dir: str) -> pd.DataFrame | None:
    """One row per admission from rca_adm_features.csv. Returns None if the file is missing."""
    feat_path = os.path.join(data_dir, 'rca_adm_features.csv')
    if not os.path.exists(feat_path):
        return None
    feats = pd.read_csv(feat_path, low_memory=False)
    feats.columns = feats.columns.str.lower()
    print(f"  Loaded admission features from {feat_path}")
    return feats.drop_duplicates(subset=['index_visit_occurrence_id'])


def _apply_case_filters(event_log: pd.DataFrame, feats: pd.DataFrame | None, case_col: str) -> pd.DataFrame:
    """Filters for the sensitivity runs. I set them in the job script.

    RCA_FIRST_ONLY=1      keep only each patient's first admission
    RCA_EXCLUDE_DEATHS=1  drop admissions with a death by day 30 after discharge
    The filters run before the feature selection. So the 10% threshold and the
    EDA summary describe the filtered cohort.
    """
    filters = []
    if os.environ.get('RCA_FIRST_ONLY') == '1':
        filters.append(('is_first_admission', 1))
    if os.environ.get('RCA_EXCLUDE_DEATHS') == '1':
        filters.append(('died_by_day30', 0))
    if not filters:
        return event_log
    if feats is None:
        raise RuntimeError('A case filter is set, but rca_adm_features.csv is missing.')
    kept = feats
    for col, val in filters:
        kept = kept[kept[col] == val]
    ids = set(kept['index_visit_occurrence_id'].astype(event_log[case_col].dtype))
    n_before = event_log[case_col].nunique()
    event_log = event_log[event_log[case_col].isin(ids)].copy()
    print(f"  Case filters {filters}: {n_before} -> {event_log[case_col].nunique()} cases")
    return event_log


def prepare_data(data_dir: str, min_frequency: float = ACTIVITY_MIN_FREQUENCY) -> tuple[pd.DataFrame, list, list, pd.DataFrame]:
    event_log = _fetch_event_log(data_dir)
    event_log.columns = event_log.columns.str.lower()
    event_log['event_datetime'] = pd.to_datetime(event_log['event_datetime'], errors='coerce')

    case_col = 'index_visit_occurrence_id'
    feats = _load_admission_features(data_dir)
    event_log = _apply_case_filters(event_log, feats, case_col)
    min_count = max(1, int(event_log[case_col].nunique() * min_frequency))

    drug_df = _onehot_activities(event_log, {'DRUG'}, 'drug', case_col, min_count, top_n=TOP_N_DRUGS)
    stable_act_df = _onehot_activities(event_log, STABLE_EVENT_TYPES, 'cond', case_col, min_count)

    # I drop the "no matching concept" columns. They come from unmapped records
    # and are not real conditions.
    stable_act_df = stable_act_df[
        [c for c in stable_act_df.columns if 'no_matching_concept' not in c]
    ]

    attr_cols = [case_col, 'age_at_admission', 'gender', 'length_of_stay', 'readmitted']
    if 'person_id' in event_log.columns:
        attr_cols.insert(1, 'person_id')   # I need it to cluster the intervals by patient
    case_attrs = (
        event_log.drop_duplicates(subset=[case_col])
        [attr_cols]
        .set_index(case_col)
    )

    case_attrs['age_group'] = pd.cut(
        pd.to_numeric(case_attrs['age_at_admission'], errors='coerce'),
        bins=[0, 40, 55, 65, 75, 150],
        labels=['age_lt40', 'age_40_54', 'age_55_64', 'age_65_74', 'age_gte75'],
    ).cat.add_categories('unknown').fillna('unknown').astype(str)

    case_attrs['los_category'] = pd.cut(
        pd.to_numeric(case_attrs['length_of_stay'], errors='coerce').clip(lower=0),
        bins=[-1, 0, 3, 7, 9999],
        labels=['same_day', 'short', 'medium', 'long'],
    ).cat.add_categories('unknown').fillna('unknown').astype(str)

    df = case_attrs.copy()
    for ohe_df in [drug_df, stable_act_df]:
        if not ohe_df.empty:
            ohe_df.index = ohe_df.index.astype(df.index.dtype)
            df = df.join(ohe_df, how='left')

    act_cols = list(drug_df.columns) + list(stable_act_df.columns)
    df[act_cols] = df[act_cols].fillna(0).astype(int)
    # I join the admission attributes from rca_adm_features.csv, if that file
    # is in data_dir.
    if feats is not None:
        keep = [c for c in ADMISSION_FEATURE_COLS if c in feats.columns]
        adm = feats.set_index(case_col)[keep]
        adm.index = adm.index.astype(df.index.dtype)
        df = df.join(adm, how='left')
        n_missing = int(df[keep].isna().any(axis=1).sum())
        print(f"  Joined {keep}; {n_missing} cases without a match")
        if 'admission_no' in df.columns:
            df['prior_admissions'] = (
                pd.to_numeric(df['admission_no'], errors='coerce') - 1
            ).clip(lower=0, upper=5)

    df = df.reset_index(drop=True)

    stable_cols = ['age_group', 'gender', 'los_category'] + list(stable_act_df.columns)
    flexible_cols = list(drug_df.columns)

    for c in stable_cols + flexible_cols:
        if c in df.columns:
            df[c] = df[c].astype(str)

    return df, stable_cols, flexible_cols, event_log
