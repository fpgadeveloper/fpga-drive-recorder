# Requirements

In order to build this design and test it on hardware, you will need the following:

* Vivado 2025.2 (the free Standard Edition for most targets; the targets marked "Enterprise"
  in the [target table](build_instructions.md#target-designs), such as the VCK190, need a
  Vivado Enterprise license for the device; the design needs no IP license)
* Vitis 2025.2 (it provides `sdtgen` / `xsct`, which the Yocto flow uses to turn the Vivado
  XSA into a System Device Tree)
* A native Linux machine for the Yocto / EDF build, with
  [Google's repo tool](https://gerrit.googlesource.com/git-repo/) and the host packages
  listed in [Yocto](yocto.md#requirements); the Vivado part also builds on Windows
* 1x [FPGA Drive FMC Gen4] or [M.2 M-key Stack FMC]
* One or two M.2 NVMe PCIe SSDs (see [supported SSDs](supported_ssds)); for RAID0 recording,
  two SSDs on a target with two active M.2 slots
* One of the supported carrier boards listed below, with its USB-UART cable
* A micro-SD card of 8 GB or larger
* Optionally, an Ethernet connection from the board to your network, to log in over SSH

There is no PetaLinux flow (PetaLinux is being retired) and no standalone (baremetal)
application in this design.

## List of supported boards

{% set unique_boards = {} %}
{% for design in data.designs %}
	{% if design.publish %}
	    {% if design.board not in unique_boards %}
	        {% set _ = unique_boards.update({design.board: {"group": design.group, "link": design.link, "connectors": []}}) %}
	    {% endif %}
	    {% if design.connector not in unique_boards[design.board]["connectors"] %}
	    	{% set _ = unique_boards[design.board]["connectors"].append(design.connector) %}
	    {% endif %}
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

| Carrier board        | Supported FMC connector(s)    |
|---------------------|--------------|
{% for name,board in unique_boards.items() %}{% if board.group == group.label %}| [{{ name }}]({{ board.link }}) | {% for connector in board.connectors %}{{ connector }} {% endfor %} |
{% endif %}{% endfor %}
{% endif %}
{% endfor %}

For the list of target designs with the number of M.2 slots and PCIe lanes of each, refer
to the [build instructions](build_instructions.md#target-designs).

[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
