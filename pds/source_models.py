"""Emitted-light models sampled on the digitizer grid.

The template-convolved fits evaluate the emitted light on the 16 ns grid and
convolve it with the detector response. Sampling an exponential at the grid
points, A*exp(-(t_k - t0)/tau) for t_k >= t0, is fine for the slow component
(tau ~ 1.3 us >> 16 ns) but not for the fast one (tau = 6 ns < 16 ns): the
first sample after t0 carries exp(-delta/tau), where delta = t_k - t0 is the
sub-tick phase of t0. A_fast then has to absorb a factor up to
exp(16/6) ~ 14 that depends only on where t0 sits inside a tick, and the
discrete fast integral is not A_fast*tau_fast.

binned_exponential() averages the exponential over each sample bin instead.
Its sum times dt is exactly A*tau (up to truncation at the end of the
window) for any t0, so A*tau is the physical integral and t0 moves the light
smoothly between bins.
"""
import numpy as np


def binned_exponential(time_array, t0, amplitude, tau, dt=None):
    """Mean of amplitude*exp(-(t - t0)/tau)*theta(t - t0) over each bin.

    Bin k covers [t_k, t_k + dt). Units of time_array, t0, tau and dt must
    agree. Returns an array shaped like time_array.
    """
    time_array = np.asarray(time_array, dtype=float)
    if dt is None:
        dt = time_array[1] - time_array[0]

    lo = np.maximum(time_array, t0)
    hi = time_array + dt
    active = hi > t0

    out = np.zeros_like(time_array)
    out[active] = (amplitude * tau / dt
                   * (np.exp(-(lo[active] - t0) / tau)
                      - np.exp(-(hi[active] - t0) / tau)))
    return out


def sampled_exponential(time_array, t0, amplitude, tau):
    """Point-sampled exponential, as in fitting_bertolini_avg.py (reference)."""
    time_array = np.asarray(time_array, dtype=float)
    out = np.zeros_like(time_array)
    active = time_array >= t0
    out[active] = amplitude * np.exp(-(time_array[active] - t0) / tau)
    return out


def effective_sampled_integral(time_array, t0, amplitude, tau):
    """Integral the point-sampled model really puts on the grid, sum * dt.

    Use it to reinterpret parameter tables written by the point-sampled fit:
    for the fast component this, not A*tau, is what the data constrained.
    """
    dt = time_array[1] - time_array[0]
    return float(np.sum(sampled_exponential(time_array, t0, amplitude, tau)) * dt)
