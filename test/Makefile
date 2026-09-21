.PHONY: all rtl host lint clean

all: rtl host lint

rtl:
	python3 run_rtl_tests.py

host:
	python3 -m unittest -v test_host.py

lint:
	iverilog -g2012 -Wall -s tt_um_romd_uart_loader -o build/lint.vvp \
		../src/uart.v ../src/uart_loader.v ../src/spi_sram.v ../src/project.v

clean:
	rm -rf build __pycache__
