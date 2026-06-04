#!/bin/bash

./zig-out/bin/bskysim-general -n 1010 -w 8 -o traces/100K_general_false data/100K_monotonic.bin simconf/benchmark_false.json
./zig-out/bin/bskysim-general -n 1010 -w 8 -o traces/100K_general_true data/100K_monotonic.bin simconf/benchmark_true.json
./zig-out/bin/bskysim-general -n 1010 -w 8 -o traces/100K_specific_false data/100K_monotonic.bin
./zig-out/bin/bskysim-general -n 1010 -w 8 -o traces/100K_specific_true data/100K_monotonic.bin 

