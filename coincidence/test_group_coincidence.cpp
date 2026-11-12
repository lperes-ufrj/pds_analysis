// Synthetic check of the group mode of run_coincidence (--channels-coincident):
//   make -C coincidence test-group-coincidence
// Built as its own translation unit, linked with coincidence_lib.cpp.
#define COINCIDENCE_NO_MAIN
#include "run_coincidence.cpp"
#undef COINCIDENCE_NO_MAIN

#include <TFile.h>
#include <unistd.h>

namespace {

void check(bool condition, const std::string &message)
{
    if (!condition) throw std::runtime_error(message);
}

std::vector<std::string> readRows(const fs::path &csv, std::string &header)
{
    std::ifstream input(csv);
    std::vector<std::string> rows;
    std::string line;
    std::getline(input, line);
    header = trim(line);
    while (std::getline(input, line)) rows.push_back(trim(line));
    return rows;
}

void expectRows(
    const fs::path &csv, const std::vector<std::string> &expected, const std::string &label
)
{
    std::string header;
    const auto rows = readRows(csv, header);
    const std::string group_columns = ",n_coincident_channels,coincident_channels";
    check(header.size() > group_columns.size()
              && header.substr(header.size() - group_columns.size()) == group_columns,
          label + ": missing group columns in header: " + header);
    check(rows.size() == expected.size(),
          label + ": " + std::to_string(rows.size()) + " rows, expected "
              + std::to_string(expected.size()));
    for (std::size_t index = 0; index < rows.size(); ++index) {
        check(rows[index] == expected[index],
              label + ": row " + std::to_string(index) + " is '" + rows[index]
                  + "', expected '" + expected[index] + "'");
    }
}

}  // namespace

int main(int argc, char **argv)
{
    try {
        check(argc == 2, "usage: test_group_coincidence WAVEFORM_INTERVALS_INI");
        const auto directory = fs::temp_directory_path()
            / ("pds_group_coincidence_test_" + std::to_string(getpid()));
        fs::create_directory(directory);
        const auto input = directory / "input.root";
        {
            TFile file(input.c_str(), "RECREATE");
            TTree tree("WaveformTree", "group coincidence fixtures");
            Int_t event = 0, index = 0;
            UInt_t channel = 0;
            ULong64_t timestamp = 0;
            std::vector<short> adc;
            tree.Branch("event", &event);
            tree.Branch("channel", &channel);
            tree.Branch("waveform_index", &index);
            tree.Branch("timestamp", &timestamp);
            tree.Branch("adc", &adc);
            // Same pulse shape everywhere (start at tick 60), so pulse-time
            // differences are timestamp differences, in ns.
            auto add = [&](int e, int i, unsigned ch, int relative_ns, bool pulse = true) {
                event = e; index = i; channel = ch; timestamp = 1000000 + relative_ns;
                adc.assign(1024, 100);
                for (int n = 0; n < 50; ++n) adc[n] = n % 2 ? 101 : 99;
                if (pulse) adc[60] = 200;
                tree.Fill();
            };
            // 1: four channels spanning exactly 160 ns (inclusive).
            add(1, 0, 2030, 0); add(1, 1, 2031, 50); add(1, 2, 2040, 100); add(1, 3, 2041, 160);
            add(1, 4, 2080, 80);
            // 2: the fourth channel one tick too late: 3 of 4 only.
            add(2, 0, 2030, 0); add(2, 1, 2031, 50); add(2, 2, 2040, 100); add(2, 3, 2041, 176);
            add(2, 4, 2080, 80);
            // 3: a channel with two pulses counts once: 3 distinct channels.
            add(3, 0, 2030, 0); add(3, 1, 2030, 16); add(3, 2, 2031, 32); add(3, 3, 2040, 48);
            add(3, 4, 2080, 0);
            // 4: a pulse failing the minimum amplitude does not count.
            add(4, 0, 2030, 0); add(4, 1, 2031, 0); add(4, 2, 2040, 0); add(4, 3, 2041, 0, false);
            add(4, 4, 2080, 0);
            // 5: saved-waveform boundaries t0 - 160 and t_last + 160 (inclusive),
            //    and one ns past t_last + 160.
            add(5, 0, 2030, 0); add(5, 1, 2031, 50); add(5, 2, 2040, 100); add(5, 3, 2041, 160);
            add(5, 4, 2080, -160); add(5, 5, 2080, 321); add(5, 6, 2080, 320);
            // 6: two overlapping 3-channel groups: the one closer to the
            //    saved pulse is reported.
            add(6, 0, 2030, 0); add(6, 1, 2031, 50); add(6, 2, 2040, 100); add(6, 3, 2041, 200);
            add(6, 4, 2080, 190);
            // 7: a single channel is no coincidence.
            add(7, 0, 2030, 0); add(7, 1, 2080, 0);
            tree.Write();
        }

        const std::string all4 = "2030;2031;2040;2041";
        struct Case {
            std::size_t min_coincident;
            std::size_t events, waveforms;
            std::uint64_t groups;
            std::vector<std::string> rows;
        };
        const std::vector<Case> cases{
            {4, 2, 3, 2, {
                "1,2080,4,160,80,1000000,2030,0,2041,3,4," + all4,
                "5,2080,4,160,-160,1000000,2030,0,2041,3,4," + all4,
                "5,2080,6,160,320,1000000,2030,0,2041,3,4," + all4,
            }},
            {3, 6, 7, 8, {
                "1,2080,4,160,80,1000000,2030,0,2041,3,4," + all4,
                "2,2080,4,126,30,1000050,2031,1,2041,3,3,2031;2040;2041",
                "3,2080,4,48,0,1000000,2030,0,2040,3,3,2030;2031;2040",
                "4,2080,4,0,0,1000000,2030,0,2040,2,3,2030;2031;2040",
                "5,2080,4,160,-160,1000000,2030,0,2041,3,4," + all4,
                "5,2080,6,160,320,1000000,2030,0,2041,3,4," + all4,
                "6,2080,4,150,140,1000050,2031,1,2041,3,3,2031;2040;2041",
            }},
        };

        const WaveformAnalyzer analyzer(argv[1]);
        for (const auto &test : cases) {
            Arguments args;
            args.config = argv[1];
            args.group = {2030, 2031, 2040, 2041};
            args.save = {2080};
            args.min_coincident = test.min_coincident;
            const std::string label = std::to_string(test.min_coincident) + " of 4";
            const auto csv = directory / ("selected_" + std::to_string(test.min_coincident) + ".csv");
            auto chain = createChain({input.string()});
            const auto statistics = scanCoincidence(*chain, analyzer, args, {}, csv.string());
            check(statistics.selected_events == test.events,
                  label + ": " + std::to_string(statistics.selected_events) + " events");
            check(statistics.selected_waveforms == test.waveforms,
                  label + ": " + std::to_string(statistics.selected_waveforms) + " waveforms");
            check(statistics.coincident_pairs == test.groups,
                  label + ": " + std::to_string(statistics.coincident_pairs) + " groups");
            expectRows(csv, test.rows, label);
            std::cout << "PASS: group coincidence, at least " << label << '\n';
        }
        fs::remove_all(directory);
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << std::endl;
        return 1;
    }
}
