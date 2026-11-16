"""Positive control for the doubly robust check (src/dr_validation.py).

I simulate admissions with confounding by indication and a known drug effect:
+3 points in ED arrivals and -3 points in all other admissions. The plain
difference between treated and untreated is biased here. The AIPW estimate
should find the true effects. No patient data is used.

Run:  python test_dr_simulation.py
      python test_dr_simulation.py --coverage 100       interval coverage over 100 simulations
      RCA_DR_LEARNER=gbm python test_dr_simulation.py   the same with gradient boosting models
"""
import sys

import numpy as np
import pandas as pd

from config import DR_LEARNER
from src.dr_validation import run_dr_validation


def simulate(seed: int = 1, n: int = 20000, n_patients: int = 13000) -> tuple[pd.DataFrame, np.ndarray]:
    rng = np.random.default_rng(seed)
    pid = rng.integers(0, n_patients, size=n)
    age = rng.normal(60, 15, n).clip(18, 100)
    ed = rng.binomial(1, 0.7, n)
    cond = rng.binomial(1, 0.3, (n, 3))
    prior = rng.poisson(0.5, n).clip(0, 5)
    # confounding: ED arrivals, older and repeat patients get the drug more often
    logit_t = -2.2 + 0.8 * ed + 0.02 * (age - 60) + 0.3 * prior
    t = rng.binomial(1, 1 / (1 + np.exp(-logit_t)))
    # the same factors lower the chance of avoiding readmission
    base = 0.92 - 0.06 * ed - 0.002 * (age - 60) - 0.03 * prior - 0.02 * cond[:, 0]
    true_eff = np.where(ed == 1, 0.03, -0.03)
    y_avoid = rng.binomial(1, np.clip(base + t * true_eff, 0.01, 0.99))
    df = pd.DataFrame({
        'person_id': pid, 'age_at_admission': age,
        'gender': np.where(rng.random(n) < 0.63, '8532', '8507'),
        'readmitted': 1 - y_avoid, 'ed_arrival': ed, 'ideation_dx': 0, 'attempt_dx': 0,
        'prior_admissions': prior, 'drug__x': t,
        'cond__a': cond[:, 0], 'cond__b': cond[:, 1], 'cond__c': cond[:, 2],
    })
    return df, true_eff


def _truth(df: pd.DataFrame, true_eff: np.ndarray) -> dict:
    prior = df['prior_admissions'].to_numpy()
    ed = df['ed_arrival'].to_numpy()
    return {
        'all admissions': true_eff.mean(),
        'ED arrival': true_eff[ed == 1].mean(),
        'no ED arrival': true_eff[ed == 0].mean(),
        'first admission': true_eff[prior == 0].mean(),
        'repeat admission': true_eff[prior > 0].mean(),
    }


def coverage(n_runs: int) -> pd.DataFrame:
    """The share of simulations in which the 95% interval contains the true effect."""
    hits = []
    for seed in range(n_runs):
        df, true_eff = simulate(seed=seed)
        res = run_dr_validation(df, ['drug__x'], ['cond__a', 'cond__b', 'cond__c'])
        res['true_effect'] = res['subgroup'].map(_truth(df, true_eff))
        res['covered'] = (res['aipw_ci_low'] <= res['true_effect']) & (res['true_effect'] <= res['aipw_ci_high'])
        hits.append(res[['subgroup', 'covered']])
    return pd.concat(hits).groupby('subgroup', sort=False)['covered'].mean().rename('coverage').reset_index()


if __name__ == '__main__':
    print(f'Stage 3 models: {DR_LEARNER}')
    if len(sys.argv) > 2 and sys.argv[1] == '--coverage':
        print(coverage(int(sys.argv[2])).to_string(index=False))
        sys.exit(0)
    df, true_eff = simulate()
    res = run_dr_validation(df, ['drug__x'], ['cond__a', 'cond__b', 'cond__c'])
    prior = df['prior_admissions'].to_numpy()
    ed = df['ed_arrival'].to_numpy()
    truth = {
        'all admissions': true_eff.mean(),
        'ED arrival': true_eff[ed == 1].mean(),
        'no ED arrival': true_eff[ed == 0].mean(),
        'first admission': true_eff[prior == 0].mean(),
        'repeat admission': true_eff[prior > 0].mean(),
    }
    res['true_effect'] = res['subgroup'].map(truth).round(4)
    res['covered'] = (res['aipw_ci_low'] <= res['true_effect']) & (res['true_effect'] <= res['aipw_ci_high'])
    print(res[['subgroup', 'true_effect', 'unadjusted_diff', 'aipw_effect',
               'aipw_ci_low', 'aipw_ci_high', 'covered']].to_string(index=False))
