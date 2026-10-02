.. FPGA Drive Recorder documentation master file.

FPGA Drive Recorder
===================

This is the documentation for the FPGA Drive Recorder reference design: zero-copy recording
of data generated in the FPGA fabric to a file on an NVMe SSD, and playback of recordings
into the fabric, using the `FPGA Drive FMC Gen4`_ or the `M.2 M-key Stack FMC`_.


.. toctree::
   :maxdepth: 2
   :caption: User Guide

   description
   architecture
   requirements
   supported_carriers
   supported_ssds
   build_instructions
   yocto
   linux_test
   apps
   benchmarks
   limitations
   troubleshooting
   revision_history

.. toctree::
   :maxdepth: 2
   :caption: Reference

   register_map
   driver
   file_format

.. toctree::
   :maxdepth: 2
   :caption: Customizing the design

   custom_source
   custom_sink


.. _FPGA Drive FMC Gen4: https://docs.opsero.com/op063/datasheet/overview/
.. _M.2 M-key Stack FMC: https://docs.opsero.com/op073/datasheet/overview/
