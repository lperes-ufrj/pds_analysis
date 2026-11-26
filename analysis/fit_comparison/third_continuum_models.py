"""Which model describes the fast component vs field?

Reads the parameter tables of a template-convolved fit
(fitting_bertolini_avg.py or fitting_bertolini_binned.py) and compares three
descriptions of r_fast(E) = I_fast(E)/I_fast(0), given the excimer factor
phi(E) = A_slow(E)/A_slow(0) measured by the same fit:

    null       r_fast = phi
               singlet and triplet come from one excimer pool, same fraction
               for direct excitation and recombination. 0 parameters.

    constant   r_fast = x + (1 - x) * phi
               a fraction x of the zero-field fast light does not follow the
               recombination. 1 parameter. Two physics readings give exactly
               this form and r_fast(E) alone cannot tell them apart:
                 (i)  a field-independent prompt component, e.g. the third
                      continuum (Ar++ / Ar+*, 160-325 nm, < 6 ns, field
                      independent: Santorelli et al. 2020, Heindl et al. 2010);
                 (ii) a lower singlet fraction in recombination light than in
                      direct-excitation light (Kubota/Doke): if both channels
                      contribute linearly in R(E), r_fast is linear in phi
                      with intercept 1 - kappa, kappa = (f_r/f) / (s_r/s).
               In both cases x does not depend on E.

    segreto    r_fast = phi + A * E/(E + eps)
               the extra Ar++ component of fit_diff.py (Segreto, 11/09/2025).
               2 parameters.

The diagnostic plot is r_fast against phi: the null is the diagonal, the
constant model is a straight line through (1, 1), Segreto's model bends.

Errors: r_fast_err from the integrals table (includes the E = 0 denominator)
plus the phi error (Aslow_err, both numerator and denominator), propagated
with the slope of each model, in quadrature. The A_slow-I_fast covariance
inside one fit is not in the tables and is ignored.

Usage:
    python analysis/fit_comparison/third_continuum_models.py PARAMS_DIR [PARAMS_DIR ...]
        [--labels L1 L2 ...] [--out DIR]

PARAMS_DIR is a .../plots_bertolini_{avg,binned}/<MODULE>/parameters/ folder.
"""
import argparse
import os
import sys

import numpy as np
import matplotlib.pyplot as plt
from iminuit import Minuit

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(os.path.dirname(SCRIPT_DIR))
sys.path.insert(0, REPO_DIR)
from pds import paths  # noqa: E402

DEFAULT_OUT = str(paths.OUTPUT_DIR / 'analysis' / 'fit_comparison' / 'third_continuum')


def load(params_dir):
    par = np.genfromtxt(os.path.join(params_dir, 'fit_params_vs_field.txt'),
                        names=True, comments='#')
    ing = np.genfromtxt(os.path.join(params_dir, 'integrals_vs_field.txt'),
                        names=True, comments='#')
    if not np.array_equal(par['field_kV'], ing['field_kV']):
        raise ValueError(f'{params_dir}: the two tables have different fields')

    E = ing['efield_kVcm']
    phi = par['Aslow'] / par['Aslow'][0]
    phi_err = phi * np.hypot(par['Aslow_err'] / par['Aslow'],
                             par['Aslow_err'][0] / par['Aslow'][0])
    phi_err[0] = 0.0

    # fits with a parameter at its limit are flagged, not dropped: the caller
    # sees them in the table
    at_limit = np.isclose(par['tau_slow'], 0.7, atol=1e-3) | np.isclose(par['tau_slow'], 1.6, atol=1e-3)

    return dict(E=E, phi=phi, phi_err=phi_err,
                r=ing['r_fast'], r_err=ing['r_fast_err'],
                f_fast=ing['f_fast'], valid=par['valid'].astype(bool),
                at_limit=at_limit, chi2_ndof=par['chi2_ndof'])


def _chi2(pred, slope, d, sel):
    var = d['r_err'][sel]**2 + (slope * d['phi_err'][sel])**2
    return float(np.sum((d['r'][sel] - pred) ** 2 / var))


def fit_models(d):
    sel = d['E'] > 0                       # E = 0 is 1 by construction
    E, phi = d['E'][sel], d['phi'][sel]
    out = {}

    out['null'] = dict(chi2=_chi2(phi, 1.0, d, sel), npar=0, values={}, errors={})

    def chi2_const(x):
        return _chi2(x + (1 - x) * phi, 1 - x, d, sel)
    m = Minuit(chi2_const, x=0.3)
    m.errordef = Minuit.LEAST_SQUARES
    m.limits['x'] = (-1, 1)
    m.migrad(); m.hesse()
    out['constant'] = dict(chi2=m.fval, npar=1, values=m.values.to_dict(),
                           errors=m.errors.to_dict(), m=m)

    def chi2_seg(A, eps):
        return _chi2(phi + A * E / (E + eps), 1.0, d, sel)
    m = Minuit(chi2_seg, A=0.1, eps=0.1)
    m.errordef = Minuit.LEAST_SQUARES
    m.limits['A'] = (0, 2)
    m.limits['eps'] = (1e-4, 5)
    m.migrad(); m.hesse()
    out['segreto'] = dict(chi2=m.fval, npar=2, values=m.values.to_dict(),
                          errors=m.errors.to_dict(), m=m)

    n = int(sel.sum())
    for name, r in out.items():
        r['ndof'] = n - r['npar']
        r['aic'] = r['chi2'] + 2 * r['npar']

    # x per point, to see whether it is constant
    with np.errstate(divide='ignore', invalid='ignore'):
        out['x_point'] = (d['r'] - d['phi']) / (1 - d['phi'])
    return out


def report(label, d, res):
    print(f'\n=== {label} ===')
    print(f'{"E kV/cm":>8} {"phi":>6} {"r_fast":>14} {"r-phi":>7} {"x_i":>6} {"f_fast":>6} {"chi2/ndof":>9} flags')
    for k in range(len(d['E'])):
        flags = []
        if not d['valid'][k]:
            flags.append('INVALID')
        if d['at_limit'][k]:
            flags.append('tau_slow AT LIMIT')
        xi = res['x_point'][k]
        print(f'{d["E"][k]:8.3f} {d["phi"][k]:6.3f} {d["r"][k]:6.3f} +- {d["r_err"][k]:.3f} '
              f'{d["r"][k] - d["phi"][k]:+7.3f} {xi if np.isfinite(xi) else float("nan"):6.3f} '
              f'{d["f_fast"][k]:6.3f} {d["chi2_ndof"][k]:9.2f} {" ".join(flags)}')
    for name in ('null', 'constant', 'segreto'):
        r = res[name]
        pars = ', '.join(f'{k} = {v:.4f} +- {r["errors"][k]:.4f}' for k, v in r['values'].items())
        print(f'  {name:9s} chi2/ndof = {r["chi2"]:7.2f}/{r["ndof"]}  AIC = {r["aic"]:7.2f}  {pars}')
    if d['at_limit'].any() or not d['valid'].all():
        print('  WARNING: some fields have a failed or limit-bound fit; do not read physics from this module')


def plot(results, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    fig, ax = plt.subplots(1, 2, figsize=(12, 5))
    phis = np.linspace(0.3, 1.0, 100)
    for i, (label, d, res) in enumerate(results):
        c = f'C{i}'
        ax[0].errorbar(d['phi'], d['r'], xerr=d['phi_err'], yerr=d['r_err'],
                       fmt='o', ms=4, color=c, label=label)
        x = res['constant']['values']['x']
        ax[0].plot(phis, x + (1 - x) * phis, '-', color=c, lw=1,
                   label=rf'  constant: $x$ = {x:.3f}')
        sel = d['E'] > 0
        ax[1].plot(d['E'][sel], res['x_point'][sel], 'o-', color=c, label=label)
    ax[0].plot(phis, phis, 'k:', lw=1, label='null: $r_f = \\varphi$')
    ax[0].set_xlabel(r'$\varphi = A_s(E)/A_s(0)$')
    ax[0].set_ylabel(r'$r_f = I_f(E)/I_f(0)$')
    ax[0].legend(fontsize=8)
    ax[1].set_xlabel('Electric field [kV/cm]')
    ax[1].set_ylabel(r'$x_i = (r_f - \varphi)/(1 - \varphi)$')
    ax[1].set_title('constant model: flat line')
    ax[1].legend(fontsize=8)
    fig.tight_layout()
    path = os.path.join(out_dir, 'rfast_vs_phi.png')
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f'\n[png] {path}')


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('params_dirs', nargs='+')
    p.add_argument('--labels', nargs='*', default=None)
    p.add_argument('--out', default=DEFAULT_OUT)
    a = p.parse_args()
    labels = a.labels or [os.path.normpath(x).split(os.sep)[-2] for x in a.params_dirs]
    if len(labels) != len(a.params_dirs):
        p.error('--labels must match the number of folders')

    results = []
    for label, folder in zip(labels, a.params_dirs):
        d = load(folder)
        res = fit_models(d)
        report(label, d, res)
        results.append((label, d, res))
    plot(results, a.out)


if __name__ == '__main__':
    main()
