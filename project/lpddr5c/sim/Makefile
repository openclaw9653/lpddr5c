#============================================================================
# Makefile for LPDDR5 Controller Simulation
#============================================================================

#========================================================================
# Tool Configuration
#========================================================================
SIMULATOR ?= vcs  # or xcelium, questa, verilator
WAVES ?= 1

#========================================================================
# Directories
#========================================================================
PROJ_DIR       := $(shell pwd)
RTL_DIR        := $(PROJ_DIR)/rtl
TB_DIR         := $(PROJ_DIR)/testbench
SIM_DIR        := $(PROJ_DIR)/sim
WAVE_DIR       := $(SIM_DIR)/waves
LOG_DIR        := $(SIM_DIR)/logs

#========================================================================
# RTL File List
#========================================================================
RTL_FILES := \
    $(RTL_DIR)/lpddr5c_top.sv \
    $(RTL_DIR)/lpddr5c_cmd_scheduler.sv \
    $(RTL_DIR)/lpddr5c_data_path.sv \
    $(RTL_DIR)/lpddr5c_reg_cfg.sv \
    $(RTL_DIR)/lpddr5c_refresh_ctrl.sv \
    $(RTL_DIR)/lpddr5c_training_ctrl.sv \
    $(RTL_DIR)/lpddr5c_lp_mgmt.sv \
    $(RTL_DIR)/lpddr5c_dfi_if.sv

TB_FILES := \
    $(TB_DIR)/tb_lpddr5c_top.sv

ALL_FILES := $(RTL_FILES) $(TB_FILES)

#========================================================================
# VCS Configuration
#========================================================================
VCS := vcs
VCS_FLAGS := \
    -full64 \
    -sv \
    -sverilog \
    -debug_all \
    +incdir+$(RTL_DIR) \
    +incdir+$(TB_DIR) \
    +lint=all,noVCDE,noSVA \
    -timescale=1ns/1ps \
    -o $(SIM_DIR)/simv

ifeq ($(WAVES),1)
VCS_FLAGS += +define+DUMP_WAVES
endif

#========================================================================
# Xcelium (Cadence) Configuration
#========================================================================
XCELIUM := xrun
XCELIUM_FLAGS := \
    -64bit \
    -sv \
    -clean \
    -timescale 1ns/1ps \
    -incdir $(RTL_DIR) \
    -incdir $(TB_DIR) \
    -log $(LOG_DIR)/xcelium.log

#========================================================================
# Verilator Configuration (Open Source)
#========================================================================
VERILATOR := verilator
VERILATOR_FLAGS := \
    --sv \
    --cc \
    --exe \
    --trace \
    -I$(RTL_DIR) \
    -I$(TB_DIR) \
    --top-module tb_lpddr5c_top \
    -o $(SIM_DIR)/simv_verilator

#========================================================================
# Targets
#========================================================================
.PHONY: all help clean vcs xcelium verilator waves comp elab sim

all: help

help:
	@echo "LPDDR5 Controller Simulation Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  make vcs         - Compile & simulate with VCS"
	@echo "  make xcelium     - Compile & simulate with Xcelium"
	@echo "  make verilator   - Compile & simulate with Verilator"
	@echo "  make comp        - Compile only (no simulation)"
	@echo "  make sim         - Run simulation only"
	@echo "  make waves       - View waveforms"
	@echo "  make clean       - Clean simulation files"
	@echo ""
	@echo "Options:"
	@echo "  SIMULATOR=vcs|xcelium|verilator  - Select simulator"
	@echo "  WAVES=0|1                         - Enable/disable waveform dump"

#========================================================================
# Create Directories
#========================================================================
$(SIM_DIR) $(WAVE_DIR) $(LOG_DIR):
	mkdir -p $@

#========================================================================
# VCS Flow
#========================================================================
vcs: $(SIM_DIR) $(WAVE_DIR) $(LOG_DIR)
	@echo "========================================"
	@echo "Compiling with VCS..."
	@echo "========================================"
	cd $(SIM_DIR) && $(VCS) $(VCS_FLAGS) $(ALL_FILES)
	@echo ""
	@echo "========================================"
	@echo "Running simulation..."
	@echo "========================================"
	cd $(SIM_DIR) && ./simv +vcs+finish+100000 \
		-l $(LOG_DIR)/sim.log
	@echo ""
	@echo "========================================"
	@echo "Simulation complete!"
	@echo "Log: $(LOG_DIR)/sim.log"
	@echo "========================================"

#========================================================================
# Xcelium Flow
#========================================================================
xcelium: $(SIM_DIR) $(WAVE_DIR) $(LOG_DIR)
	@echo "========================================"
	@echo "Simulating with Xcelium..."
	@echo "========================================"
	cd $(SIM_DIR) && $(XCELIUM) $(XCELIUM_FLAGS) $(ALL_FILES)
	@echo ""
	@echo "========================================"
	@echo "Simulation complete!"
	@echo "Log: $(LOG_DIR)/xcelium.log"
	@echo "========================================"

#========================================================================
# Verilator Flow
#========================================================================
verilator: $(SIM_DIR) $(WAVE_DIR) $(LOG_DIR)
	@echo "========================================"
	@echo "Compiling with Verilator..."
	@echo "========================================"
	$(VERILATOR) $(VERILATOR_FLAGS) $(ALL_FILES) -Mdir $(SIM_DIR)/obj_dir
	@echo ""
	@echo "Building..."
	make -C $(SIM_DIR)/obj_dir -f Vtb_lpddr5c_top.mk
	@echo ""
	@echo "========================================"
	@echo "Running simulation..."
	@echo "========================================"
	$(SIM_DIR)/obj_dir/Vtb_lpddr5c_top
	@echo ""
	@echo "========================================"
	@echo "Simulation complete!"
	@echo "========================================"

#========================================================================
# Compile Only
#========================================================================
comp: $(SIM_DIR)
	@echo "========================================"
	@echo "Compiling only..."
	@echo "========================================"
ifeq ($(SIMULATOR),vcs)
	cd $(SIM_DIR) && $(VCS) $(VCS_FLAGS) -Mupdate $(ALL_FILES)
else ifeq ($(SIMULATOR),xcelium)
	cd $(SIM_DIR) && $(XCELIUM) $(XCELIUM_FLAGS) -compile $(ALL_FILES)
else ifeq ($(SIMULATOR),verilator)
	$(VERILATOR) $(VERILATOR_FLAGS) $(ALL_FILES) -Mdir $(SIM_DIR)/obj_dir
else
	@echo "Unknown simulator: $(SIMULATOR)"
	@echo "Use SIMULATOR=vcs|xcelium|verilator"
	@exit 1
endif
	@echo "Compile complete!"

#========================================================================
# Simulate Only
#========================================================================
sim: $(SIM_DIR)
	@echo "========================================"
	@echo "Running simulation..."
	@echo "========================================"
ifeq ($(SIMULATOR),vcs)
	cd $(SIM_DIR) && ./simv -l $(LOG_DIR)/sim.log
else ifeq ($(SIMULATOR),xcelium)
	cd $(SIM_DIR) && $(XCELIUM) $(XCELIUM_FLAGS) -R
else ifeq ($(SIMULATOR),verilator)
	$(SIM_DIR)/obj_dir/Vtb_lpddr5c_top
else
	@echo "Unknown simulator: $(SIMULATOR)"
	@exit 1
endif
	@echo "Simulation complete!"

#========================================================================
# View Waveforms
#========================================================================
waves: $(WAVE_DIR)
	@echo "Opening waveforms..."
ifeq ($(SIMULATOR),vcs)
	verdi -ssf $(WAVE_DIR)/tb_lpddr5c_top.vcd &
else ifeq ($(SIMULATOR),xcelium)
	simvision &
else ifeq ($(SIMULATOR),verilator)
	gtkwave $(WAVE_DIR)/tb_lpddr5c_top.vcd &
else
	@echo "Open waveform file manually: $(WAVE_DIR)/tb_lpddr5c_top.vcd"
endif

#========================================================================
# Clean
#========================================================================
clean:
	@echo "Cleaning simulation files..."
	rm -rf $(SIM_DIR)/simv*
	rm -rf $(SIM_DIR)/csrc
	rm -rf $(SIM_DIR)/DVEfiles
	rm -rf $(SIM_DIR)/obj_dir
	rm -rf $(SIM_DIR)/*.daidir
	rm -rf $(SIM_DIR)/*.vpd
	rm -rf $(SIM_DIR)/*.fsdb
	rm -rf $(WAVE_DIR)/*.vcd
	rm -rf $(LOG_DIR)/*.log
	rm -rf $(SIM_DIR)/vc_hdrs.h
	rm -rf $(SIM_DIR)/ucli.key
	@echo "Clean complete!"

#========================================================================
# Distclean (aggressive clean)
#========================================================================
distclean: clean
	@echo "Distcleaning..."
	rm -rf $(SIM_DIR)/*
	@echo "Distclean complete!"
