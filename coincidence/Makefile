CXX ?= c++
CXXFLAGS := -O3 -Wall -Wextra -pedantic -std=c++17 $(shell root-config --cflags)
LDLIBS := $(shell root-config --libs)

BIN_DIR := ../bin
PROGRAMS := run_coincidence plot_wfs_coincidence only_selection run_peak_finder
TARGETS := $(addprefix $(BIN_DIR)/,$(PROGRAMS))
HEADERS := coincidence_lib.hpp

.PHONY: all clean test-peak-finder test-group-coincidence $(PROGRAMS)

all: $(TARGETS)

run_coincidence: $(BIN_DIR)/run_coincidence

plot_wfs_coincidence: $(BIN_DIR)/plot_wfs_coincidence

only_selection: $(BIN_DIR)/only_selection

run_peak_finder: $(BIN_DIR)/run_peak_finder

test-peak-finder: $(BIN_DIR)/run_peak_finder
	python3 tests/test_peak_finder.py

# group mode of run_coincidence on synthetic waveforms
test-group-coincidence: | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -Wno-unused-function test_group_coincidence.cpp coincidence_lib.cpp -o $(BIN_DIR)/test_group_coincidence $(LDLIBS)
	$(BIN_DIR)/test_group_coincidence waveform_intervals.ini

$(BIN_DIR):
	mkdir -p $@

$(BIN_DIR)/run_coincidence: run_coincidence.cpp coincidence_lib.cpp $(HEADERS) | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) run_coincidence.cpp coincidence_lib.cpp -o $@ $(LDLIBS)

$(BIN_DIR)/plot_wfs_coincidence: plot_wfs_coincidence.cpp coincidence_lib.cpp waveform_plotting.cpp waveform_plotting.hpp $(HEADERS) | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) plot_wfs_coincidence.cpp coincidence_lib.cpp waveform_plotting.cpp -o $@ $(LDLIBS)

$(BIN_DIR)/only_selection: only_selection.cpp coincidence_lib.cpp waveform_plotting.cpp waveform_plotting.hpp $(HEADERS) | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) only_selection.cpp coincidence_lib.cpp waveform_plotting.cpp -o $@ $(LDLIBS)

$(BIN_DIR)/run_peak_finder: run_peak_finder.cpp coincidence_lib.cpp waveform_plotting.cpp waveform_plotting.hpp $(HEADERS) | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) run_peak_finder.cpp coincidence_lib.cpp waveform_plotting.cpp -o $@ $(LDLIBS)

clean:
	$(RM) $(TARGETS)
