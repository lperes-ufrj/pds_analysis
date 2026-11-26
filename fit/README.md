# fit

Fit of the deconvolved signal: two exponentials ⊗ Gaussian + constant.

Analysis step 3: reads the `deconv_<ch>.txt` files produced by `deconvolution/`
and fits the LAr scintillation model.

```bash
python fit/fit.py
```

## Model

```
s(t) = N_f · EMG(t; t0, τ_f, σ) + N_s · EMG(t; t0, τ_s, σ) + C
```

Parametrized by the **areas** `N_f`, `N_s`: the fast/slow integrals (in p.e.)
come straight out of the fit, with Hesse errors, without manual propagation.
The EMG is evaluated in two branches with `erfcx` (`u ≥ 0` and `u < 0`) so it
does not overflow in the tail.

Per-tick error estimated from the fluctuation of the pre-signal region of the
deconvolved signal itself. Fit window in `FIT_WINDOW` (avoids the FFT window
edges and the template wrap region).

## Input

`output/deconvolution/data/deconv_<ch>.txt` — every channel found by the glob.

## Outputs (`$PDS_OUTPUT/fit/`, default `output/fit/`)

| Path | Contents |
|---|---|
| `plots/fit_<ch>.png` | data + fit (linear and log) |
| `data/fit_results.txt` | τ_f, τ_s, N_f, N_s, fast/total, σ, C, χ²/ndf, valid — one channel per line |

## Bin-averaged source (`waveform_fits/fitting_bertolini_binned.py`)

Same fit as `fitting_bertolini_avg.py` (which is left as it was), but the
emitted light is averaged over each 16 ns bin
(`pds/source_models.py::binned_exponential`) instead of sampled at the bin
start. With τ_fast = 6 ns the point-sampled fast component depends on where
t0 falls inside a tick, so A_fast absorbs a factor up to exp(16/6) and
I_fast = A_fast·τ_fast is not the integral the data constrain. That is the
×2.4 jump of A_fast at 40 kV in the M8 coincidence sample (t0 moved 10.8 ns;
exp(5.2/6) = 2.38). Outputs go to `plots_bertolini_binned/`. Extra option:
`--fit-max` (µs). M5/M8 use the wide t0 window (0.9–1.4 µs).

`analysis/fit_comparison/third_continuum_models.py` reads either version's
`parameters/` folder and compares r_fast(E) against φ(E) = A_slow(E)/A_slow(0)
with three models: null (r_fast = φ), constant field-independent fraction
(x + (1−x)φ; third continuum or a recombination/excitation singlet asymmetry,
degenerate in r_fast alone) and Segreto's extra component φ + A·E/(E+ε).
