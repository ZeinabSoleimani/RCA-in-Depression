#!/usr/bin/env python3
"""
End-to-end test on synthetic data. No patient data is used.
I run the pipeline on data/synthetic_test/event_log_sample.csv. In this log,
three pairs of condition and drug have a built-in effect. The test reports
whether the pipeline finds them.
"""

import os
import pandas as pd

GROUND_TRUTH = {
    ('diabetes_type2', 'metformin'):  0.65,
    ('heart_failure',  'furosemide'): 0.70,
    ('hypertension',   'lisinopril'): 0.60,
}

NOISE_DRUGS = ['atorvastatin', 'amlodipine', 'omeprazole', 'metoprolol', 'sertraline', 'aspirin']

TEST_DATA_DIR   = 'data/synthetic_test'
TEST_OUTPUT_DIR = 'outputs/synthetic_test'

_OVERRIDES = {
    'DATA_DIR':               TEST_DATA_DIR,
    'OUTPUT_DIR':             TEST_OUTPUT_DIR,
    'ACTIVITY_MIN_FREQUENCY': 0.04,
    'AR_MIN_SUPPORT_PCT':     0.02,
    'AR_MIN_CONFIDENCE':      0.65,
    'TOP_N_DRUGS':            10,
    'UPLIFT_MIN_MAX_ITE':     -2.0,
}


def _apply(cfg):
    saved = {k: getattr(cfg, k) for k in _OVERRIDES if hasattr(cfg, k)}
    for k, v in _OVERRIDES.items():
        setattr(cfg, k, v)
    return saved


def _restore(cfg, saved):
    for k, v in saved.items():
        setattr(cfg, k, v)


def run_pipeline() -> dict:
    import config as cfg
    saved = _apply(cfg)
    os.makedirs(TEST_OUTPUT_DIR, exist_ok=True)
    try:
        from src.preprocessing import prepare_data
        from src.eda import save_eda
        cases_df, stable_cols, flexible_cols, event_log = prepare_data(TEST_DATA_DIR)
        save_eda(event_log, TEST_OUTPUT_DIR)

        from src.lift_rules import prepare_ar_dataframe, run_lift_rules, extract_treatments
        ar_df = prepare_ar_dataframe(cases_df, stable_cols, flexible_cols)
        pretty, json_export = run_lift_rules(ar_df, stable_cols, flexible_cols)
        with open(os.path.join(TEST_OUTPUT_DIR, 'action_rules.txt'), 'w') as f:
            f.write('\n'.join(pretty))

        treatments = extract_treatments(json_export, flexible_cols) or flexible_cols

        from src.uplift import fit_uplift
        condition_cols = [c for c in stable_cols if c.startswith('cond__')]
        uplift_summary, _, ite_arrays = fit_uplift(cases_df, treatments, condition_cols)

        from src.causal_rules import assemble_causal_rules
        causal_rules_df = assemble_causal_rules(json_export, uplift_summary, flexible_cols, cases_df, ite_arrays)
        causal_rules_df.to_csv(os.path.join(TEST_OUTPUT_DIR, 'causal_rules.csv'), index=False)

        from compute_lift import compute_lift_for_subgroup, _parse_precondition
        lift_rows = []
        for _, row in causal_rules_df.iterrows():
            try:
                sd = _parse_precondition(row['precondition'], stable_cols)
            except ValueError:
                continue
            r = compute_lift_for_subgroup(ar_df, sd, row['treatment'])
            if r:
                lift_rows.append({'treatment': row['treatment'], 'precondition': row['precondition'],
                                   'subgroup_ite': row['subgroup_ite'], **r})
        lift_df = pd.DataFrame(lift_rows) if lift_rows else pd.DataFrame()
        if not lift_df.empty:
            lift_df.to_csv(os.path.join(TEST_OUTPUT_DIR, 'causal_rules_with_lift.csv'), index=False)

        return {'causal_rules': causal_rules_df, 'flexible_cols': flexible_cols}
    finally:
        _restore(cfg, saved)


def _recovered(causal_rules: pd.DataFrame, cond: str, drug: str) -> tuple[bool, str]:
    drug_col   = f'drug__{drug}'
    cond_clean = cond.replace('_', ' ').title()

    for _, row in causal_rules.iterrows():
        if row['treatment'] != drug_col:
            continue
        precond = row['precondition']
        if cond_clean not in precond:
            continue
        idx     = precond.index(cond_clean)
        snippet = precond[idx: idx + len(cond_clean) + 10]
        if '= 0' in snippet:
            continue
        ite = row['subgroup_ite']
        if ite > 0:
            return True, f'ITE={ite:+.4f}  "{precond}"'
        return False, f'found but ITE={ite:+.4f} (wrong direction)'

    return False, 'no matching rule'


def evaluate(outputs: dict) -> None:
    causal_rules  = outputs['causal_rules']
    flexible_cols = outputs.get('flexible_cols', [])

    print(f'{"CONDITION":<22} {"DRUG":<14} {"EFFECT":<8} {"CAUGHT?":<10} DETAIL')
    print('-' * 75)
    n_caught = 0
    for (cond, drug), effect in GROUND_TRUTH.items():
        ok, detail = _recovered(causal_rules, cond, drug)
        n_caught += ok
        print(f'{cond:<22} {drug:<14} -{effect:.0%}    {"YES" if ok else "NO "}     {detail}')

    print('-' * 75)
    print(f'Recovered {n_caught}/{len(GROUND_TRUTH)} planted signals')

    noise_cols = {f'drug__{d}' for d in NOISE_DRUGS}
    fp = causal_rules[causal_rules['treatment'].isin(noise_cols)]
    if fp.empty:
        print('False positives: none')
    else:
        print(f'False positives: {len(fp)} noise rule(s), max ITE {fp["subgroup_ite"].max():+.4f}')


if __name__ == '__main__':
    outputs = run_pipeline()
    evaluate(outputs)
