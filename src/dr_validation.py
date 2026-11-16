"""Stage 3: doubly robust check of the drug effects (AIPW).

An uplift tree only adjusts for the covariates it splits on. Here I adjust for
all covariates at once. I use the augmented inverse probability weighting
(AIPW) estimator:

    effect = mean of  m1(X) - m0(X)
                      + T (Y - m1(X)) / e(X)
                      - (1 - T) (Y - m0(X)) / (1 - e(X))

    Y      1 if the admission was not readmitted (same sign as in the trees)
    T      1 if the drug was given in the stay
    e(X)   the propensity: the probability of getting the drug, given X
    m1(X)  the probability of avoiding readmission with the drug, given X
    m0(X)  the same without the drug

The estimate is correct if the propensity model or the outcome models are
right. This is why it is called doubly robust. The three models are logistic
regressions by default. With config.DR_LEARNER = 'gbm' they are gradient
boosting models. I fit them with 5-fold cross-fitting, so each admission gets
its predictions from models that never saw it. Folds and intervals are grouped
by patient, so several admissions of one patient do not count as independent.

X is the same covariate set as in the trees: sex, age, severity markers,
process history and comorbidities. I leave out length of stay, as in the
trees, because the drug may change it (it is a mediator).

balance_table() checks the propensity model. After weighting by the inverse
propensity, treated and untreated admissions should look alike on every
covariate.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import GroupKFold, KFold
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

from config import DR_LEARNER
from src.uplift import CONFOUNDER_COLS, _prepare_confounder_matrix

N_FOLDS = 5
PROPENSITY_CLIP = 0.01   # I clip the propensities to [0.01, 0.99]
MIN_ARM = 100            # a subgroup needs this many treated and this many untreated


def _make_model():
    if DR_LEARNER == 'gbm':
        # I keep the trees shallow and stop early, so the model cannot memorize the data
        return HistGradientBoostingClassifier(
            max_depth=3, learning_rate=0.05, max_iter=300, min_samples_leaf=50,
            early_stopping=True, validation_fraction=0.15, n_iter_no_change=20,
            random_state=42)
    if DR_LEARNER != 'logit':
        raise ValueError(f"RCA_DR_LEARNER must be 'logit' or 'gbm', not '{DR_LEARNER}'")
    return make_pipeline(StandardScaler(), LogisticRegression(max_iter=5000))


def _fit_predict(X_tr, y_tr, X_te) -> np.ndarray:
    """Predicted probabilities. If y_tr has only one class, I return the training mean."""
    if len(np.unique(y_tr)) < 2:
        return np.full(len(X_te), float(np.mean(y_tr)))
    return _make_model().fit(X_tr, y_tr).predict_proba(X_te)[:, 1]


def _cross_fit(X, t, y, groups):
    n = len(y)
    e, m1, m0 = np.zeros(n), np.zeros(n), np.zeros(n)
    if groups is not None:
        folds = GroupKFold(n_splits=N_FOLDS).split(X, t, groups)
    else:
        folds = KFold(n_splits=N_FOLDS, shuffle=True, random_state=42).split(X)
    for tr, te in folds:
        e[te] = _fit_predict(X[tr], t[tr], X[te])
        tr1, tr0 = tr[t[tr] == 1], tr[t[tr] == 0]
        m1[te] = _fit_predict(X[tr1], y[tr1], X[te])
        m0[te] = _fit_predict(X[tr0], y[tr0], X[te])
    return e, m1, m0


def _mean_se(psi: np.ndarray, groups) -> tuple[float, float]:
    """Mean of the influence values and its standard error, clustered by patient."""
    n = len(psi)
    est = float(psi.mean())
    resid = psi - est
    if groups is None:
        se = float(resid.std(ddof=1) / np.sqrt(n))
    else:
        sums = pd.Series(resid).groupby(np.asarray(groups)).sum().to_numpy()
        se = float(np.sqrt((sums ** 2).sum()) / n)
    return est, se


def _mean_ci(psi: np.ndarray, groups) -> tuple[float, float, float]:
    """Mean of the influence values with a 95% interval clustered by patient."""
    est, se = _mean_se(psi, groups)
    return est, est - 1.96 * se, est + 1.96 * se


def _p_value(est: float, se: float) -> float:
    """Two-sided p-value of a normal test of est = 0."""
    if se <= 0:
        return 1.0
    return float(math.erfc(abs(est / se) / math.sqrt(2)))


def _holm(pvals: np.ndarray) -> np.ndarray:
    """Holm correction for many tests. It controls the chance of any false finding."""
    p = np.asarray(pvals, dtype=float)
    adj = np.full(len(p), np.nan)
    valid = np.where(~np.isnan(p))[0]
    order = valid[np.argsort(p[valid])]
    m = len(order)
    running = 0.0
    for rank, idx in enumerate(order):
        running = max(running, min(1.0, (m - rank) * p[idx]))
        adj[idx] = running
    return adj


def _unadjusted_psi(t: np.ndarray, y: np.ndarray) -> np.ndarray:
    """Influence values of the plain difference between treated and untreated."""
    p = t.mean()
    y1, y0 = y[t == 1].mean(), y[t == 0].mean()
    return (y1 - y0) + t * (y - y1) / p - (1 - t) * (y - y0) / (1 - p)


def _subgroups(cases_df: pd.DataFrame) -> list[tuple[str, np.ndarray]]:
    n = len(cases_df)
    out = [('all admissions', np.ones(n, dtype=bool))]
    if 'ed_arrival' in cases_df.columns:
        ed = pd.to_numeric(cases_df['ed_arrival'], errors='coerce').fillna(0).to_numpy()
        out += [('ED arrival', ed == 1), ('no ED arrival', ed == 0)]
    if 'prior_admissions' in cases_df.columns:
        pa = pd.to_numeric(cases_df['prior_admissions'], errors='coerce').fillna(0).to_numpy()
        if (pa > 0).any():
            out += [('first admission', pa == 0), ('repeat admission', pa > 0)]
    return out


def compute_dr_scores(cases_df: pd.DataFrame, treatments: list,
                      condition_cols: list | None = None) -> dict:
    """I fit the models once per drug and keep the influence value of each admission."""
    X = _prepare_confounder_matrix(cases_df, condition_cols)
    y = (1 - pd.to_numeric(cases_df['readmitted'], errors='coerce').fillna(0).astype(int)).to_numpy()
    groups = cases_df['person_id'].to_numpy() if 'person_id' in cases_df.columns else None
    scores = {'y': y, 'groups': groups, 'treatments': {}}
    for col in treatments:
        t = pd.to_numeric(cases_df[col], errors='coerce').fillna(0).astype(int).to_numpy()
        if t.sum() < MIN_ARM or (t == 0).sum() < MIN_ARM:
            continue
        e, m1, m0 = _cross_fit(X, t, y, groups)
        e_c = np.clip(e, PROPENSITY_CLIP, 1 - PROPENSITY_CLIP)
        psi = m1 - m0 + t * (y - m1) / e_c - (1 - t) * (y - m0) / (1 - e_c)
        scores['treatments'][col] = {'t': t, 'e': e, 'psi': psi}
    return scores


def _covariate_names(cases_df: pd.DataFrame, condition_cols: list | None) -> list:
    """The column names of the matrix from _prepare_confounder_matrix, in the same order."""
    names = ['is_female', 'is_male'] + [c for c in CONFOUNDER_COLS if c in cases_df.columns]
    if condition_cols:
        names += [c for c in condition_cols if c in cases_df.columns]
    return names


def _smd(x: np.ndarray, t: np.ndarray, w: np.ndarray, sd: float) -> float:
    """Weighted mean of x in the treated minus the untreated, divided by sd."""
    m1 = np.average(x[t == 1], weights=w[t == 1])
    m0 = np.average(x[t == 0], weights=w[t == 0])
    return float((m1 - m0) / sd) if sd > 0 else 0.0


def balance_table(cases_df: pd.DataFrame, scores: dict,
                  condition_cols: list | None = None) -> pd.DataFrame:
    """Covariate balance between treated and untreated admissions.

    The standardized mean difference (SMD) is the difference in the mean of a
    covariate between the two groups, divided by its standard deviation.
    smd_raw compares the groups as they are. smd_weighted compares them after
    I weight each admission by the inverse of its propensity (clipped as in
    the AIPW score). A value under 0.1 is usually read as balanced. Both
    columns use the same unweighted standard deviation, so they can be
    compared directly. I write only SMDs, no group means and no counts.
    """
    X = _prepare_confounder_matrix(cases_df, condition_cols)
    names = _covariate_names(cases_df, condition_cols)
    assert len(names) == X.shape[1], 'covariate names do not match the matrix'
    rows = []
    for col, sc in scores['treatments'].items():
        t = sc['t']
        e_c = np.clip(sc['e'], PROPENSITY_CLIP, 1 - PROPENSITY_CLIP)
        w = np.where(t == 1, 1 / e_c, 1 / (1 - e_c))
        ones = np.ones(len(t))
        for name, mask in _subgroups(cases_df):
            t_s = t[mask]
            if t_s.sum() < MIN_ARM or (t_s == 0).sum() < MIN_ARM:
                continue
            for j, cov in enumerate(names):
                x = X[mask, j]
                sd = math.sqrt((x[t_s == 1].var() + x[t_s == 0].var()) / 2)
                rows.append({
                    'treatment':    col,
                    'subgroup':     name,
                    'covariate':    cov,
                    'smd_raw':      round(_smd(x, t_s, ones[mask], sd), 3),
                    'smd_weighted': round(_smd(x, t_s, w[mask], sd), 3),
                })
    return pd.DataFrame(rows)


def _estimates(t_s, y_s, psi_s, e_s, g_s) -> dict:
    u, u_lo, u_hi = _mean_ci(_unadjusted_psi(t_s, y_s), g_s)
    a, a_se = _mean_se(psi_s, g_s)
    return {
        'unadjusted_diff':    round(u, 4),
        'unadjusted_ci_low':  round(u_lo, 4),
        'unadjusted_ci_high': round(u_hi, 4),
        'aipw_effect':        round(a, 4),
        'aipw_ci_low':        round(a - 1.96 * a_se, 4),
        'aipw_ci_high':       round(a + 1.96 * a_se, 4),
        'p_value':            _p_value(a, a_se),
        'propensity_min':     round(float(e_s.min()), 4),
        'propensity_max':     round(float(e_s.max()), 4),
    }


def summarize_dr(cases_df: pd.DataFrame, scores: dict) -> pd.DataFrame:
    """The effect of each drug, for all admissions and for a few fixed subgroups."""
    y, groups = scores['y'], scores['groups']
    rows = []
    for col, sc in scores['treatments'].items():
        t, e, psi = sc['t'], sc['e'], sc['psi']
        for name, mask in _subgroups(cases_df):
            t_s = t[mask]
            if t_s.sum() < MIN_ARM or (t_s == 0).sum() < MIN_ARM:
                continue
            g_s = groups[mask] if groups is not None else None
            rows.append({
                'treatment':    col,
                'subgroup':     name,
                'n_admissions': int(mask.sum()),
                'n_treated':    int(t_s.sum()),
                'n_patients':   int(len(np.unique(g_s))) if g_s is not None else None,
                **_estimates(t_s, y[mask], psi[mask], e[mask], g_s),
                'share_clipped': round(float(((e[mask] < PROPENSITY_CLIP) |
                                              (e[mask] > 1 - PROPENSITY_CLIP)).mean()), 4),
            })
    return pd.DataFrame(rows)


def run_dr_validation(cases_df: pd.DataFrame, treatments: list,
                      condition_cols: list | None = None) -> pd.DataFrame:
    return summarize_dr(cases_df, compute_dr_scores(cases_df, treatments, condition_cols))


def validate_rules(causal_rules_df: pd.DataFrame, cases_df: pd.DataFrame, scores: dict,
                   stable_cols: list, parse_precondition) -> pd.DataFrame:
    """Doubly robust effect of every causal rule, in its own subgroup.

    The subgroup of a rule is the set of admissions that match all of its
    stable attributes. The effect is the mean influence value over that
    subgroup, with an interval clustered by patient. There are many rules and
    they overlap, so I correct the p-values with Holm's method. Verdict:
      benefit      corrected p < 0.05 and the effect is positive
      harm signal  corrected p < 0.05 and the effect is negative
      no evidence  otherwise
    """
    y, groups = scores['y'], scores['groups']
    rows = []
    for _, rule in causal_rules_df.iterrows():
        sc = scores['treatments'].get(rule['treatment'])
        if sc is None:
            continue
        try:
            stable = parse_precondition(rule['precondition'], stable_cols)
        except ValueError:
            continue
        mask = np.ones(len(cases_df), dtype=bool)
        for attr, val in stable.items():
            mask &= cases_df[attr].astype(str).to_numpy() == str(val)
        t_s = sc['t'][mask]
        base = {
            'treatment':        rule['treatment'],
            'precondition':     rule['precondition'],
            'n_subgroup':       int(mask.sum()),
            'n_treated':        int(t_s.sum()),
            'tree_subgroup_ite': rule.get('subgroup_ite'),
        }
        if t_s.sum() < MIN_ARM or (t_s == 0).sum() < MIN_ARM:
            rows.append({**base, 'p_value': np.nan})
            continue
        g_s = groups[mask] if groups is not None else None
        rows.append({**base, **_estimates(t_s, y[mask], sc['psi'][mask], sc['e'][mask], g_s)})

    out = pd.DataFrame(rows)
    if out.empty:
        return out
    out['p_holm'] = _holm(out['p_value'].to_numpy())
    out['verdict'] = np.where(
        out['p_holm'] < 0.05,
        np.where(out['aipw_effect'] > 0, 'benefit', 'harm signal'),
        'no evidence')
    out.loc[out['p_value'].isna(), 'verdict'] = 'too few patients'
    out['p_value'] = out['p_value'].round(6)
    out['p_holm'] = out['p_holm'].round(6)
    return out
