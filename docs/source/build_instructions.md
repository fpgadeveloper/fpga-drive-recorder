# Build instructions

## Source code

The source code for the reference design is managed on this Github repository:

* [https://github.com/fpgadeveloper/fpga-drive-recorder](https://github.com/fpgadeveloper/fpga-drive-recorder)

To get the code, clone the repository with:
```
git clone --recursive https://github.com/fpgadeveloper/fpga-drive-recorder.git
```

## License requirements

The designs use no separately licensed IP. Most of them can be built with the Vivado ML
Standard Edition **without a license**; the designs marked "Enterprise" in the Vivado
Edition column below target a device that the Standard Edition does not support (for
example the XCVC1902 of the VCK190) and need a Vivado Enterprise license.

## Target designs

The table below lists the target design name, the M.2 slots supported by the design and the
FMC connector on which to connect the mezzanine card.

{% for group in data.groups %}
    {% set designs_in_group = [] %}
    {% for design in data.designs %}
        {% if design.group == group.label and design.publish %}
            {% set _ = designs_in_group.append(design.label) %}
        {% endif %}
    {% endfor %}
    {% if designs_in_group | length > 0 %}
### {{ group.name }} designs

| Target board        | Target design     | M.2 Slot 1<br>PCIe Lanes  | M.2 Slot 2<br>PCIe Lanes  | FMC Slot    | Vivado<br> Edition |
|---------------------|-------------------|---------------------------|---------------------------|-------------|-----|
{% for design in data.designs %}{% if design.group == group.label and design.publish %}| [{{ design.board }}]({{ design.link }}) | `{{ design.label }}` | {{ design.lanes[0] }} | {{ design.lanes[1] | default("-") }} | {{ design.connector }} | {{ "Enterprise" if design.license else "Standard 🆓" }} |
{% endif %}{% endfor %}
{% endif %}
{% endfor %}

## Cross-platform build runner

All builds are driven by the `build.py` runner at the root of the repository. Each command
builds whatever it depends on automatically, skips anything that is already built, and
locates the AMD tools itself, so there is no need to source the settings scripts beforehand.

On Linux and on Windows (git bash), commands are run with the `build.sh` shim, which finds a
suitable Python 3 automatically (including the interpreter bundled with the AMD tools).
Windows users who prefer not to use git bash can run the same commands from Command Prompt or
PowerShell using `build.bat` instead (for example `build.bat xsa --target uzev`).

This repository uses git submodules: clone it with `--recursive`, or run
`git submodule update --init` in an existing clone, before building.

To see the available targets and the state of a build:

```
./build.sh list                       # list the targets and their attributes
./build.sh status --target <target>   # show the per-stage artifact state
./build.sh clean --target <target>    # delete a target's generated outputs
```

```{note}
The Linux image (Yocto) can only be built on a native Linux machine; the Vivado project and
XSA build on Windows too. On Windows, the runner refuses the Yocto stage up front and prints
the exact command to run on the Linux machine.
```

### Build Vivado project

This single command creates the Vivado project, generates the bitstream and exports the
hardware to an XSA file:

```
./build.sh xsa --target <target>
```

Valid targets are:
{% for design in data.designs if design.publish %} `{{ design.label }}`{{ ", " if not loop.last else "." }} {% endfor %}

To get the Vivado project and block design without generating a bitstream — for example to
explore or modify the design in the Vivado GUI — run `./build.sh project --target <target>`
instead, then open the project from `Vivado/<target>/`.

### Build Yocto

This builds the Yocto / EDF Linux image (AMD's Embedded Development Framework) with the
`gen-machineconf` / `parse-sdt` flow, including the `fdrec` kernel driver and the recorder
apps. It requires a native Linux machine with
[Google's `repo` tool](https://gerrit.googlesource.com/git-repo/) on the `PATH`; the
`xsct`/`sdtgen` tools come from Vitis, which the runner locates and sources itself. The
Vivado XSA is built first if it does not already exist:

```
./build.sh yocto --target <target>
```

Valid targets for Yocto are:
{% for design in data.designs if design.yocto and design.publish %} `{{ design.label }}`{{ ", " if not loop.last else "." }} {% endfor %}

The first build of a target runs `repo sync` (several GB of git history) and bitbake from
scratch, so it takes a while; subsequent builds are incremental. The output products
(`BOOT.BIN`, `Image`, `boot.scr`, `system.dtb`, `rootfs.wic.xz`, `rootfs.tar.gz`) are gathered
into `Yocto/<target>/images/linux/`. See [Yocto](yocto) for how the image is put together,
how to flash it and how to boot it.

#### Yocto offline build

To build offline (or simply faster), point the build at a locally extracted AMD sstate-cache
mirror.

1. Download the sstate-cache artefacts ("sstate-cache & Downloads - 2025.2") from the AMD
   Embedded Design Tools download page and extract them to a single location, for example
   `/home/user/yocto-sstate`, leaving this directory structure:
   ```
   /home/user/yocto-sstate
                          +---  aarch64       (Zynq UltraScale+)
                          +---  microblaze    (PMU firmware)
                          +---  downloads
   ```
2. Create a text file called `offline.txt` in the `Yocto` directory of the repository
   containing a single line with that path, written with NO TRAILING FORWARD SLASH:
   ```
   /home/user/yocto-sstate
   ```

The Yocto build then auto-detects which architecture sub-directories are present and
configures the build to use the mirror.

### Build everything

This builds everything the target supports — the Vivado project and XSA, then the Yocto
image — and gathers the boot images into `bootimages/*.zip`:

```
./build.sh all --target <target>
./build.sh all --target all      # every target in the repo
```

On Windows, `all` builds everything the host can build and reports the Yocto stage as
`BLOCKED` rather than failing.

### Build the driver and apps outside Yocto

The kernel module and the apps are ordinary Makefile projects, so you can rebuild them
without the Yocto flow, for example on the board itself:

```
make -C sw/fdrec-driver KERNEL_SRC=<configured kernel tree for the board's kernel>
make -C sw/fdrec-apps                # needs liburing (>= 2.2)
```

See [Applications](apps) and [Kernel driver](driver).

### Simulate the custom RTL

The custom RTL in `Vivado/src/hdl/` (`fdrec_tpg`, `fdrec_core` with its ingest, packetizer,
egress and register blocks, and `fdrec_check`) has self-checking testbenches in
`Vivado/src/sim/`. Run them in the Vivado simulator (xsim) with:

```
cd Vivado
vivado -mode batch -notrace -source scripts/sim.tcl -tclargs all
```

Each testbench prints `PASS` or `FAIL`. Run them after you change the RTL; they check the
test pattern, the rate accuracy, drop counting, TLAST framing with drops, the 64-bit
counter latching, the soft reset under traffic and the checker's counters.

[supported Linux distributions]: https://docs.amd.com/r/en-US/ug1144-petalinux-tools-reference-guide/Setting-Up-Your-Environment
