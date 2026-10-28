#ifndef COINCIDENCE_LIB_HPP
#define COINCIDENCE_LIB_HPP

#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

class TChain;

inline constexpr std::int64_t SAMPLE_PERIOD_NS = 16;

struct PeakSearchResult {
    bool found = false;
    int tick = -1;
    double amplitude = 0.0;
    std::size_t peak_count = 0;
    bool primary_outside_signal_region = false;
    bool additional_outside_signal_region = false;
};

class WaveformAnalyzer {
public:
    explicit WaveformAnalyzer(const std::string &ini_file);

    std::pair<int, int> interval(unsigned int channel, const std::string &name) const;
    double baseline(const std::vector<short> &waveform, int c = 8, int t = 12) const;
    double noiseBaseline(const std::vector<short> &waveform, unsigned int channel) const;
    double amplitude(
        const std::vector<short> &waveform,
        unsigned int channel,
        const std::string &name = "signal"
    ) const;
    double signalAmplitude(const std::vector<short> &waveform, unsigned int channel) const;
    double baselineAdjustedSignalAmplitude(
        const std::vector<short> &waveform,
        unsigned int channel
    ) const;
    double preSignalAmplitude(const std::vector<short> &waveform, unsigned int channel) const;
    double postSignalAmplitude(const std::vector<short> &waveform, unsigned int channel) const;
    PeakSearchResult findPeak(
        const std::vector<short> &waveform,
        unsigned int channel
    ) const;
    int signalPeakTick(const std::vector<short> &waveform, unsigned int channel) const;
    double noiseRms(const std::vector<short> &waveform, unsigned int channel) const;
    // Peak-finder threshold: max(minimumPeakHeightAdc, minimumPeakHeightSigma * noise RMS).
    // Set with an optional [peak_finder] section in the INI file.
    double minimumPeakHeightAdc() const { return minimum_peak_height_adc_; }
    double minimumPeakHeightSigma() const { return minimum_peak_height_sigma_; }
    int pulseStart(const std::vector<short> &waveform, unsigned int channel) const;
    // Baseline-subtracted prompt charge divided by the total signal charge.
    double fprompt(const std::vector<short> &waveform, unsigned int channel) const;
    // fprompt() needs the channel's SiPM type (table in coincidence_lib.cpp).
    bool hasFprompt(unsigned int channel) const;
    std::int64_t dtNsPulses(
        const std::vector<short> &waveform_a,
        unsigned int channel_a,
        std::uint64_t timestamp_a,
        const std::vector<short> &waveform_b,
        unsigned int channel_b,
        std::uint64_t timestamp_b
    ) const;

private:
    using Intervals = std::unordered_map<std::string, std::pair<int, int>>;
    std::unordered_map<unsigned int, Intervals> intervals_;
    double minimum_peak_height_adc_;
    double minimum_peak_height_sigma_;

    std::pair<int, int> checkedRegion(
        const std::vector<short> &waveform,
        unsigned int channel,
        const std::string &name
    ) const;
};

std::unique_ptr<TChain> createChain(const std::vector<std::string> &files);

// Waveform quality cuts shared by plot_wfs_coincidence and only_selection.
// Compatibility contract: these are exactly the five rejection flags used by
// coin_1p0v_code/plot_wfs_coincidence.cpp.  Plotting and reporting additions
// must consume this decision; they must not add acceptance criteria of their own.
struct Coin1p0vSelectionDecision {
    bool fails_noise = false;
    bool fails_post_signal = false;
    bool fails_full_range_amplitude = false;
    bool fails_primary_peak = false;
    bool fails_additional_peak = false;
    // Informational, not one of the five cuts: a significant peak was found.
    bool peak_found = false;

    bool rejected() const
    {
        return fails_noise || fails_post_signal || fails_full_range_amplitude
            || fails_primary_peak || fails_additional_peak;
    }
};

Coin1p0vSelectionDecision evaluateCoin1p0vSelection(
    const std::vector<short> &adc,
    unsigned int channel,
    double baseline,
    const WaveformAnalyzer &analyzer,
    double max_auxiliary_amplitude,
    double max_full_range_amplitude
);

// Normalized-rate amplitude cut (thresholds from analysis/rate_analysis.py),
// used by run_coincidence and only_selection. Amplitude =
// max(ADC[50:180]) - mean(ADC[0:50]); keep these half-open ranges
// synchronized with analysis/rate_analysis.py.
inline constexpr std::size_t RATE_BASELINE_FIRST_SAMPLE = 0;
inline constexpr std::size_t RATE_BASELINE_LAST_SAMPLE = 50;
inline constexpr std::size_t RATE_SIGNAL_FIRST_SAMPLE = 50;
inline constexpr std::size_t RATE_SIGNAL_LAST_SAMPLE = 180;

struct NormRateAdcThreshold {
    double target_frequency_khz = std::numeric_limits<double>::quiet_NaN();
    double threshold_adc = std::numeric_limits<double>::quiet_NaN();
};

using NormRateAdcThresholds =
    std::unordered_map<unsigned int, NormRateAdcThreshold>;

// Reads an equalized_run_RUN_thresholds.txt file (whitespace-separated
// columns channel, target_frequency_khz, threshold_adc).
NormRateAdcThresholds readNormRateAdcThresholds(const std::string &threshold_file);
double baselineToPeakAmplitude(const std::vector<short> &adc);
bool passesNormRateAdcThreshold(double amplitude, double threshold);

#endif
