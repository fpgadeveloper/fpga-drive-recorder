# Supported carrier boards

## List of supported boards

{% set unique_boards = {} %}
{% for design in data.designs %}
    {% if design.publish %}
        {% if design.board not in unique_boards %}
            {% set _ = unique_boards.update({design.board: {"group": design.group, "link": design.link, "designs": []}}) %}
        {% endif %}
        {% set _ = unique_boards[design.board]["designs"].append(design) %}
    {% endif %}
{% endfor %}

{% for group in data.groups %}
    {% set boards_in_group = [] %}
    {% for name, board in unique_boards.items() %}
        {% if board.group == group.label %}
            {% set _ = boards_in_group.append(board) %}
        {% endif %}
    {% endfor %}
    {% if boards_in_group | length > 0 %}
### {{ group.name }} boards

| Carrier board | Target design | FMC connector | M.2 slots (PCIe lanes) |
|---------------|---------------|---------------|------------------------|
{% for name,board in unique_boards.items() %}{% if board.group == group.label %}{% for design in board.designs %}| [{{ name }}]({{ board.link }}) | `{{ design.label }}` | {{ design.connector }} | {% for l in design.lanes %}SSD{{ loop.index }} {{ l }}{{ ", " if not loop.last else "" }}{% endfor %} |
{% endfor %}{% endif %}{% endfor %}
{% endif %}
{% endfor %}

The recorder is being ported to further Linux-capable targets of
[fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie) (Zynq
UltraScale+ and Versal boards); they are added to this list as they are released.

What a carrier needs for this design:

* An FMC connector with the gigabit transceivers for the M.2 slots: four lanes per slot for
  a x4 link, eight for two x4 slots (an HPC or FMC+ connector, depending on the board's
  routing).
* A processor that runs Linux (Zynq UltraScale+ or Versal), with enough DDR memory for the
  hugepage buffer pool (the image reserves 512 MB by default).
* Fabric resources for the recorder's FIFOs (block RAM) and the AXI DMA; the
  [resource usage](architecture.md#resource-usage) of the first target gives an idea.

## Unlisted boards

If you need more information on whether the [FPGA Drive FMC Gen4] or [M.2 M-key Stack FMC]
is compatible with a carrier that is not listed above, please first check the
[compatibility list]. If the carrier is not listed there, please [contact Opsero],
provide us with the pinout of your carrier and we'll be happy to check compatibility. A
carrier that runs the fpga-drive-aximm-pcie design under Linux is a good candidate for the
recorder.

## Board specific notes

### UltraZed-EV Carrier

* The carrier has one HPC FMC connector, which supports two SSDs, each with an independent
  4-lane PCIe Gen3 interface.
* Boot mode: to boot from the SD card, set DIP switch SW2 on the UltraZed-EV SOM to 1000
  (1=ON, 2=OFF, 3=OFF, 4=OFF).
* The Linux console is the PS UART 0 interface on the carrier's USB-UART, at 115200 baud.
* The eMMC on the SOM enumerates as `mmcblk0` and the SD card as `mmcblk1`; the Linux image
  boots its root filesystem from `/dev/mmcblk1p3`.
* The SOM has 4 GB of PS DDR4.

### ZCU106

* The `zcu106_hpc0` design uses the HPC0 FMC connector, which supports two SSDs, each with an
  independent 4-lane PCIe Gen3 interface (XDMA Root Ports).
* The design builds with the free Vivado Standard Edition (no license needed).
* The SSD on the first Root Port is set up by the NVMe driver with a single I/O queue, as on
  the UltraZed-EV (see [Where the bottlenecks are](benchmarks.md#where-the-bottlenecks-are)).

### VCK190

* The `vck190_fmcp1` design uses the FMCP1 connector (FMC+), which supports two SSDs, each
  with an independent 4-lane PCIe Gen4 interface.
* VADJ: the board's system controller normally sets the FMC VADJ supply from the FMC card's
  EEPROM. The Linux image does not depend on it: its U-Boot boot script enables VADJ at
  1.5 V (IR38164 regulator over I2C) before Linux starts, and prints
  `FPGA Drive FMC: enabling VADJ (1.5V) via IR38164` on the console.
* Building the design needs a Vivado **Enterprise** license, because the XCVC1902 device is
  not supported by the free Standard Edition. This is a device license, not an IP license:
  the design itself uses no licensed IP.

[contact Opsero]: https://opsero.com/contact-us
[compatibility list]: https://www.fpgadrive.com/docs/fpga-drive-fmc-gen4/compatibility/
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
