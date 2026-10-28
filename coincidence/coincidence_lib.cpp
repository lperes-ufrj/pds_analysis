#include "coincidence_lib.hpp"

#include <TChain.h>

#include <algorithm>
#include <cmath>
#include <fstream>
#include <limits>
#include <numeric>
#include <sstream>
#include <stdexcept>

namespace {

constexpr std::size_t PEAK_SMOOTHING_WINDOW = 10;
constexpr double DEFAULT_MINIMUM_PEAK_HEIGHT_ADC = 500.0;
constexpr double DEFAULT_MINIMUM_PEAK_HEIGHT_SIGMA = 10.0;

struct PeakCandidate {
    int tick = -1;
    double amplitude = 0.0;
};

std::string trimIntervalLine(const std::string &text)
{
    const auto first = text.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    const auto last = text.find_last_not_of(" \t\r\n");
    return text.substr(first, last - first + 1);
}

std::vector<std::string> splitWhitespaceFields(const std::string &line)
{
    std::istringstream input(line);
    std::vector<std::string> fields;
    std::string field;
    while (input >> field) fields.push_back(field);
    return fields;
}

}  // namespace

WaveformAnalyzer::WaveformAnalyzer(const std::string &ini_file)
    : minimum_peak_height_adc_(DEFAULT_MINIMUM_PEAK_HEIGHT_ADC),
      minimum_peak_height_sigma_(DEFAULT_MINIMUM_PEAK_HEIGHT_SIGMA)
{
    std::ifstream input(ini_file);
    if (!input) throw std::runtime_error("Could not open config file: " + ini_file);

    unsigned int current_channel = 0;
    bool in_channel_section = false;
    bool in_peak_finder_section = false;
    std::string line;

    while (std::getline(input, line)) {
        line = trimIntervalLine(line);
        if (line.empty() || line.front() == '#' || line.front() == ';') continue;

        if (line.front() == '[' && line.back() == ']') {
            const std::string section = line.substr(1, line.size() - 2);
            constexpr const char prefix[] = "channel_";
            in_channel_section = section.rfind(prefix, 0) == 0;
            in_peak_finder_section = section == "peak_finder";
            if (in_channel_section) {
                current_channel = static_cast<unsigned int>(std::stoul(section.substr(8)));
            }
            continue;
        }

        if (!in_channel_section && !in_peak_finder_section) continue;
        const auto equals = line.find('=');
        if (equals == std::string::npos) continue;

        const std::string name = trimIntervalLine(line.substr(0, equals));
        const std::string value = trimIntervalLine(line.substr(equals + 1));

        if (in_peak_finder_section) {
            const double number = std::stod(value);
            if (!std::isfinite(number) || number < 0.0) {
                throw std::runtime_error("Invalid [peak_finder] value in config: " + line);
            }
            if (name == "min_height_adc") minimum_peak_height_adc_ = number;
            else if (name == "min_height_sigma") minimum_peak_height_sigma_ = number;
            else throw std::runtime_error("Unknown [peak_finder] key in config: " + name);
            continue;
        }

        const auto colon = value.find(':');
        if (colon == std::string::npos) {
            throw std::runtime_error("Invalid interval in config: " + line);
        }

        const int start = std::stoi(trimIntervalLine(value.substr(0, colon)));
        const int stop = std::stoi(trimIntervalLine(value.substr(colon + 1)));
        intervals_[current_channel][name] = {start, stop};
    }
}

std::pair<int, int> WaveformAnalyzer::interval(
    unsigned int channel,
    const std::string &name
) const
{
    const auto channel_it = intervals_.find(channel);
    if (channel_it == intervals_.end()) {
        throw std::runtime_error("Missing config section for channel " + std::to_string(channel));
    }
    const auto interval_it = channel_it->second.find(name);
    if (interval_it == channel_it->second.end()) {
        throw std::runtime_error(
            "Missing interval '" + name + "' for channel " + std::to_string(channel)
        );
    }
    return interval_it->second;
}

std::pair<int, int> WaveformAnalyzer::checkedRegion(
    const std::vector<short> &waveform,
    unsigned int channel,
    const std::string &name
) const
{
    auto [start, stop] = interval(channel, name);
    start = std::max(0, std::min(start, static_cast<int>(waveform.size())));
    stop = std::max(start, std::min(stop, static_cast<int>(waveform.size())));
    if (start == stop) {
        throw std::runtime_error(
            "Empty interval '" + name + "' for channel " + std::to_string(channel)
        );
    }
    return {start, stop};
}

double WaveformAnalyzer::baseline(const std::vector<short> &waveform, int c, int t) const
{
    if (waveform.empty()) {
        throw std::runtime_error("Cannot calculate baseline from an empty waveform");
    }

    const auto [minimum_it, maximum_it] = std::minmax_element(waveform.begin(), waveform.end());
    const int minimum = *minimum_it;
    const int maximum = *maximum_it;
    std::vector<int> counts(static_cast<std::size_t>(maximum - minimum + 1), 0);
    for (const short value : waveform) ++counts[static_cast<std::size_t>(value - minimum)];

    int mode = minimum;
    int mode_count = -1;
    for (int value = minimum; value <= maximum; ++value) {
        const int count = counts[static_cast<std::size_t>(value - minimum)];
        if (count > mode_count) {
            mode = value;
            mode_count = count;
        }
    }

    const int lower = mode - c;
    const int upper = mode + c;
    const std::size_t stride = static_cast<std::size_t>(std::max(1, t));
    double sum = 0.0;
    std::size_t accepted = 0;

    for (std::size_t tick = 0; tick < waveform.size();) {
        const int value = waveform[tick];
        if (value >= lower && value <= upper) {
            sum += value;
            ++accepted;
            tick += stride;
        } else {
            ++tick;
        }
    }
    return accepted == 0 ? static_cast<double>(mode) : sum / accepted;
}

double WaveformAnalyzer::amplitude(
    const std::vector<short> &waveform,
    unsigned int channel,
    const std::string &name
) const
{
    const auto [start, stop] = checkedRegion(waveform, channel, name);
    const auto begin = waveform.begin() + start;
    const auto end = waveform.begin() + stop;
    const auto [minimum, maximum] = std::minmax_element(begin, end);
    return static_cast<double>(*maximum) - static_cast<double>(*minimum);
}

double WaveformAnalyzer::noiseBaseline(
    const std::vector<short> &waveform,
    unsigned int channel
) const
{
    const auto [start, stop] = checkedRegion(waveform, channel, "noise");
    std::vector<short> samples(waveform.begin() + start, waveform.begin() + stop);
    const std::size_t middle = samples.size() / 2;
    std::nth_element(samples.begin(), samples.begin() + middle, samples.end());
    const double upper = samples[middle];

    if (samples.size() % 2 != 0) return upper;

    const double lower = *std::max_element(samples.begin(), samples.begin() + middle);
    return (lower + upper) / 2.0;
}

double WaveformAnalyzer::signalAmplitude(
    const std::vector<short> &waveform,
    unsigned int channel
) const
{
    return amplitude(waveform, channel, "signal");
}

double WaveformAnalyzer::baselineAdjustedSignalAmplitude(
    const std::vector<short> &waveform,
    unsigned int channel
) const
{
    const auto [start, stop] = checkedRegion(waveform, channel, "signal");
    const auto peak = std::max_element(waveform.begin() + start, waveform.begin() + stop);
    return static_cast<double>(*peak) - noiseBaseline(waveform, channel);
}

double WaveformAnalyzer::preSignalAmplitude(
    const std::vector<short> &waveform,
    unsigned int channel
) const
{
    return amplitude(waveform, channel, "pre_signal");
}

double WaveformAnalyzer::postSignalAmplitude(
    const std::vector<short> &waveform,
    unsigned int channel
) const
{
    return amplitude(waveform, channel, "post_signal");
}

PeakSearchResult WaveformAnalyzer::findPeak(
    const std::vector<short> &waveform,
    unsigned int channel
) const
{
    PeakSearchResult result;
    if (waveform.size() < 3) return result;

    const double waveform_baseline = noiseBaseline(waveform, channel);
    const double minimum_height = std::max(
        minimum_peak_height_adc_,
        minimum_peak_height_sigma_ * noiseRms(waveform, channel)
    );

    const std::size_t half_window = PEAK_SMOOTHING_WINDOW / 2;
    std::vector<double> smoothed(waveform.size());
    for (std::size_t tick = 0; tick < waveform.size(); ++tick) {
        const std::size_t start = tick > half_window ? tick - half_window : 0;
        const std::size_t stop = std::min(waveform.size(), tick + half_window + 1);
        const double sum = std::accumulate(
            waveform.begin() + static_cast<std::ptrdiff_t>(start),
            waveform.begin() + static_cast<std::ptrdiff_t>(stop),
            0.0
        );
        smoothed[tick] = sum / static_cast<double>(stop - start) - waveform_baseline;
    }

    std::vector<PeakCandidate> candidates;
    for (std::size_t tick = 1; tick + 1 < smoothed.size(); ++tick) {
        const bool is_local_maximum = smoothed[tick] > smoothed[tick - 1]
            && smoothed[tick] >= smoothed[tick + 1];
        if (is_local_maximum && smoothed[tick] >= minimum_height) {
            candidates.push_back({static_cast<int>(tick), smoothed[tick]});
        }
    }

    result.peak_count = candidates.size();
    if (candidates.empty()) return result;

    const auto primary = std::max_element(
        candidates.begin(), candidates.end(),
        [](const PeakCandidate &left, const PeakCandidate &right) {
            return left.amplitude < right.amplitude;
        }
    );
    result.found = true;
    result.tick = primary->tick;
    result.amplitude = primary->amplitude;

    // Ordinary variables keep this lambda capture compatible with ROOT 6.28's
    // C++17 interpreter (capturing structured bindings requires C++20).
    const auto signal_region = checkedRegion(waveform, channel, "signal");
    const int signal_start = signal_region.first;
    const int signal_stop = signal_region.second;
    const auto outside_signal = [signal_start, signal_stop](int tick) {
        return tick < signal_start || tick >= signal_stop;
    };
    result.primary_outside_signal_region = outside_signal(primary->tick);

    if (!result.primary_outside_signal_region) {
        result.additional_outside_signal_region = std::any_of(
            candidates.begin(), candidates.end(),
            [&](const PeakCandidate &candidate) {
                return candidate.tick != primary->tick && outside_signal(candidate.tick);
            }
        );
    }
    return result;
}

int WaveformAnalyzer::signalPeakTick(
    const std::vector<short> &waveform,
    unsigned int channel
) const
{
    const auto [start, stop] = checkedRegion(waveform, channel, "signal");
    return start + static_cast<int>(
        std::distance(
            waveform.begin() + start,
            std::max_element(waveform.begin() + start, waveform.begin() + stop)
        )
    );
}

double WaveformAnalyzer::noiseRms(
    const std::vector<short> &waveform,
    unsigned int channel
) const
{
    const auto [start, stop] = checkedRegion(waveform, channel, "noise");
    const double count = stop - start;
    const double sum = std::accumulate(
        waveform.begin() + start,
        waveform.begin() + stop,
        0.0
    );
    const double mean = sum / count;
    double squared_difference = 0.0;
    for (int index = start; index < stop; ++index) {
        const double difference = waveform[static_cast<std::size_t>(index)] - mean;
        squared_difference += difference * difference;
    }
    return std::sqrt(squared_difference / count);
}

int WaveformAnalyzer::pulseStart(
    const std::vector<short> &waveform,
    unsigned int channel
) const
{
    const auto [start, stop] = checkedRegion(waveform, channel, "signal");
    const double threshold = noiseBaseline(waveform, channel)
        + 10.0 * noiseRms(waveform, channel);
    const auto peak_it = std::max_element(waveform.begin() + start, waveform.begin() + stop);
    int tick = static_cast<int>(std::distance(waveform.begin() + start, peak_it));
    while (tick > 0 && waveform[static_cast<std::size_t>(start + tick - 1)] >= threshold) {
        --tick;
    }
    return start + tick;
}

std::int64_t WaveformAnalyzer::dtNsPulses(
    const std::vector<short> &waveform_a,
    unsigned int channel_a,
    std::uint64_t timestamp_a,
    const std::vector<short> &waveform_b,
    unsigned int channel_b,
    std::uint64_t timestamp_b
) const
{
    const auto time_a = static_cast<std::int64_t>(timestamp_a)
        + pulseStart(waveform_a, channel_a) * SAMPLE_PERIOD_NS;
    const auto time_b = static_cast<std::int64_t>(timestamp_b)
        + pulseStart(waveform_b, channel_b) * SAMPLE_PERIOD_NS;
    return time_a - time_b;
}

std::unique_ptr<TChain> createChain(const std::vector<std::string> &files)
{
    auto chain = std::make_unique<TChain>("WaveformTree");
    for (const auto &file : files) {
        if (chain->Add(file.c_str()) == 0) {
            throw std::runtime_error("Could not add ROOT file to chain: " + file);
        }
    }
    return chain;
}


double WaveformAnalyzer::fprompt(
    const std::vector<short> &waveform,
    unsigned int channel
) const
{
    // Keep the manufacturer mapping and the two windows separate even while
    // they have the same values, so either detector type can be tuned without
    // changing the CSV/export code.
    enum class SipmType { HPK, FBK };
    static const std::unordered_map<unsigned int, SipmType> sipm_types{
        {1010, SipmType::HPK}, {1011, SipmType::HPK},
        {1020, SipmType::HPK}, {1021, SipmType::HPK},
        {1030, SipmType::HPK}, {1031, SipmType::HPK},
        {1040, SipmType::HPK}, {1041, SipmType::HPK},
        {1050, SipmType::HPK}, {1051, SipmType::HPK},
        {1060, SipmType::HPK}, {1061, SipmType::HPK},
        {1070, SipmType::HPK}, {1071, SipmType::HPK},
        {1080, SipmType::HPK}, {1081, SipmType::HPK},
        {2050, SipmType::FBK}, {2051, SipmType::FBK},
        {2060, SipmType::HPK}, {2061, SipmType::HPK},
        {2070, SipmType::HPK}, {2071, SipmType::HPK},
        {2080, SipmType::FBK}, {2081, SipmType::FBK},
    };
    constexpr std::pair<int, int> HPK_FAST_INTERVAL{60, 90};
    constexpr std::pair<int, int> FBK_FAST_INTERVAL{60, 90};

    const auto type = sipm_types.find(channel);
    if (type == sipm_types.end()) {
        throw std::runtime_error(
            "Missing SiPM type for channel " + std::to_string(channel)
        );
    }

    const auto [signal_start, signal_stop] = checkedRegion(waveform, channel, "signal");
    const auto [configured_prompt_start, configured_prompt_stop] =
        type->second == SipmType::HPK ? HPK_FAST_INTERVAL : FBK_FAST_INTERVAL;
    if (configured_prompt_start < signal_start
        || configured_prompt_stop > signal_stop
        || configured_prompt_start >= configured_prompt_stop) {
        throw std::runtime_error(
            "Prompt interval is not contained in the signal interval for channel "
            + std::to_string(channel)
        );
    }
    const int prompt_start = configured_prompt_start;
    const int prompt_stop = configured_prompt_stop;

    const double waveform_baseline = noiseBaseline(waveform, channel);
    double total_charge = 0.0;
    double prompt_charge = 0.0;
    for (int index = signal_start; index < signal_stop; ++index) {
        const double charge =
            static_cast<double>(waveform[static_cast<std::size_t>(index)])
            - waveform_baseline;
        total_charge += charge;
        if (index >= prompt_start && index < prompt_stop) {
            prompt_charge += charge;
        }
    }
    if (total_charge == 0.0) return 0.0;
    return prompt_charge / total_charge;
}

// --------------------------------------------- normalized-rate amplitude cut

NormRateAdcThresholds readNormRateAdcThresholds(const std::string &threshold_file)
{
    std::ifstream input(threshold_file);
    if (!input) {
        throw std::runtime_error(
            "Could not open normalized-rate ADC-threshold file: "
            + threshold_file
        );
    }

    NormRateAdcThresholds thresholds;
    bool found_header = false;
    std::size_t channel_column = 0;
    std::size_t target_frequency_column = 0;
    std::size_t threshold_column = 0;
    std::size_t line_number = 0;
    std::string line;

    while (std::getline(input, line)) {
        ++line_number;
        line = trimIntervalLine(line);
        if (line.empty()) continue;

        const bool comment = line.front() == '#';
        if (comment) line = trimIntervalLine(line.substr(1));
        if (line.empty()) continue;

        const auto fields = splitWhitespaceFields(line);
        if (!found_header) {
            const auto channel = std::find(fields.begin(), fields.end(), "channel");
            const auto target_frequency = std::find(
                fields.begin(), fields.end(), "target_frequency_khz"
            );
            const auto threshold = std::find(fields.begin(), fields.end(), "threshold_adc");
            if (channel != fields.end() && target_frequency != fields.end()
                && threshold != fields.end()) {
                channel_column = static_cast<std::size_t>(
                    std::distance(fields.begin(), channel)
                );
                target_frequency_column = static_cast<std::size_t>(
                    std::distance(fields.begin(), target_frequency)
                );
                threshold_column = static_cast<std::size_t>(
                    std::distance(fields.begin(), threshold)
                );
                found_header = true;
                continue;
            }
            if (comment) continue;
            throw std::runtime_error(
                "Normalized-rate ADC-threshold file must contain 'channel', "
                "'target_frequency_khz', and 'threshold_adc' "
                "columns: " + threshold_file
            );
        }

        if (comment) continue;
        const std::size_t required_column = std::max(
            {channel_column, target_frequency_column, threshold_column}
        );
        if (fields.size() <= required_column) {
            throw std::runtime_error(
                "Malformed normalized-rate ADC-threshold row "
                + std::to_string(line_number)
                + " in " + threshold_file
            );
        }

        unsigned int channel = 0;
        NormRateAdcThreshold rate_threshold;
        try {
            const std::string &channel_text = fields[channel_column];
            if (!channel_text.empty() && channel_text.front() == '-') {
                throw std::invalid_argument("negative channel");
            }
            std::size_t consumed = 0;
            const unsigned long long parsed_channel = std::stoull(channel_text, &consumed);
            if (consumed != channel_text.size()
                || parsed_channel > std::numeric_limits<unsigned int>::max()) {
                throw std::out_of_range("invalid channel");
            }
            channel = static_cast<unsigned int>(parsed_channel);

            const std::string &target_frequency_text = fields[target_frequency_column];
            consumed = 0;
            rate_threshold.target_frequency_khz = std::stod(
                target_frequency_text, &consumed
            );
            if (consumed != target_frequency_text.size()) {
                throw std::invalid_argument("invalid target frequency");
            }

            const std::string &threshold_text = fields[threshold_column];
            consumed = 0;
            rate_threshold.threshold_adc = std::stod(threshold_text, &consumed);
            if (consumed != threshold_text.size()) {
                throw std::invalid_argument("invalid threshold");
            }
        } catch (const std::exception &) {
            throw std::runtime_error(
                "Invalid normalized-rate ADC-threshold values on row "
                + std::to_string(line_number)
                + " in " + threshold_file
            );
        }

        if (!thresholds.emplace(channel, rate_threshold).second) {
            throw std::runtime_error(
                "Duplicate normalized-rate ADC-threshold channel "
                + std::to_string(channel)
                + " in " + threshold_file
            );
        }
    }

    if (!found_header) {
        throw std::runtime_error(
            "Normalized-rate ADC-threshold file has no header: "
            + threshold_file
        );
    }
    return thresholds;
}

double baselineToPeakAmplitude(const std::vector<short> &adc)
{
    const std::size_t baseline_stop = std::min(RATE_BASELINE_LAST_SAMPLE, adc.size());
    const std::size_t signal_stop = std::min(RATE_SIGNAL_LAST_SAMPLE, adc.size());
    if (RATE_BASELINE_FIRST_SAMPLE >= baseline_stop || RATE_SIGNAL_FIRST_SAMPLE >= signal_stop) {
        return std::numeric_limits<double>::quiet_NaN();
    }

    const double baseline_sum = std::accumulate(
        adc.begin() + static_cast<std::ptrdiff_t>(RATE_BASELINE_FIRST_SAMPLE),
        adc.begin() + static_cast<std::ptrdiff_t>(baseline_stop),
        0.0
    );
    const double baseline = baseline_sum
        / static_cast<double>(baseline_stop - RATE_BASELINE_FIRST_SAMPLE);
    const auto peak = std::max_element(
        adc.begin() + static_cast<std::ptrdiff_t>(RATE_SIGNAL_FIRST_SAMPLE),
        adc.begin() + static_cast<std::ptrdiff_t>(signal_stop)
    );
    return static_cast<double>(*peak) - baseline;
}

bool passesNormRateAdcThreshold(double amplitude, double threshold)
{
    return std::isfinite(amplitude) && amplitude >= threshold;
}

// ------------------------------------------------- waveform quality cuts

namespace {

double maximumAbsoluteAmplitudeInRegion(
    const std::vector<short> &adc,
    const WaveformAnalyzer &analyzer,
    unsigned int channel,
    const std::string &name,
    double baseline
)
{
    auto [start, stop] = analyzer.interval(channel, name);
    start = std::max(0, std::min(start, static_cast<int>(adc.size())));
    stop = std::max(start, std::min(stop, static_cast<int>(adc.size())));
    if (start == stop) throw std::runtime_error("Empty " + name + " interval");

    double amplitude = 0.0;
    for (int i = start; i < stop; ++i) {
        amplitude = std::max(
            amplitude,
            std::abs(static_cast<double>(adc[i]) - baseline)
        );
    }
    return amplitude;
}

double maximumInRegion(
    const std::vector<short> &adc,
    const WaveformAnalyzer &analyzer,
    unsigned int channel,
    const std::string &name
)
{
    auto [start, stop] = analyzer.interval(channel, name);
    start = std::max(0, std::min(start, static_cast<int>(adc.size())));
    stop = std::max(start, std::min(stop, static_cast<int>(adc.size())));
    if (start == stop) throw std::runtime_error("Empty " + name + " interval");
    return *std::max_element(adc.begin() + start, adc.begin() + stop);
}


double fullRangeAmplitude(const std::vector<short> &adc, double baseline)
{
    if (adc.empty()) {
        throw std::runtime_error("Cannot calculate amplitude from an empty waveform");
    }
    return static_cast<double>(*std::max_element(adc.begin(), adc.end())) - baseline;
}

}  // namespace

Coin1p0vSelectionDecision evaluateCoin1p0vSelection(
    const std::vector<short> &adc,
    unsigned int channel,
    double baseline,
    const WaveformAnalyzer &analyzer,
    double max_auxiliary_amplitude,
    double max_full_range_amplitude
)
{
    // Keep these calculations and strict boundaries synchronized with the old
    // coin_1p0v_code selection.  In particular, these are positive maxima
    // above the noise median (not absolute excursions), and equality passes.
    const double noise_amplitude = maximumInRegion(
        adc, analyzer, channel, "noise"
    ) - baseline;
    const double post_signal_amplitude = maximumAbsoluteAmplitudeInRegion(
    adc, analyzer, channel, "post_signal", baseline
    );
    const bool fails_noise = noise_amplitude > max_auxiliary_amplitude;
    const bool fails_post_signal = post_signal_amplitude > max_auxiliary_amplitude;
    const double amplitude = fullRangeAmplitude(adc, baseline);
    const bool fails_full_range_amplitude = amplitude > max_full_range_amplitude;
    const PeakSearchResult peak = analyzer.findPeak(adc, channel);
    const bool fails_primary_peak = peak.primary_outside_signal_region;
    const bool fails_additional_peak = peak.additional_outside_signal_region;

    return {
        fails_noise,
        fails_post_signal,
        fails_full_range_amplitude,
        fails_primary_peak,
        fails_additional_peak,
        peak.found
    };
}
