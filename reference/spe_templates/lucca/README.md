# lucca templates

Single-photoelectron (SPE) templates for M5 through M8. Each template has 1024
samples in ADC at 16 ns per tick. The suffix `_1` identifies the even channel
and `_2` the odd channel.

| Module | Calibration run | Channels | Template |
|---|---|---|---|
| M5 | 043354 | 2050, 2051 | Tick-wise 1-PE mean minus 0-PE mean, unsmoothed |
| M6 | 043355 | 2060, 2061 | Tick-wise 1-PE mean minus 0-PE mean, unsmoothed |
| M7 | 039365 | 2070, 2071 | Archived SPE templates used in the M7 waveform fits |
| M8 | 039366 | 2080, 2081 | Lucca variant 9C, smoothed in tick pairs |

M5 and M6 use 15 ADC upper cuts before and after the signal and a 12 ADC
late-pulse veto on the 0-PE sample. The M7 files are the archived templates
for channels 2070 and 2071.

Per-tick uncertainty files are supplied for M8. The current uncertainty
sampler assumes the adjacent-pair smoothing of variant 9C.

## M8 files

| File | Channel | Content |
|---|---|---|
| `template_39366_M8_1.txt` | 2080 | 9C template, ADC, 1024 ticks (16 ns), `%.9e` |
| `template_39366_M8_2.txt` | 2081 | same, array 2 |
| `sigma_39366_M8_1.txt`, `sigma_39366_M8_2.txt` | 2080, 2081 | total 1σ uncertainty per tick of the 9C template, ADC |

The `sigma_*` files do not match the template file name pattern, so
`pds.modules` ignores them. Only `fitting_bertolini_avg.py --propagate-uncertainties`
reads them.

## M8 template construction

1. Raw 1024-tick waveforms of run 039366, per channel. Baseline: mode of the
   waveform, then mean of the samples within 8 ADC of the mode.
2. Quality cuts, in sequence: RMS of ticks 0-239 < 30 ADC; ticks 0-239 within
   ±15 ADC; max of ticks 270-1023 < 80 ADC; ticks 350-1023 within ±15 ADC.
3. Fingerplot: charge = sum of ticks 255-265. Four-Gaussian fit (Minuit) gives q0,
   spacing g, widths.
4. One-PE sample: q1 − σ1 < Q < q1 + σ1. Zero-PE sample:
   q0 − 3σ0 < Q < min(q0 + 3σ0, q0 + g/2).
5. 9A = tick-wise mean(1 PE) − mean(0 PE). 9B = 9A minus the mean of ticks 0-199.
   **9C** = 9B averaged in non-overlapping tick pairs (each pair value is written
   to both ticks).
6. Uncertainty of 9C = statistical error of the pair means ⊕ ADC quantization
   (1/√12 ADC) ⊕ tick resolution (|dT/dtick|/√12).

Events (zero PE / one PE): 2080 → 3314 / 1984; 2081 → 3547 / 2263.
Residual offsets removed in 9B: 2080 → −0.196 ADC; 2081 → −0.222 ADC.

Peak ≈ 10.0 ADC (2080) and 9.5 ADC (2081) at tick 264, the same scale as the
`francesca` M8 templates (peak ≈ 9.8 ADC at tick 267).

Source code and logbook: `calib/understanding_template/` of sag_analysis
(`compare_approaches.py`, `SPE_Template_Logbook.tex`), not committed there.

## M8 fit settings

`fit_max` = 4.5 µs and t0 ∈ [0.84, 1.04] µs for M8 with this set (`SET_TUNING`
in `fit/waveform_fits/fitting_bertolini_avg.py`). The francesca values
(2.95 µs, t0 = 1.008 ± 0.010 µs) do not apply: the window excluded the
measured rise of these templates.
