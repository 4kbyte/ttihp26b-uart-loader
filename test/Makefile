.PHONY: all rtl host lint clean

ifeq ($(GATES),yes)

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

COMPILE_ARGS += -DGL_TEST
COMPILE_ARGS += -DFUNCTIONAL
COMPILE_ARGS += -DSIM
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13g2/libs.ref/sg13g2_io/verilog/sg13g2_io.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog/sg13g2_stdcell.v
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb
COCOTB_TEST_MODULES = test_gate

all: sim

include $(shell cocotb-config --makefiles)/Makefile.sim

else

all: rtl host lint

rtl:
	python3 run_rtl_tests.py

host:
	python3 -m unittest -v test_host.py

lint:
	iverilog -g2012 -Wall -s tt_um_romd_uart_loader -o build/lint.vvp \
		../src/uart.v ../src/uart_loader.v ../src/spi_sram.v ../src/project.v

clean:
	rm -rf build sim_build __pycache__ results.xml tb.vcd tb.fst

endif
