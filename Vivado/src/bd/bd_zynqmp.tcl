################################################################
# Block design build script for Zynq US+ designs
################################################################

# Returns true if str contains substr
proc str_contains {str substr} {
  if {[string first $substr $str] == -1} {
    return 0
  } else {
    return 1
  }
}

# GT and PCIe LOCs
set select_quad_0 [dict get $gt_loc_dict $target 0 quad]
set pcie_blk_locn_0 [dict get $gt_loc_dict $target 0 pcie]

if {$dual_design} {
  set select_quad_1 [dict get $gt_loc_dict $target 1 quad]
  set pcie_blk_locn_1 [dict get $gt_loc_dict $target 1 pcie]
}

# CHECKING IF PROJECT EXISTS
if { [get_projects -quiet] eq "" } {
   puts "ERROR: Please open or create a project!"
   return 1
}

set cur_design [current_bd_design -quiet]
set list_cells [get_bd_cells -quiet]

create_bd_design $block_name

current_bd_design $block_name

set parentCell [get_bd_cells /]

# Get object for parentCell
set parentObj [get_bd_cells $parentCell]
if { $parentObj == "" } {
   puts "ERROR: Unable to find parent cell <$parentCell>!"
   return
}

# Make sure parentObj is hier blk
set parentType [get_property TYPE $parentObj]
if { $parentType ne "hier" } {
   puts "ERROR: Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."
   return
}

# Save current instance; Restore later
set oldCurInst [current_bd_instance .]

# Set parent object as current
current_bd_instance $parentObj

# Add the Processor System and apply board preset
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1" }  [get_bd_cells zynq_ultra_ps_e_0]

# Configure the PS: Enable HP0 and HP1 (for dual designs) to DDR
if {$dual_design} {
  set_property -dict [list CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__USE__S_AXI_GP3 {1} \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {1} \
  CONFIG.PSU__USE__IRQ0 {1} \
  CONFIG.PSU__HIGH_ADDRESS__ENABLE {1}] [get_bd_cells zynq_ultra_ps_e_0]
} else {
  set_property -dict [list CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__USE__S_AXI_GP3 {0} \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__IRQ0 {1} \
  CONFIG.PSU__HIGH_ADDRESS__ENABLE {1}] [get_bd_cells zynq_ultra_ps_e_0]
}

# FPGA Drive Recorder: PS clocks and HP port for the recording datapath
#   pl_clk1 = 250 MHz : dp_clk  (AXI DMA, packetizer, ingest read side, HP2, fdrec registers)
#   pl_clk2 = 200 MHz : src_clk (test pattern generator / user data source, ingest write side)
#   S_AXI_HP2_FPD (128-bit) : AXI DMA S2MM + MM2S + SG masters -> PS DDR (non-coherent)
set_property -dict [list CONFIG.PSU__FPGA_PL1_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ {250} \
  CONFIG.PSU__FPGA_PL2_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL2_REF_CTRL__FREQMHZ {200} \
  CONFIG.PSU__USE__S_AXI_GP4 {1} \
  CONFIG.PSU__SAXIGP4__DATA_WIDTH {128}] [get_bd_cells zynq_ultra_ps_e_0]

# Connect the PS clocks
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]
if {$dual_design} {
  connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins zynq_ultra_ps_e_0/maxihpm1_fpd_aclk]
  connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins zynq_ultra_ps_e_0/saxihp1_fpd_aclk]
}

# Add the DMA/Bridge Subsystem for PCIe IPs
create_bd_cell -type ip -vlnv xilinx.com:ip:xdma xdma_0
if {$dual_design} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:xdma xdma_1
}

# ZCU106 HPC0 has enough MGTs for all 4-lanes for SSD1 and SSD2
# ZCU106 HPC1 has only 1x MGT for SSD1 (cannot support SSD2)
# ZCU104 LPC has only 1x MGT for SSD1
if {[lindex $num_lanes 0] == "X4"} {
  # 4-lane PCIe config
  set max_link_width X4
  set axi_data_width 128_bit
  set axisten_freq 250
  set pf_device_id 9134
} else {
  # 1-lane PCIe config
  set max_link_width X1
  set axi_data_width 64_bit
  set axisten_freq 125
  set pf_device_id 9131
}

# We need to get the correct name format of the PCIe selection
set pcie_blk [get_property CONFIG.pcie_blk_locn [get_bd_cells xdma_0]]
# Find the position of the last underscore
set last_underscore_index [string last "_" $pcie_blk]
# Check if the string contains an underscore
if {$last_underscore_index >= 0} {
    set pcie_blk_locn_0 "[string range $pcie_blk 0 [expr {$last_underscore_index - 1}]]_$pcie_blk_locn_0"
    if {$dual_design} {
      set pcie_blk_locn_1 "[string range $pcie_blk 0 [expr {$last_underscore_index - 1}]]_$pcie_blk_locn_1"
    }
}
# ##########################################################
# Configure DMA/Bridge Subsystem for PCIe IP
# ##########################################################
# Notes:
# (1) The high speed PCIe traces on the FPGA Drive FMC are very
#    short, so there is very low signal loss between the FPGA
#    and the SSD. For this reason, it is best to use the
#    "Chip-to-Chip" loss profile in the "GT Settings" (the
#    default is "Add-on card"). Also, the "Chip-to-Chip"
#    profile is the only one that disables the DFE, a feature
#    that is better suited for longer and more lossy traces.
# (2) Answer record 70854 was important in getting the settings
#    right in this design:
#    https://www.xilinx.com/support/answers/70854.html
# (3) On Zynq Ultrascale+ designs, we have found that at least
#    one BAR had to be assigned in the lower 32-bit address space,
#    or the SSD would not be properly enumerated.
# (4) To further the above point, we have also found that if BAR0
#    is placed at address 0x10_0000_0000 (the default value),
#    the NVMe driver crashes on boot. This occurs even when we
#    enable "High Address" in ZynqMP settings "PS-PL Configuration"->
#    "Address Fragmentation": CONFIG.PSU__HIGH_ADDRESS__ENABLE {1}
#    and even when the SSD's BARs are assigned to the lower 32-bit
#    address space via another BAR (eg. BAR1 @ 0xA0000000).
#    It seems that BAR0 must be assigned in the lower 32-bit
#    address space for this to work, which is in line with the
#    answer record mentioned above (although the images in that
#    document do not align with what is written).
#    
set_property -dict [list CONFIG.functional_mode {AXI_Bridge} \
CONFIG.mode_selection {Advanced} \
CONFIG.device_port_type {Root_Port_of_PCI_Express_Root_Complex} \
CONFIG.pl_link_cap_max_link_width $max_link_width \
CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
CONFIG.axi_addr_width {49} \
CONFIG.axi_data_width $axi_data_width \
CONFIG.axisten_freq $axisten_freq \
CONFIG.dedicate_perst {false} \
CONFIG.sys_reset_polarity {ACTIVE_LOW} \
CONFIG.pf0_device_id $pf_device_id \
CONFIG.pf0_base_class_menu {Bridge_device} \
CONFIG.pf0_class_code_base {06} \
CONFIG.pf0_sub_class_interface_menu {PCI_to_PCI_bridge} \
CONFIG.pf0_class_code_sub {04} \
CONFIG.pf0_class_code_interface {00} \
CONFIG.pf0_class_code {060400} \
CONFIG.xdma_axilite_slave {true} \
CONFIG.pcie_blk_locn $pcie_blk_locn_0 \
CONFIG.en_gt_selection {true} \
CONFIG.select_quad $select_quad_0 \
CONFIG.INS_LOSS_NYQ {5} \
CONFIG.plltype {QPLL1} \
CONFIG.ins_loss_profile {Chip-to-Chip} \
CONFIG.type1_membase_memlimit_enable {Enabled} \
CONFIG.type1_prefetchable_membase_memlimit {64bit_Enabled} \
CONFIG.axibar_num {1} \
CONFIG.axibar2pciebar_0 {0x00000000A0000000} \
CONFIG.BASEADDR {0x00000000} \
CONFIG.HIGHADDR {0x001FFFFF} \
CONFIG.pf0_bar0_enabled {false} \
CONFIG.pf1_class_code {060700} \
CONFIG.pf1_base_class_menu {Bridge_device} \
CONFIG.pf1_class_code_base {06} \
CONFIG.pf1_class_code_sub {07} \
CONFIG.pf1_sub_class_interface_menu {CardBus_bridge} \
CONFIG.pf1_class_code_interface {00} \
CONFIG.pf1_bar2_enabled {false} \
CONFIG.pf1_bar2_64bit {false} \
CONFIG.pf1_bar4_enabled {false} \
CONFIG.pf1_bar4_64bit {false} \
CONFIG.dma_reset_source_sel {Phy_Ready} \
CONFIG.pf0_bar0_type_mqdma {Memory} \
CONFIG.pf1_bar0_type_mqdma {Memory} \
CONFIG.pf2_bar0_type_mqdma {Memory} \
CONFIG.pf3_bar0_type_mqdma {Memory} \
CONFIG.pf0_sriov_bar0_type {Memory} \
CONFIG.pf1_sriov_bar0_type {Memory} \
CONFIG.pf2_sriov_bar0_type {Memory} \
CONFIG.pf3_sriov_bar0_type {Memory} \
CONFIG.PF0_DEVICE_ID_mqdma $pf_device_id \
CONFIG.PF2_DEVICE_ID_mqdma $pf_device_id \
CONFIG.PF3_DEVICE_ID_mqdma $pf_device_id \
CONFIG.pf0_base_class_menu_mqdma {Bridge_device} \
CONFIG.pf0_class_code_base_mqdma {06} \
CONFIG.pf0_class_code_mqdma {068000} \
CONFIG.pf1_base_class_menu_mqdma {Bridge_device} \
CONFIG.pf1_class_code_base_mqdma {06} \
CONFIG.pf1_class_code_mqdma {068000} \
CONFIG.pf2_base_class_menu_mqdma {Bridge_device} \
CONFIG.pf2_class_code_base_mqdma {06} \
CONFIG.pf2_class_code_mqdma {068000} \
CONFIG.pf3_base_class_menu_mqdma {Bridge_device} \
CONFIG.pf3_class_code_base_mqdma {06} \
CONFIG.pf3_class_code_mqdma {068000}] [get_bd_cells xdma_0]

if {$dual_design} {
  # Create xdma_1 and place it at PCIe block X0Y0
  set_property -dict [list CONFIG.functional_mode {AXI_Bridge} \
  CONFIG.mode_selection {Advanced} \
  CONFIG.device_port_type {Root_Port_of_PCI_Express_Root_Complex} \
  CONFIG.pl_link_cap_max_link_width $max_link_width \
  CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
  CONFIG.axi_addr_width {49} \
  CONFIG.axi_data_width $axi_data_width \
  CONFIG.axisten_freq $axisten_freq \
  CONFIG.dedicate_perst {false} \
  CONFIG.sys_reset_polarity {ACTIVE_LOW} \
  CONFIG.pf0_device_id $pf_device_id \
  CONFIG.pf0_base_class_menu {Bridge_device} \
  CONFIG.pf0_class_code_base {06} \
  CONFIG.pf0_sub_class_interface_menu {PCI_to_PCI_bridge} \
  CONFIG.pf0_class_code_sub {04} \
  CONFIG.pf0_class_code_interface {00} \
  CONFIG.pf0_class_code {060400} \
  CONFIG.xdma_axilite_slave {true} \
  CONFIG.pcie_blk_locn $pcie_blk_locn_1 \
  CONFIG.en_gt_selection {true} \
  CONFIG.select_quad $select_quad_1 \
  CONFIG.INS_LOSS_NYQ {5} \
  CONFIG.plltype {QPLL1} \
  CONFIG.ins_loss_profile {Chip-to-Chip} \
  CONFIG.type1_membase_memlimit_enable {Enabled} \
  CONFIG.type1_prefetchable_membase_memlimit {64bit_Enabled} \
  CONFIG.axibar_num {1} \
  CONFIG.axibar2pciebar_0 {0x00000000B0000000} \
  CONFIG.BASEADDR {0x00000000} \
  CONFIG.HIGHADDR {0x001FFFFF} \
  CONFIG.pf0_bar0_enabled {false} \
  CONFIG.pf1_class_code {060700} \
  CONFIG.pf1_base_class_menu {Bridge_device} \
  CONFIG.pf1_class_code_base {06} \
  CONFIG.pf1_class_code_sub {07} \
  CONFIG.pf1_sub_class_interface_menu {CardBus_bridge} \
  CONFIG.pf1_class_code_interface {00} \
  CONFIG.pf1_bar2_enabled {false} \
  CONFIG.pf1_bar2_64bit {false} \
  CONFIG.pf1_bar4_enabled {false} \
  CONFIG.pf1_bar4_64bit {false} \
  CONFIG.dma_reset_source_sel {Phy_Ready} \
  CONFIG.pf0_bar0_type_mqdma {Memory} \
  CONFIG.pf1_bar0_type_mqdma {Memory} \
  CONFIG.pf2_bar0_type_mqdma {Memory} \
  CONFIG.pf3_bar0_type_mqdma {Memory} \
  CONFIG.pf0_sriov_bar0_type {Memory} \
  CONFIG.pf1_sriov_bar0_type {Memory} \
  CONFIG.pf2_sriov_bar0_type {Memory} \
  CONFIG.pf3_sriov_bar0_type {Memory} \
  CONFIG.PF0_DEVICE_ID_mqdma $pf_device_id \
  CONFIG.PF2_DEVICE_ID_mqdma $pf_device_id \
  CONFIG.PF3_DEVICE_ID_mqdma $pf_device_id \
  CONFIG.pf0_base_class_menu_mqdma {Bridge_device} \
  CONFIG.pf0_class_code_base_mqdma {06} \
  CONFIG.pf0_class_code_mqdma {068000} \
  CONFIG.pf1_base_class_menu_mqdma {Bridge_device} \
  CONFIG.pf1_class_code_base_mqdma {06} \
  CONFIG.pf1_class_code_mqdma {068000} \
  CONFIG.pf2_base_class_menu_mqdma {Bridge_device} \
  CONFIG.pf2_class_code_base_mqdma {06} \
  CONFIG.pf2_class_code_mqdma {068000} \
  CONFIG.pf3_base_class_menu_mqdma {Bridge_device} \
  CONFIG.pf3_class_code_base_mqdma {06} \
  CONFIG.pf3_class_code_mqdma {068000}] [get_bd_cells xdma_1]
}

# Answer record 71106: Zynq Ultrascale+ MPSoC - PL PCIe Root Port Bridge (Vivado 2018.1)
# - MSI Interrupt handling causes downstream devices to time out
# https://www.xilinx.com/support/answers/71106.html
set_property -dict [list CONFIG.msi_rx_pin_en {true}] [get_bd_cells xdma_0]
if {$dual_design} {
  set_property -dict [list CONFIG.msi_rx_pin_en {true}] [get_bd_cells xdma_1]
}

# Create AXI Interconnect for the XDMA slave interfaces
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect periph_intercon_0
if {$dual_design} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect periph_intercon_1
}

# Use connection automation after configuration of the PCIe block - so it will assign 512MB to the S_AXI_CTL interfaces
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {/xdma_0/axi_aclk (250 MHz)} Clk_slave {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Clk_xbar {Auto} Master {/xdma_0/M_AXI_B} Slave {/zynq_ultra_ps_e_0/S_AXI_HP0_FPD} intc_ip {New AXI Interconnect} master_apm {0}}  [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Clk_slave {/xdma_0/axi_aclk (250 MHz)} Clk_xbar {Auto} Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} Slave {/xdma_0/S_AXI_B} intc_ip {periph_intercon_0} master_apm {0}}  [get_bd_intf_pins xdma_0/S_AXI_B]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Clk_slave {/xdma_0/axi_aclk (250 MHz)} Clk_xbar {Auto} Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} Slave {/xdma_0/S_AXI_LITE} intc_ip {periph_intercon_0} master_apm {0}}  [get_bd_intf_pins xdma_0/S_AXI_LITE]
if {$dual_design} {
  apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {/xdma_1/axi_aclk (250 MHz)} Clk_slave {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Clk_xbar {Auto} Master {/xdma_1/M_AXI_B} Slave {/zynq_ultra_ps_e_0/S_AXI_HP1_FPD} intc_ip {New AXI Interconnect} master_apm {0}}  [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP1_FPD]
  apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Clk_slave {/xdma_1/axi_aclk (250 MHz)} Clk_xbar {Auto} Master {/zynq_ultra_ps_e_0/M_AXI_HPM1_FPD} Slave {/xdma_1/S_AXI_B} intc_ip {periph_intercon_1} master_apm {0}}  [get_bd_intf_pins xdma_1/S_AXI_B]
  apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Clk_slave {/xdma_1/axi_aclk (250 MHz)} Clk_xbar {Auto} Master {/zynq_ultra_ps_e_0/M_AXI_HPM1_FPD} Slave {/xdma_1/S_AXI_LITE} intc_ip {periph_intercon_1} master_apm {0}}  [get_bd_intf_pins xdma_1/S_AXI_LITE]
}

# Set the BAR0 offsets and sizes
set_property offset 0x00A0000000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_xdma_0_BAR0}]
set_property range 256M [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_xdma_0_BAR0}]
if {$dual_design} {
  set_property offset 0x00B0000000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_xdma_1_BAR0}]
  set_property range 256M [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_xdma_1_BAR0}]
}

# Add MGT external port for PCIe (SSD1)
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pci_exp_0
connect_bd_intf_net [get_bd_intf_pins xdma_0/pcie_mgt] [get_bd_intf_ports pci_exp_0]

# Add MGT external port for PCIe (SSD2)
if {$dual_design} {
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pci_exp_1
  connect_bd_intf_net [get_bd_intf_pins xdma_1/pcie_mgt] [get_bd_intf_ports pci_exp_1]
}

# Add differential buffer for the 100MHz PCIe reference clock (SSD1)
create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf ref_clk_0_buf
set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDSGTE}] [get_bd_cells ref_clk_0_buf]
# sys_clk and sys_clk_gt connected as per DMA/Bridge Subsystem for PCIe Product guide PG195
# https://www.xilinx.com/support/documentation/ip_documentation/xdma/v2_0/pg195-pcie-dma.pdf
connect_bd_net [get_bd_pins ref_clk_0_buf/IBUF_DS_ODIV2] [get_bd_pins xdma_0/sys_clk]
connect_bd_net [get_bd_pins ref_clk_0_buf/IBUF_OUT] [get_bd_pins xdma_0/sys_clk_gt]
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 ref_clk_0
connect_bd_intf_net [get_bd_intf_pins ref_clk_0_buf/CLK_IN_D] [get_bd_intf_ports ref_clk_0]

# Add differential buffer for the 100MHz PCIe reference clock (SSD2)
if {$dual_design} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf ref_clk_1_buf
  set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDSGTE}] [get_bd_cells ref_clk_1_buf]
  # sys_clk and sys_clk_gt connected as per DMA/Bridge Subsystem for PCIe Product guide PG195
  # https://www.xilinx.com/support/documentation/ip_documentation/xdma/v2_0/pg195-pcie-dma.pdf
  connect_bd_net [get_bd_pins ref_clk_1_buf/IBUF_DS_ODIV2] [get_bd_pins xdma_1/sys_clk]
  connect_bd_net [get_bd_pins ref_clk_1_buf/IBUF_OUT] [get_bd_pins xdma_1/sys_clk_gt]
  create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 ref_clk_1
  connect_bd_intf_net [get_bd_intf_pins ref_clk_1_buf/CLK_IN_D] [get_bd_intf_ports ref_clk_1]
}

# Create concat for the interrupts and connect them
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_interrupts
connect_bd_net [get_bd_pins concat_interrupts/dout] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]
if {$dual_design} {
  set_property -dict [list CONFIG.NUM_PORTS {6}] [get_bd_cells concat_interrupts]
  connect_bd_net [get_bd_pins xdma_0/interrupt_out] [get_bd_pins concat_interrupts/In0]
  connect_bd_net [get_bd_pins xdma_1/interrupt_out] [get_bd_pins concat_interrupts/In1]
  connect_bd_net [get_bd_pins xdma_0/interrupt_out_msi_vec0to31] [get_bd_pins concat_interrupts/In2]
  connect_bd_net [get_bd_pins xdma_0/interrupt_out_msi_vec32to63] [get_bd_pins concat_interrupts/In3]
  connect_bd_net [get_bd_pins xdma_1/interrupt_out_msi_vec0to31] [get_bd_pins concat_interrupts/In4]
  connect_bd_net [get_bd_pins xdma_1/interrupt_out_msi_vec32to63] [get_bd_pins concat_interrupts/In5]
} else {
  set_property -dict [list CONFIG.NUM_PORTS {3}] [get_bd_cells concat_interrupts]
  connect_bd_net [get_bd_pins xdma_0/interrupt_out] [get_bd_pins concat_interrupts/In0]
  connect_bd_net [get_bd_pins xdma_0/interrupt_out_msi_vec0to31] [get_bd_pins concat_interrupts/In1]
  connect_bd_net [get_bd_pins xdma_0/interrupt_out_msi_vec32to63] [get_bd_pins concat_interrupts/In2]
}

# Add proc system reset for xdma_0/axi_ctl_aresetn
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pcie_0_axi_aclk
connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_pins rst_pcie_0_axi_aclk/slowest_sync_clk]
connect_bd_net [get_bd_pins xdma_0/axi_ctl_aresetn] [get_bd_pins rst_pcie_0_axi_aclk/ext_reset_in]
disconnect_bd_net /xdma_0_axi_aresetn [get_bd_pins periph_intercon_0/M01_ARESETN]
connect_bd_net [get_bd_pins xdma_0/axi_ctl_aresetn] [get_bd_pins periph_intercon_0/M01_ARESETN]

# Add proc system reset for xdma_1/axi_ctl_aresetn
if {$dual_design} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pcie_1_axi_aclk
  connect_bd_net [get_bd_pins xdma_1/axi_aclk] [get_bd_pins rst_pcie_1_axi_aclk/slowest_sync_clk]
  connect_bd_net [get_bd_pins xdma_1/axi_ctl_aresetn] [get_bd_pins rst_pcie_1_axi_aclk/ext_reset_in]
  disconnect_bd_net /xdma_1_axi_aresetn [get_bd_pins periph_intercon_1/M01_ARESETN]
  connect_bd_net [get_bd_pins xdma_1/axi_ctl_aresetn] [get_bd_pins periph_intercon_1/M01_ARESETN]
}

# Create PERST ports
create_bd_port -dir O -from 0 -to 0 -type rst perst_0
connect_bd_net [get_bd_pins /rst_pcie_0_axi_aclk/peripheral_reset] [get_bd_ports perst_0]
if {$dual_design} {
  create_bd_port -dir O -from 0 -to 0 -type rst perst_1
  connect_bd_net [get_bd_pins /rst_pcie_1_axi_aclk/peripheral_reset] [get_bd_ports perst_1]
}

# Connect AXI PCIe reset
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins xdma_0/sys_rst_n]
if {$dual_design} {
  connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins xdma_1/sys_rst_n]
}

# Constant to enable/disable 3.3V power supply of SSD2 and clock source
set const_dis_ssd2_pwr [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_dis_ssd2_pwr ]
create_bd_port -dir O disable_ssd2_pwr
connect_bd_net [get_bd_pins const_dis_ssd2_pwr/dout] [get_bd_ports disable_ssd2_pwr]
if {$dual_design} {
  # LOW to enable SSD2
  set_property -dict [list CONFIG.CONST_VAL {0}] $const_dis_ssd2_pwr
} else {
  # HIGH to disable SSD2
  set_property -dict [list CONFIG.CONST_VAL {1}] $const_dis_ssd2_pwr
}

# ##########################################################
# FPGA Drive Recorder datapath
# ##########################################################
#
#  user_data_source (src_clk)          fdrec_core                    dp_clk
#  [fdrec_tpg] --AXIS 128b--> [ingest FIFO -> packetizer] --AXIS--> axi_dma_0 S2MM
#                                  ^ AXI-Lite regs                    | M_AXI_S2MM + M_AXI_SG
#                                  |                                  v
#  M_AXI_HPM0_FPD -> periph_intercon_0 -+-> fdrec_core/S_AXI     axi_smc_dma -> S_AXI_HP2_FPD
#                                       +-> axi_dma_0/S_AXI_LITE
#
# Playback (register map 1.1):
#
#  axi_dma_0 MM2S --AXIS 128b (dp_clk)--> fdrec_core [egress FIFO] --AXIS (src_clk)-->
#  user_data_sink [fdrec_check]   (M_AXI_MM2S -> axi_smc_dma -> S_AXI_HP2_FPD)
#
# The user_data_source / user_data_sink hierarchies are the documented
# insertion points for a customer's own data source / sink (see
# docs/source/custom_source.md).

# Actual PL clock frequencies (the PS PLLs may not hit the requested values exactly)
set dp_clk_hz  [expr {int(round([get_property CONFIG.FREQ_HZ [get_bd_pins zynq_ultra_ps_e_0/pl_clk1]]))}]
set src_clk_hz [expr {int(round([get_property CONFIG.FREQ_HZ [get_bd_pins zynq_ultra_ps_e_0/pl_clk2]]))}]
puts "INFO: fdrec dp_clk (pl_clk1) = $dp_clk_hz Hz, src_clk (pl_clk2) = $src_clk_hz Hz"

# Resets for the two new clock domains
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_dp_clk
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk1] [get_bd_pins rst_dp_clk/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_dp_clk/ext_reset_in]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_src_clk
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] [get_bd_pins rst_src_clk/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_src_clk/ext_reset_in]

# user_data_source hierarchy: the test pattern generator
create_bd_cell -type hier user_data_source
create_bd_pin -dir I -type clk user_data_source/src_clk
create_bd_pin -dir I -type rst user_data_source/src_resetn
create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 user_data_source/M_AXIS
create_bd_pin -dir I user_data_source/tpg_enable
create_bd_pin -dir I user_data_source/tpg_seq_rst
create_bd_pin -dir I -from 31 -to 0 user_data_source/tpg_rate_inc
create_bd_pin -dir O -from 63 -to 0 user_data_source/tpg_seq_next
create_bd_cell -type module -reference fdrec_tpg user_data_source/fdrec_tpg_0
connect_bd_net [get_bd_pins user_data_source/src_clk] [get_bd_pins user_data_source/fdrec_tpg_0/src_clk]
connect_bd_net [get_bd_pins user_data_source/src_resetn] [get_bd_pins user_data_source/fdrec_tpg_0/src_resetn]
connect_bd_net [get_bd_pins user_data_source/tpg_enable] [get_bd_pins user_data_source/fdrec_tpg_0/tpg_enable]
connect_bd_net [get_bd_pins user_data_source/tpg_seq_rst] [get_bd_pins user_data_source/fdrec_tpg_0/tpg_seq_rst]
connect_bd_net [get_bd_pins user_data_source/tpg_rate_inc] [get_bd_pins user_data_source/fdrec_tpg_0/tpg_rate_inc]
connect_bd_net [get_bd_pins user_data_source/tpg_seq_next] [get_bd_pins user_data_source/fdrec_tpg_0/tpg_seq_next]
connect_bd_intf_net [get_bd_intf_pins user_data_source/M_AXIS] [get_bd_intf_pins user_data_source/fdrec_tpg_0/m_axis]

# user_data_sink hierarchy: the playback checker
create_bd_cell -type hier user_data_sink
create_bd_pin -dir I -type clk user_data_sink/snk_clk
create_bd_pin -dir I -type rst user_data_sink/snk_resetn
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 user_data_sink/S_AXIS
create_bd_pin -dir I user_data_sink/chk_enable
create_bd_pin -dir I user_data_sink/chk_reset
create_bd_pin -dir I -from 31 -to 0 user_data_sink/chk_rate_inc
set chk_counters {chk_beats chk_errors chk_gaps chk_gap_beats chk_underflows chk_last_seq}
foreach p $chk_counters {
  create_bd_pin -dir O -from 63 -to 0 user_data_sink/$p
}
create_bd_cell -type module -reference fdrec_check user_data_sink/fdrec_check_0
foreach p [concat {snk_clk snk_resetn chk_enable chk_reset chk_rate_inc} $chk_counters] {
  connect_bd_net [get_bd_pins user_data_sink/$p] [get_bd_pins user_data_sink/fdrec_check_0/$p]
}
connect_bd_intf_net [get_bd_intf_pins user_data_sink/S_AXIS] [get_bd_intf_pins user_data_sink/fdrec_check_0/s_axis]

# fdrec_core hierarchy: ingest FIFO + packetizer + egress FIFO + AXI-Lite register block
create_bd_cell -type hier fdrec_core
create_bd_pin -dir I -type clk fdrec_core/src_clk
create_bd_pin -dir I -type rst fdrec_core/src_resetn
create_bd_pin -dir I -type clk fdrec_core/dp_clk
create_bd_pin -dir I -type rst fdrec_core/dp_resetn
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 fdrec_core/S_AXIS
create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 fdrec_core/M_AXIS
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 fdrec_core/S_AXI
create_bd_pin -dir O fdrec_core/tpg_enable
create_bd_pin -dir O fdrec_core/tpg_seq_rst
create_bd_pin -dir O -from 31 -to 0 fdrec_core/tpg_rate_inc
create_bd_pin -dir I -from 63 -to 0 fdrec_core/tpg_seq_next
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 fdrec_core/S_AXIS_MM2S
create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 fdrec_core/M_AXIS_SNK
create_bd_pin -dir O fdrec_core/chk_enable
create_bd_pin -dir O fdrec_core/chk_reset
create_bd_pin -dir O -from 31 -to 0 fdrec_core/chk_rate_inc
foreach p $chk_counters {
  create_bd_pin -dir I -from 63 -to 0 fdrec_core/$p
}
create_bd_cell -type module -reference fdrec_core fdrec_core/fdrec_core_0
set_property -dict [list CONFIG.SRC_CLK_HZ $src_clk_hz \
  CONFIG.DP_CLK_HZ $dp_clk_hz \
  CONFIG.FIFO_DEPTH {4096} \
  CONFIG.EGR_FIFO_DEPTH {4096}] [get_bd_cells fdrec_core/fdrec_core_0]
foreach p [concat {src_clk src_resetn dp_clk dp_resetn tpg_enable tpg_seq_rst tpg_rate_inc tpg_seq_next \
                   chk_enable chk_reset chk_rate_inc} $chk_counters] {
  connect_bd_net [get_bd_pins fdrec_core/$p] [get_bd_pins fdrec_core/fdrec_core_0/$p]
}
connect_bd_intf_net [get_bd_intf_pins fdrec_core/S_AXIS] [get_bd_intf_pins fdrec_core/fdrec_core_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/M_AXIS] [get_bd_intf_pins fdrec_core/fdrec_core_0/m_axis]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/S_AXI] [get_bd_intf_pins fdrec_core/fdrec_core_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/S_AXIS_MM2S] [get_bd_intf_pins fdrec_core/fdrec_core_0/s_axis_mm2s]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/M_AXIS_SNK] [get_bd_intf_pins fdrec_core/fdrec_core_0/m_axis_snk]

# Source -> core, and the TPG control/status signals
connect_bd_intf_net [get_bd_intf_pins user_data_source/M_AXIS] [get_bd_intf_pins fdrec_core/S_AXIS]
foreach p {tpg_enable tpg_seq_rst tpg_rate_inc tpg_seq_next} {
  connect_bd_net [get_bd_pins fdrec_core/$p] [get_bd_pins user_data_source/$p]
}

# Core -> sink, and the checker control/status signals
connect_bd_intf_net [get_bd_intf_pins fdrec_core/M_AXIS_SNK] [get_bd_intf_pins user_data_sink/S_AXIS]
foreach p [concat {chk_enable chk_reset chk_rate_inc} $chk_counters] {
  connect_bd_net [get_bd_pins fdrec_core/$p] [get_bd_pins user_data_sink/$p]
}

# AXI DMA: scatter-gather, S2MM (record) + MM2S (playback), 128-bit stream and
# memory map, burst 256, 26-bit buffer length register, 64-bit addressing (PS
# DDR above 4 GB boundary is at 0x8_0000_0000), no DRE
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_0
set_property -dict [list CONFIG.c_include_sg {1} \
  CONFIG.c_include_mm2s {1} \
  CONFIG.c_m_axi_mm2s_data_width {128} \
  CONFIG.c_m_axis_mm2s_tdata_width {128} \
  CONFIG.c_mm2s_burst_size {256} \
  CONFIG.c_include_mm2s_dre {0} \
  CONFIG.c_include_s2mm {1} \
  CONFIG.c_micro_dma {0} \
  CONFIG.c_sg_length_width {26} \
  CONFIG.c_sg_include_stscntrl_strm {0} \
  CONFIG.c_addr_width {64} \
  CONFIG.c_s_axis_s2mm_tdata_width {128} \
  CONFIG.c_m_axi_s2mm_data_width {128} \
  CONFIG.c_s2mm_burst_size {256} \
  CONFIG.c_include_s2mm_dre {0}] [get_bd_cells axi_dma_0]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/M_AXIS] [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_pins fdrec_core/S_AXIS_MM2S]

# DMA masters -> SmartConnect -> S_AXI_HP2_FPD
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc_dma
set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {1}] [get_bd_cells axi_smc_dma]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_SG] [get_bd_intf_pins axi_smc_dma/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins axi_smc_dma/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins axi_smc_dma/S02_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc_dma/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP2_FPD]

# AXI-Lite: fdrec registers and DMA control on the existing PS master interconnect
set n_mi [get_property CONFIG.NUM_MI [get_bd_cells periph_intercon_0]]
set mi_regs [format "M%02d" $n_mi]
set mi_dma  [format "M%02d" [expr {$n_mi + 1}]]
set_property CONFIG.NUM_MI [expr {$n_mi + 2}] [get_bd_cells periph_intercon_0]
connect_bd_intf_net [get_bd_intf_pins periph_intercon_0/${mi_regs}_AXI] [get_bd_intf_pins fdrec_core/S_AXI]
connect_bd_intf_net [get_bd_intf_pins periph_intercon_0/${mi_dma}_AXI] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# dp_clk domain clocks and resets
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk1] \
  [get_bd_pins zynq_ultra_ps_e_0/saxihp2_fpd_aclk] \
  [get_bd_pins axi_smc_dma/aclk] \
  [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
  [get_bd_pins axi_dma_0/m_axi_sg_aclk] \
  [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
  [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
  [get_bd_pins fdrec_core/dp_clk] \
  [get_bd_pins periph_intercon_0/${mi_regs}_ACLK] \
  [get_bd_pins periph_intercon_0/${mi_dma}_ACLK]
connect_bd_net [get_bd_pins rst_dp_clk/peripheral_aresetn] \
  [get_bd_pins axi_dma_0/axi_resetn] \
  [get_bd_pins fdrec_core/dp_resetn] \
  [get_bd_pins periph_intercon_0/${mi_regs}_ARESETN] \
  [get_bd_pins periph_intercon_0/${mi_dma}_ARESETN]
connect_bd_net [get_bd_pins rst_dp_clk/interconnect_aresetn] [get_bd_pins axi_smc_dma/aresetn]

# src_clk domain clocks and resets
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] \
  [get_bd_pins user_data_source/src_clk] \
  [get_bd_pins user_data_sink/snk_clk] \
  [get_bd_pins fdrec_core/src_clk]
connect_bd_net [get_bd_pins rst_src_clk/peripheral_aresetn] \
  [get_bd_pins user_data_source/src_resetn] \
  [get_bd_pins user_data_sink/snk_resetn] \
  [get_bd_pins fdrec_core/src_resetn]

# DMA S2MM interrupt: appended to the PL-PS interrupt concat (XDMA inputs keep
# their positions)
set n_irq [get_property CONFIG.NUM_PORTS [get_bd_cells concat_interrupts]]
set_property CONFIG.NUM_PORTS [expr {$n_irq + 1}] [get_bd_cells concat_interrupts]
connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] [get_bd_pins concat_interrupts/In${n_irq}]
puts "INFO: fdrec axi_dma_0/s2mm_introut -> pl_ps_irq0\[$n_irq\]"

# DMA MM2S interrupt: next input (pl_ps_irq0[n] = GIC SPI 89 + n)
set n_irq [get_property CONFIG.NUM_PORTS [get_bd_cells concat_interrupts]]
set_property CONFIG.NUM_PORTS [expr {$n_irq + 1}] [get_bd_cells concat_interrupts]
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins concat_interrupts/In${n_irq}]
puts "INFO: fdrec axi_dma_0/mm2s_introut -> pl_ps_irq0\[$n_irq\] (GIC SPI [expr {89 + $n_irq}])"

# Address map: assign everything still unassigned (fdrec registers, DMA
# control, and the DMA's view of PS DDR through HP2)
assign_bd_address
# Pin the recorder's AXI-Lite slaves to their Phase-1 addresses (the driver's
# device tree and the docs rely on them)
set_property offset 0x0420000000 [get_bd_addr_segs zynq_ultra_ps_e_0/Data/SEG_axi_dma_0_Reg]
set_property offset 0x0420010000 [get_bd_addr_segs zynq_ultra_ps_e_0/Data/SEG_fdrec_core_0_reg0]
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]] {
  puts "INFO: addr [get_property NAME $seg] offset [get_property OFFSET $seg] range [get_property RANGE $seg]"
}
foreach as {Data_SG Data_S2MM Data_MM2S} {
  foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces axi_dma_0/$as]] {
    puts "INFO: addr axi_dma_0/$as [get_property NAME $seg] offset [get_property OFFSET $seg] range [get_property RANGE $seg]"
  }
}

validate_bd_design

# Restore current instance
current_bd_instance $oldCurInst

save_bd_design
