// only_selection: waveform selection without coincidence.
//
// Reads every waveform of the requested channels from the ROOT files of one
// run and applies the same quality cuts as plot_wfs_coincidence (the shared
// evaluateCoin1p0vSelection: noise, post-signal, full-range amplitude, primary
// peak outside the signal window, additional peak outside). Optional extras:
// the normalized-rate amplitude cut that run_coincidence applies to the saved
// channels, a "significant peak required" cut, and a per-channel limit on the
// number of waveforms.
//
// The outputs mirror plot_wfs_coincidence, with the label
// only_selection_scan_run_RUN_TAG in place of coincidence_scan_run_RUN_TAG.

#include "coincidence_lib.hpp"
#include "waveform_plotting.hpp"

#include <TBranch.h>
#include <TChain.h>
#include <TROOT.h>
#include <TStyle.h>
#include <TTree.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

using waveform_plotting::RecordsByChannel;
using waveform_plotting::plotAllWaveformsForSelection;
using waveform_plotting::plotAndSaveStatistics;

constexpr double DEFAULT_MAX_AUXILIARY_AMPLITUDE = 500.0;
constexpr double DEFAULT_MAX_FULL_RANGE_AMPLITUDE = 10000.0;
constexpr std::size_t DEFAULT_MAX_PLOT_WAVEFORMS = 20000;
constexpr Long64_t PROGRESS_INTERVAL = 1000000;
const std::string LABEL_PREFIX = "only_selection_scan_run_";

struct Options {
    fs::path input_list;
    fs::path config;
    fs::path output_dir;
    fs::path rate_threshold_file;
    std::string run;
    std::string tag;
    std::set<unsigned int> channels;
    double max_auxiliary_amplitude = DEFAULT_MAX_AUXILIARY_AMPLITUDE;
    double max_full_range_amplitude = DEFAULT_MAX_FULL_RANGE_AMPLITUDE;
    bool require_peak = false;
    std::size_t max_waveforms = 0;  // per channel, after the rate cut; 0 = all
    std::size_t max_plot_waveforms = DEFAULT_MAX_PLOT_WAVEFORMS;
};

struct WaveformKey {
    int event = 0;
    unsigned int channel = 0;
    int waveform_index = 0;
};

struct FPromptRecord {
    WaveformKey key;
    double value = 0.0;
};

using FPromptRecordsByChannel = std::map<unsigned int, std::vector<FPromptRecord>>;

// Per-channel counts. "entering" plays the role of plot_wfs_coincidence's
// "from coincidence": the population the quality cuts are applied to.
struct CutStatistics {
    std::size_t read = 0;
    std::size_t rejected_rate = 0;
    std::size_t over_limit = 0;
    std::size_t entering = 0;
    std::size_t rejected_noise = 0;
    std::size_t rejected_post_signal = 0;
    std::size_t rejected_full_range_amplitude = 0;
    std::size_t rejected_primary_peak_outside_signal = 0;
    std::size_t rejected_additional_peak_outside_signal = 0;
    std::size_t no_significant_peak = 0;
    std::size_t rejected_combined = 0;
    std::size_t final_selection = 0;

    CutStatistics &operator+=(const CutStatistics &other)
    {
        read += other.read;
        rejected_rate += other.rejected_rate;
        over_limit += other.over_limit;
        entering += other.entering;
        rejected_noise += other.rejected_noise;
        rejected_post_signal += other.rejected_post_signal;
        rejected_full_range_amplitude += other.rejected_full_range_amplitude;
        rejected_primary_peak_outside_signal += other.rejected_primary_peak_outside_signal;
        rejected_additional_peak_outside_signal
            += other.rejected_additional_peak_outside_signal;
        no_significant_peak += other.no_significant_peak;
        rejected_combined += other.rejected_combined;
        final_selection += other.final_selection;
        return *this;
    }
};

struct ScanResult {
    Long64_t tree_entries = 0;
    Long64_t entries_read = 0;
    bool stopped_at_limit = false;
    std::map<unsigned int, CutStatistics> cuts;
    RecordsByChannel before_cuts;      // at most max_plot_waveforms per channel
    RecordsByChannel final_selection;
    FPromptRecordsByChannel final_fprompt;
};

std::string trim(const std::string &text)
{
    const auto first = text.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    const auto last = text.find_last_not_of(" \t\r\n");
    return text.substr(first, last - first + 1);
}

std::string normalizeRun(std::string run)
{
    run = trim(run);
    if (run.rfind("run", 0) == 0 || run.rfind("RUN", 0) == 0) run.erase(0, 3);
    if (run.empty() || !std::all_of(run.begin(), run.end(), ::isdigit)) {
        throw std::runtime_error("Invalid run number: " + run);
    }
    if (run.size() < 6) run.insert(run.begin(), 6 - run.size(), '0');
    return run;
}

std::string executionTimestamp()
{
    const auto now = std::chrono::system_clock::now();
    const std::time_t time = std::chrono::system_clock::to_time_t(now);
    std::tm local_time{};
    localtime_r(&time, &local_time);
    std::ostringstream output;
    output << std::put_time(&local_time, "%Y%m%d_%H%M%S");
    return output.str();
}

void printUsage(const char *program)
{
    std::cout
        << "Usage: " << program << " --channel CH [--channel CH ...] [options] INPUT_LIST.txt\n\n"
        << "Select waveforms without coincidence: every waveform of the requested\n"
        << "channels in the ROOT files of INPUT_LIST goes through the quality cuts of\n"
        << "plot_wfs_coincidence. Outputs use the label only_selection_scan_run_RUN_TAG.\n\n"
        << "Options:\n"
        << "  --channel CH                 Channel to select (repeatable, required)\n"
        << "  --run RUN                    Run number (default: inferred from INPUT_LIST)\n"
        << "  --tag TAG                    Label suffix (default: YYYYMMDD_HHMMSS now)\n"
        << "  --config FILE                Waveform interval INI file\n"
        << "  --output-dir DIR             Output directory\n"
        << "                               (default: coincidence/selected_waveforms/TAG)\n"
        << "  --max-auxiliary-amplitude N  Noise/post-signal limit in ADC (default: 500)\n"
        << "  --max-full-range-amplitude N Full-waveform amplitude limit in ADC (default: 10000)\n"
        << "  --norm-rate-adc-threshold-file FILE\n"
        << "                               Keep only waveforms with max(ADC[50:180]) -\n"
        << "                               mean(ADC[0:50]) >= the channel's threshold, as\n"
        << "                               run_coincidence does for saved channels\n"
        << "  --require-peak               Also reject waveforms without a significant peak\n"
        << "  --max-waveforms N            Use at most N waveforms per channel, after the\n"
        << "                               rate cut, in file order (default: 0 = all)\n"
        << "  --max-plot-waveforms N       Waveforms per channel in the before-cuts density\n"
        << "                               plot (default: 20000; 0 = no plot)\n"
        << "  -h, --help                   Show this help\n";
}

std::size_t parseCount(const std::string &option, const std::string &text)
{
    std::size_t consumed = 0;
    long long value = 0;
    try {
        value = std::stoll(text, &consumed);
    } catch (const std::exception &) {
        consumed = 0;
    }
    if (consumed != text.size() || value < 0) {
        throw std::runtime_error(option + " needs a non-negative integer, got: " + text);
    }
    return static_cast<std::size_t>(value);
}

Options parseOptions(int argc, char **argv, const fs::path &program_dir)
{
    Options options;
    options.config = program_dir / "waveform_intervals.ini";

    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "-h" || argument == "--help") {
            printUsage(argv[0]);
            std::exit(0);
        }
        if (argument == "--require-peak") {
            options.require_peak = true;
            continue;
        }
        if (argument == "--channel" || argument == "--run" || argument == "--tag"
            || argument == "--config" || argument == "--output-dir"
            || argument == "--max-auxiliary-amplitude"
            || argument == "--max-full-range-amplitude"
            || argument == "--norm-rate-adc-threshold-file"
            || argument == "--max-waveforms" || argument == "--max-plot-waveforms") {
            if (++index >= argc) throw std::runtime_error("Missing value for " + argument);
            const std::string value = argv[index];
            if (argument == "--channel") {
                const std::size_t channel = parseCount(argument, value);
                if (channel > std::numeric_limits<unsigned int>::max()) {
                    throw std::runtime_error("Channel out of range: " + value);
                }
                options.channels.insert(static_cast<unsigned int>(channel));
            } else if (argument == "--run") options.run = normalizeRun(value);
            else if (argument == "--tag") options.tag = value;
            else if (argument == "--config") options.config = value;
            else if (argument == "--output-dir") options.output_dir = value;
            else if (argument == "--max-auxiliary-amplitude") {
                options.max_auxiliary_amplitude = std::stod(value);
            } else if (argument == "--max-full-range-amplitude") {
                options.max_full_range_amplitude = std::stod(value);
            } else if (argument == "--norm-rate-adc-threshold-file") {
                options.rate_threshold_file = value;
            } else if (argument == "--max-waveforms") {
                options.max_waveforms = parseCount(argument, value);
            } else {
                options.max_plot_waveforms = parseCount(argument, value);
            }
            continue;
        }
        if (!argument.empty() && argument.front() == '-') {
            throw std::runtime_error("Unknown option: " + argument);
        }
        if (!options.input_list.empty()) {
            throw std::runtime_error("Unexpected positional argument: " + argument);
        }
        options.input_list = argument;
    }

    if (options.input_list.empty()) throw std::runtime_error("Missing input list");
    if (options.channels.empty()) {
        throw std::runtime_error("Missing --channel: give at least one channel to select");
    }
    if (options.tag.empty()) options.tag = executionTimestamp();
    if (!std::all_of(options.tag.begin(), options.tag.end(), [](unsigned char c) {
            return std::isalnum(c) || c == '-' || c == '_';
        })) {
        throw std::runtime_error("--tag may contain only letters, digits, '-' and '_'");
    }
    if (options.output_dir.empty()) {
        options.output_dir = program_dir / "selected_waveforms" / options.tag;
    }
    if (!std::isfinite(options.max_auxiliary_amplitude)
        || options.max_auxiliary_amplitude < 0.0) {
        throw std::runtime_error(
            "Maximum auxiliary amplitude must be a finite, non-negative value"
        );
    }
    if (!std::isfinite(options.max_full_range_amplitude)
        || options.max_full_range_amplitude < 0.0) {
        throw std::runtime_error(
            "Maximum full-range amplitude must be a finite, non-negative value"
        );
    }

    const fs::path command_line_path = fs::absolute(options.input_list);
    const fs::path program_relative_path = program_dir / options.input_list;
    options.input_list = fs::exists(command_line_path)
        ? command_line_path
        : program_relative_path;
    options.config = fs::absolute(options.config);
    options.output_dir = fs::absolute(options.output_dir);
    if (!options.rate_threshold_file.empty()) {
        options.rate_threshold_file = fs::absolute(options.rate_threshold_file);
    }
    return options;
}

std::string inferRun(const fs::path &input_list)
{
    const std::regex run_pattern("run[_-]?([0-9]+)", std::regex::icase);
    std::smatch match;
    const std::string list_name = input_list.filename().string();
    if (std::regex_search(list_name, match, run_pattern)) {
        return normalizeRun(match[1].str());
    }

    std::ifstream input(input_list);
    if (!input) throw std::runtime_error("Could not open input list: " + input_list.string());
    std::string line;
    while (std::getline(input, line)) {
        line = trim(line);
        if (line.empty() || line.front() == '#') continue;
        if (std::regex_search(line, match, run_pattern)) {
            return normalizeRun(match[1].str());
        }
    }
    throw std::runtime_error(
        "Could not infer a run number from input list: " + input_list.string()
        + " (use --run)"
    );
}

std::vector<fs::path> readRootFiles(const fs::path &input_list, const fs::path &repo_dir)
{
    std::ifstream input(input_list);
    if (!input) throw std::runtime_error("Could not open input list: " + input_list.string());

    std::vector<fs::path> files;
    std::string line;
    while (std::getline(input, line)) {
        line = trim(line);
        if (line.empty() || line.front() == '#') continue;

        fs::path path = line;
        if (path.is_relative()) {
            const fs::path list_relative = input_list.parent_path() / path;
            path = fs::exists(list_relative) ? list_relative : repo_dir / path;
        }
        path = fs::absolute(path);
        if (!fs::is_regular_file(path)) {
            throw std::runtime_error("ROOT file not found: " + path.string());
        }
        files.push_back(path);
    }
    if (files.empty()) throw std::runtime_error("No ROOT files found in " + input_list.string());
    return files;
}

template <typename Value>
TBranch *bindBranch(TTree &tree, const char *name, Value *address)
{
    TBranch *branch = nullptr;
    if (tree.GetBranch(name) == nullptr
        || tree.SetBranchAddress(name, address, &branch) < 0 || branch == nullptr) {
        throw std::runtime_error(std::string("Missing or incompatible ROOT branch: ") + name);
    }
    return branch;
}

// Drops channels without a finite threshold, as run_coincidence does for
// saved channels; returns the dropped ones.
std::vector<unsigned int> dropChannelsWithoutRateThreshold(
    std::set<unsigned int> &channels,
    const NormRateAdcThresholds &thresholds,
    const fs::path &threshold_file
)
{
    std::vector<unsigned int> dropped;
    for (auto it = channels.begin(); it != channels.end();) {
        const auto found = thresholds.find(*it);
        const bool valid = found != thresholds.end()
            && std::isfinite(found->second.target_frequency_khz)
            && found->second.target_frequency_khz >= 0.0
            && std::isfinite(found->second.threshold_adc);
        if (valid) {
            ++it;
            continue;
        }
        std::cerr << "Skipping channel " << *it
                  << ": no finite normalized-rate threshold in " << threshold_file << '\n';
        dropped.push_back(*it);
        it = channels.erase(it);
    }
    return dropped;
}

ScanResult scanWaveforms(
    TChain &chain,
    const WaveformAnalyzer &analyzer,
    const std::set<unsigned int> &channels,
    const NormRateAdcThresholds &thresholds,
    const Options &options
)
{
    Int_t event = 0;
    UInt_t channel = 0;
    Int_t waveform_index = 0;
    std::vector<short> samples;
    std::vector<short> *adc = &samples;
    int tree_number = -1;
    TBranch *event_branch = nullptr;
    TBranch *channel_branch = nullptr;
    TBranch *index_branch = nullptr;
    TBranch *adc_branch = nullptr;

    ScanResult result;
    for (const unsigned int requested : channels) result.cuts[requested];
    result.tree_entries = chain.GetEntries();
    std::size_t channels_at_limit = 0;

    for (Long64_t entry = 0; entry < result.tree_entries; ++entry) {
        if (entry % PROGRESS_INTERVAL == 0 && entry > 0) {
            std::size_t selected = 0;
            for (const auto &[ch, cuts] : result.cuts) selected += cuts.final_selection;
            std::cout << "Input: " << entry << '/' << result.tree_entries
                      << " entries; selected=" << selected << std::endl;
        }
        const Long64_t local_entry = chain.LoadTree(entry);
        if (local_entry < 0) {
            throw std::runtime_error("Could not load ROOT entry " + std::to_string(entry));
        }
        if (chain.GetTreeNumber() != tree_number) {
            tree_number = chain.GetTreeNumber();
            TTree *tree = chain.GetTree();
            if (tree == nullptr) throw std::runtime_error("Missing WaveformTree in input file");
            event_branch = bindBranch(*tree, "event", &event);
            channel_branch = bindBranch(*tree, "channel", &channel);
            index_branch = bindBranch(*tree, "waveform_index", &waveform_index);
            adc_branch = bindBranch(*tree, "adc", &adc);
            adc_branch->SetAutoDelete(kFALSE);
        }
        ++result.entries_read;
        // Read the channel first: other channels cost no ADC I/O.
        if (channel_branch->GetEntry(local_entry) <= 0) {
            throw std::runtime_error("Could not read ROOT channel at entry " + std::to_string(entry));
        }
        const auto cuts_it = result.cuts.find(channel);
        if (cuts_it == result.cuts.end()) continue;
        CutStatistics &cuts = cuts_it->second;
        ++cuts.read;
        if (options.max_waveforms > 0 && cuts.entering >= options.max_waveforms) {
            ++cuts.over_limit;
            continue;
        }

        if (event_branch->GetEntry(local_entry) <= 0
            || index_branch->GetEntry(local_entry) <= 0
            || adc_branch->GetEntry(local_entry) <= 0 || adc == nullptr) {
            throw std::runtime_error("Could not read ROOT entry " + std::to_string(entry));
        }

        if (!thresholds.empty()) {
            const double amplitude = baselineToPeakAmplitude(*adc);
            if (!passesNormRateAdcThreshold(amplitude, thresholds.at(channel).threshold_adc)) {
                ++cuts.rejected_rate;
                continue;
            }
        }

        ++cuts.entering;
        const double baseline = analyzer.noiseBaseline(*adc, channel);
        auto &before = result.before_cuts[channel];
        if (before.size() < options.max_plot_waveforms) before.push_back({baseline, *adc});

        const Coin1p0vSelectionDecision decision = evaluateCoin1p0vSelection(
            *adc, channel, baseline, analyzer,
            options.max_auxiliary_amplitude, options.max_full_range_amplitude
        );
        const bool fails_no_peak = !decision.peak_found;
        cuts.rejected_noise += decision.fails_noise;
        cuts.rejected_post_signal += decision.fails_post_signal;
        cuts.rejected_full_range_amplitude += decision.fails_full_range_amplitude;
        cuts.rejected_primary_peak_outside_signal += decision.fails_primary_peak;
        cuts.rejected_additional_peak_outside_signal += decision.fails_additional_peak;
        cuts.no_significant_peak += fails_no_peak;

        const bool rejected = decision.rejected() || (options.require_peak && fails_no_peak);
        if (!rejected) {
            ++cuts.final_selection;
            result.final_selection[channel].push_back({baseline, *adc});
            result.final_fprompt[channel].push_back({
                {event, channel, waveform_index},
                analyzer.fprompt(*adc, channel)
            });
        } else {
            ++cuts.rejected_combined;
        }

        if (options.max_waveforms > 0 && cuts.entering == options.max_waveforms
            && ++channels_at_limit == result.cuts.size()) {
            result.stopped_at_limit = true;
            break;
        }
    }
    return result;
}

std::string joinChannels(const std::vector<unsigned int> &channels)
{
    if (channels.empty()) return "none";
    std::ostringstream output;
    for (std::size_t i = 0; i < channels.size(); ++i) {
        output << (i ? ", " : "") << channels[i];
    }
    return output.str();
}

void writeCutSummary(
    const fs::path &filename,
    const std::string &run,
    const std::string &tag,
    const fs::path &input_list,
    const std::size_t root_files,
    const Options &options,
    const std::set<unsigned int> &channels,
    const std::vector<unsigned int> &dropped_channels,
    const NormRateAdcThresholds &thresholds,
    const WaveformAnalyzer &analyzer,
    const ScanResult &scan
)
{
    std::ofstream output(filename);
    if (!output) {
        throw std::runtime_error("Could not create cut summary: " + filename.string());
    }

    CutStatistics total;
    for (const auto &[channel, cuts] : scan.cuts) total += cuts;

    output << "Waveform selection cut summary\n"
           << "==============================\n"
           << "Mode: only_selection (no coincidence; every waveform of the requested channels)\n"
           << "Analysis identifier: " << tag << '\n'
           << "Run: " << run << '\n'
           << "Input list: " << input_list.string() << '\n'
           << "Input ROOT files: " << root_files << '\n'
           << "Waveform interval configuration: " << options.config.string() << '\n'
           << "Requested channels: " << joinChannels(
                  std::vector<unsigned int>(options.channels.begin(), options.channels.end()))
           << '\n'
           << "Channels used: " << joinChannels(
                  std::vector<unsigned int>(channels.begin(), channels.end())) << '\n'
           << "Channels skipped for missing/invalid rate threshold: "
           << joinChannels(dropped_channels) << '\n'
           << "Normalized-rate ADC-threshold file: "
           << (options.rate_threshold_file.empty()
                   ? std::string("none (no rate cut)")
                   : options.rate_threshold_file.string())
           << '\n';
    if (!thresholds.empty()) {
        output << "Normalized-rate ADC thresholds applied before the quality cuts:\n";
        for (const unsigned int channel : channels) {
            const auto &threshold = thresholds.at(channel);
            output << "  Channel " << channel << ": target="
                   << threshold.target_frequency_khz << " kHz, retain amplitude >= "
                   << threshold.threshold_adc << " ADC\n";
        }
        output << "Threshold amplitude definition: max(ADC[50:180]) - mean(ADC[0:50]) "
                  "(half-open ranges)\n";
    }
    output << "Maximum waveforms per channel: "
           << (options.max_waveforms ? std::to_string(options.max_waveforms) : "all") << '\n'
           << "Tree entries: " << scan.tree_entries << " (read: " << scan.entries_read
           << (scan.stopped_at_limit ? ", stopped once every channel reached the limit" : "")
           << ")\n"
           << "Waveforms read in the used channels: " << total.read << '\n'
           << "Rejected by the normalized-rate amplitude threshold: " << total.rejected_rate << '\n'
           << "Not used (per-channel limit reached): " << total.over_limit << '\n'
           << "Waveforms entering selection: " << total.entering << "\n\n"
           << "Applied cuts\n"
           << "------------\n"
           << "Compatibility: plot_wfs_coincidence selection criteria and boundaries\n"
           << "1. Noise-region maximum ADC minus noise median <= "
           << options.max_auxiliary_amplitude << " ADC\n"
           << "2. Post-signal maximum ADC minus noise median <= "
           << options.max_auxiliary_amplitude << " ADC\n"
           << "3. Full-waveform positive amplitude above baseline <= "
           << options.max_full_range_amplitude << " ADC\n"
           << "4. Primary peak must be inside the configured signal region\n"
           << "5. No significant additional peak may be outside the signal region\n"
           << "   Significant peak: smoothed height >= max("
           << analyzer.minimumPeakHeightAdc() << " ADC, "
           << analyzer.minimumPeakHeightSigma() << " * noise RMS)\n"
           << "6. A significant peak is required: "
           << (options.require_peak ? "yes" : "no (not applied)") << '\n'
           << "------------------------------------------------\n";

    for (const unsigned int channel : channels) {
        const auto noise = analyzer.interval(channel, "noise");
        const auto signal = analyzer.interval(channel, "signal");
        const auto post_signal = analyzer.interval(channel, "post_signal");
        output << "Channel " << channel
               << ": noise=[" << noise.first << ", " << noise.second << ")"
               << ", signal=[" << signal.first << ", " << signal.second << ")"
               << ", post_signal=[" << post_signal.first << ", "
               << post_signal.second << ")\n";
    }

    // Same definition and format as plot_wfs_coincidence: pds/integrals.py
    // reads these lines as the light-yield error per channel.
    output << "\nFinal-selection baseline noise\n"
           << "------------------------------\n"
           << "Definition: sample standard deviation of all baseline-subtracted "
           << "ADC values pooled from ticks [0, 50) of the final-selection waveforms.\n";
    for (const unsigned int channel : channels) {
        const auto found = scan.final_selection.find(channel);
        if (found == scan.final_selection.end() || found->second.empty()) {
            output << "Channel " << channel << ": no final-selection waveforms\n";
            continue;
        }

        std::size_t sample_count = 0;
        double mean = 0.0;
        double sum_squared_difference = 0.0;
        for (const auto &record : found->second) {
            const std::size_t stop = std::min<std::size_t>(50, record.adc.size());
            for (std::size_t sample = 0; sample < stop; ++sample) {
                const double value = static_cast<double>(record.adc[sample])
                    - record.baseline;
                ++sample_count;
                const double difference = value - mean;
                mean += difference / static_cast<double>(sample_count);
                const double updated_difference = value - mean;
                sum_squared_difference += difference * updated_difference;
            }
        }

        output << "Channel " << channel << ": ";
        if (sample_count > 1) {
            output << std::sqrt(sum_squared_difference
                                / static_cast<double>(sample_count - 1))
                   << " ADC";
        } else {
            output << "not enough samples";
        }
        output << " (waveforms=" << found->second.size()
               << ", baseline samples=" << sample_count << ")\n";
    }

    const auto write_counts = [&](const std::string &criterion, std::size_t rejected) {
        output << std::left << std::setw(62) << criterion
               << std::right << std::setw(12) << total.entering - rejected
               << std::setw(12) << rejected << '\n';
    };

    output << "\nCut results\n"
           << "-----------\n"
           << std::left << std::setw(62) << "Criterion"
           << std::right << std::setw(12) << "Accepted"
           << std::setw(12) << "Rejected" << '\n'
           << std::string(86, '-') << '\n';
    write_counts("Noise-region amplitude", total.rejected_noise);
    write_counts("Post-signal amplitude", total.rejected_post_signal);
    write_counts("Full-range amplitude", total.rejected_full_range_amplitude);
    write_counts("Primary peak outside signal region",
                 total.rejected_primary_peak_outside_signal);
    write_counts("Significant additional peak outside signal region",
                 total.rejected_additional_peak_outside_signal);
    if (options.require_peak) {
        write_counts("No significant peak", total.no_significant_peak);
    }
    write_counts("All cuts combined", total.rejected_combined);

    output << "\nFinal selected waveforms: " << total.final_selection << '\n';
    if (!options.require_peak) {
        output << "Waveforms without a significant peak (not a cut here): "
               << total.no_significant_peak << '\n';
    }
    output << "Note: individual rejection categories can overlap; therefore their "
           << "rejected counts should not be summed.\n";

    output << "\nPer-channel counts\n"
           << "------------------\n"
           << std::right << std::setw(8) << "channel" << std::setw(10) << "read"
           << std::setw(10) << "rate_cut" << std::setw(10) << "limit"
           << std::setw(10) << "entering" << std::setw(10) << "noise"
           << std::setw(10) << "post" << std::setw(10) << "full"
           << std::setw(10) << "primary" << std::setw(11) << "additional"
           << std::setw(10) << "no_peak" << std::setw(10) << "final" << '\n';
    for (const auto &[channel, cuts] : scan.cuts) {
        output << std::setw(8) << channel << std::setw(10) << cuts.read
               << std::setw(10) << cuts.rejected_rate << std::setw(10) << cuts.over_limit
               << std::setw(10) << cuts.entering << std::setw(10) << cuts.rejected_noise
               << std::setw(10) << cuts.rejected_post_signal
               << std::setw(10) << cuts.rejected_full_range_amplitude
               << std::setw(10) << cuts.rejected_primary_peak_outside_signal
               << std::setw(11) << cuts.rejected_additional_peak_outside_signal
               << std::setw(10) << cuts.no_significant_peak
               << std::setw(10) << cuts.final_selection << '\n';
    }

    if (!output) {
        throw std::runtime_error("Failed while writing cut summary: " + filename.string());
    }
    std::cout << "Saved " << filename << '\n';
}

void writeFpromptCsvs(
    const FPromptRecordsByChannel &records_by_channel,
    const std::string &run,
    const std::string &label,
    const fs::path &output_dir
)
{
    for (const auto &[channel, records] : records_by_channel) {
        const fs::path filename = output_dir
            / ("fprompt_" + std::to_string(channel) + "_" + label + ".csv");
        std::ofstream output(filename);
        if (!output) throw std::runtime_error("Could not create " + filename.string());
        output << "run,event,channel,waveform_index_save,fprompt\n";
        output << std::setprecision(std::numeric_limits<double>::max_digits10);
        for (const auto &record : records) {
            output << run << ',' << record.key.event << ',' << record.key.channel << ','
                   << record.key.waveform_index << ',' << record.value << '\n';
        }
        if (!output) throw std::runtime_error("Failed while writing " + filename.string());
        std::cout << "Saved " << records.size() << " fprompt values to " << filename << '\n';
    }
}

void process(const Options &options, const fs::path &repo_dir)
{
    if (!fs::is_regular_file(options.input_list)) {
        throw std::runtime_error("Input list not found: " + options.input_list.string());
    }
    const std::string run = options.run.empty() ? inferRun(options.input_list) : options.run;
    const std::string label = LABEL_PREFIX + run + "_" + options.tag;
    std::cout << "\nProcessing run " << run << " (only selection, tag " << options.tag << ")\n";

    std::set<unsigned int> channels = options.channels;
    NormRateAdcThresholds thresholds;
    std::vector<unsigned int> dropped;
    if (!options.rate_threshold_file.empty()) {
        thresholds = readNormRateAdcThresholds(options.rate_threshold_file.string());
        dropped = dropChannelsWithoutRateThreshold(
            channels, thresholds, options.rate_threshold_file);
        if (channels.empty()) {
            throw std::runtime_error("No requested channel has a usable rate threshold in "
                                     + options.rate_threshold_file.string());
        }
    }
    const WaveformAnalyzer analyzer(options.config.string());
    for (const unsigned int channel : channels) {
        analyzer.interval(channel, "noise");  // fail early on a missing channel section
    }

    const auto root_paths = readRootFiles(options.input_list, repo_dir);
    std::vector<std::string> root_files;
    for (const auto &path : root_paths) root_files.push_back(path.string());
    auto chain = createChain(root_files);
    std::cout << "ROOT files: " << root_files.size()
              << "\nTree entries: " << chain->GetEntries() << "\nChannels:";
    for (const auto channel : channels) std::cout << ' ' << channel;
    std::cout << '\n';

    const ScanResult scan = scanWaveforms(*chain, analyzer, channels, thresholds, options);
    for (const auto &[channel, cuts] : scan.cuts) {
        std::cout << "Channel " << channel << ": read " << cuts.read
                  << ", rate cut " << cuts.rejected_rate
                  << ", entering " << cuts.entering
                  << ", selected " << cuts.final_selection << '\n';
    }

    writeCutSummary(
        options.output_dir / ("selection_cuts_" + label + ".txt"),
        run, options.tag, options.input_list, root_files.size(), options,
        channels, dropped, thresholds, analyzer, scan
    );
    writeFpromptCsvs(scan.final_fprompt, run, label, options.output_dir);

    if (options.max_plot_waveforms > 0) {
        plotAllWaveformsForSelection(
            channels, scan.before_cuts, run, label,
            "Before Cuts", "before_cuts", options.output_dir
        );
    }
    if (scan.final_selection.empty()) {
        std::cout << "No waveform passed the selection; no mean waveforms for run "
                  << run << '\n';
        return;
    }
    plotAndSaveStatistics(channels, scan.final_selection, run, label, options.output_dir);
}

}  // namespace

int main(int argc, char **argv)
{
    try {
        const fs::path executable = fs::weakly_canonical(fs::absolute(argv[0]));
        const fs::path executable_dir = executable.parent_path();
        const fs::path program_dir = executable_dir.filename() == "bin"
            ? executable_dir.parent_path() / "coincidence"
            : executable_dir;
        const fs::path repo_dir = program_dir.parent_path();
        const Options options = parseOptions(argc, argv, program_dir);
        if (!fs::is_regular_file(options.config)) {
            throw std::runtime_error("Configuration file not found: " + options.config.string());
        }
        fs::create_directories(options.output_dir);

        gROOT->SetBatch(kTRUE);
        gStyle->SetOptStat(0);
        process(options, repo_dir);
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "Error: " << error.what() << '\n';
        return 1;
    }
}
