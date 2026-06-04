# Benchmarking the potential of two stage compilation

This is a document that describes the approach for benchamrking how much the optimizations that the compiler would introduce if the parameters of `SimConfig` struct are at compile time and not at runtime.

## Set-up

The `build.zig` in this branch compiles two binaries according to the option `build` in `build.zig`.
1. general: accepts a JSON file as a configuration for the simulation, and all the information about those is at runtime: every `config.quantity.sample()` will require a `switch` evaluation, and all the `if(config.trace_to_file)` are going to be executing every time.
2. specific: does not accept a JSON, it has a configuration hardcoded. As it's hardcoded (therefore information at compile-time) the compiler will strip away the switches and the ifs.

## Methodology:

We are going to run the following programs 1010 times with the 100K dataset to obtain statistical rellevant results. The measured quantity is the cpu time took to run the simulation, without setup nor file processing (the function `simulation.simulate(...)` in `main.zig`), which is written in a file to analyze beforehand. The distributions in the configurations are going to be the same for every run, but the `trace_to_file` parameter.
1. general with `benchmark_false.json`
2. general with `benchmark_true.json`
3. specific compiled with `trace_to_file = false`
4. specific compiled with `trace_to_file = true`

The runs will be executed sequentially with 8 workers and the same seed ---so the workload will be distributed accordingly--- and compiled in `ReleaseFast`.


