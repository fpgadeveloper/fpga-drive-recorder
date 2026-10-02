# Custom RTL (module references)

Verilog / SystemVerilog sources for the recorder's custom logic (`fdrec_*`).

* `Vivado/scripts/build.tcl` adds every `*.v` and `*.sv` file in this folder to the
  project's `sources_1` fileset (and `*.vh` / `*.svh` as include headers) *before*
  the block design script runs, so the block design can instantiate the modules with
  `create_bd_cell -type module -reference <module_name>`.
* Keep the top module of each module reference in a Verilog (`.v`) file.
* One module per file, file name = module name.
* Each module has a self-checking testbench in `../sim/` (see `../sim/README.md`).
* The register map implemented here is defined in `include/fdrec_regs.h` and
  documented in `docs/source/register_map.md`; keep all three in sync.
