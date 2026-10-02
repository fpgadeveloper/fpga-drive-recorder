# FPGA Drive Recorder

Reference design for recording data generated in the FPGA fabric to a file on an NVMe SSD
connected through Opsero's [FPGA Drive FMC Gen4](https://docs.opsero.com/op063/datasheet/overview/)
or [M.2 M-key Stack FMC](https://docs.opsero.com/op073/datasheet/overview/).

Linux owns the SSD and the filesystem. Sample data is moved zero-copy: a fabric DMA writes
samples into DDR buffers and the NVMe controller reads those same buffers when the file is
written, so the processor only does bookkeeping.

Documentation will be hosted at [recorder.fpgadrive.com](https://recorder.fpgadrive.com).

Development is in progress on the `dev` branch. For a design that simply exposes the SSD as a
Linux block device, see [fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie).

## License

MIT - see LICENSE.txt
