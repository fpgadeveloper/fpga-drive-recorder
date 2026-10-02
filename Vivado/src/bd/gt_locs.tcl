
# Opsero Electronic Design Inc. Copyright 2024

# GT LOC constraints are required in the configuration of the PCIe IPs.
# The following code constructs a nested dictionary that contains the GT assignments for
# each target board for FPGA Drive FMC Gen4.

# To use the dictionary:
#   * Get the GT quad:    dict get $gt_loc_dict <target> <ssd index> quad
#   * Get the PCIe LOC:   dict get $gt_loc_dict <target> <ssd index> pcie
dict set gt_loc_dict uzev 0 quad GTH_Quad_225
dict set gt_loc_dict uzev 0 pcie X0Y1
dict set gt_loc_dict uzev 1 quad GTH_Quad_224
dict set gt_loc_dict uzev 1 pcie X0Y0
dict set gt_loc_dict vck190_fmcp1 0 quad GTY_Quad_201
dict set gt_loc_dict vck190_fmcp1 0 pcie X1Y0
dict set gt_loc_dict vck190_fmcp1 1 quad GTY_Quad_202
dict set gt_loc_dict vck190_fmcp1 1 pcie X1Y2
