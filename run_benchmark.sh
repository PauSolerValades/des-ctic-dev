#!/bin/bash

#./benchmarking/executables/bskysim-general -n 1010 -w 96 -o ./traces/10K_general_false ./data/10K_monotonic.bin ./simconfs/benchmark_false.json
#./benchmarking/executables/bskysim-general -n 1010 -w 96 -o ./traces/10K_general_true ./data/10K_monotonic.bin ./simconfs/benchmark_true.json
#./benchmarking/executables/bskysim-specific-false -n 1010 -w 96 -o ./traces/10K_specific_false ./data/10K_monotonic.bin
#./benchmarking/executables/bskysim-specific-true -n 1010 -w 96 -o ./traces/10K_specific_true ./data/10K_monotonic.bin

#./benchmarking/executables/bskysim-general -n 1010 -w 12 -o ./traces/100K_general_false ./data/100K_monotonic.bin ./simconfs/benchmark_false.json
#./benchmarking/executables/bskysim-general -n 1010 -w 12 -o ./traces/100K_general_true ./data/100K_monotonic.bin ./simconfs/benchmark_true.json
./benchmarking/executables/bskysim-specific-false -n 1010 -w 10 -o ./traces/100K_specific_false ./data/100K_monotonic.bin
./benchmarking/executables/bskysim-specific-true -n 1010 -w 10 -o ./traces/100K_specific_true ./data/100K_monotonic.bin

