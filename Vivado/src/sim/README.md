# Testbenches

Self-checking testbenches for the RTL in `../hdl/`, run in the Vivado simulator (xsim)
by `Vivado/scripts/sim.tcl` without a Vivado project:

```
cd Vivado
vivado -mode batch -notrace -source scripts/sim.tcl -tclargs <name>   # tb_<name>.sv
vivado -mode batch -notrace -source scripts/sim.tcl -tclargs all      # every tb_*.sv
```

The script also runs under a plain `tclsh` once Vivado's `settings64.sh` has been
sourced: `tclsh scripts/sim.tcl all`.

Contract for a testbench:

* File `tb_<name>.sv` (or `.v`) whose top module is `tb_<name>`.
* It compiles together with every file in `../hdl/` (XPM macros come from Vivado's
  precompiled `xpm` library).
* It checks its own results, prints a line containing `PASS` when everything is
  correct or a line containing `FAIL` (plus the reason) on any error, then calls
  `$finish`. It must always terminate (use a watchdog that prints `FAIL` on timeout).

A testbench passes only if its output contains `PASS` and no `FAIL`. `sim.tcl` exits
with status 1 if any testbench fails. Work files and logs go to `Vivado/sim/<tb>/`
(gitignored).
