SHELL := /bin/bash
.DELETE_ON_ERROR:
.SHELLFLAGS := -eu -o pipefail -c
PREFIX ?= $(CURDIR)/work/toolchain
YOSYS ?= $(PREFIX)/bin/yosys
NEXTPNR ?= $(PREFIX)/bin/nextpnr-ice40
ICEPACK ?= $(PREFIX)/bin/icepack
RTL := rtl/uart.v rtl/i2c_register.v rtl/capture.v rtl/frame_ram.v rtl/camera_core.v rtl/top.v
CXXRTL_INCLUDE ?= $(PREFIX)/share/yosys/include/backends/cxxrtl/runtime

.PHONY: all test toolchain test-host
all: build/camera.bin

toolchain:
	PREFIX="$(PREFIX)" bash scripts/build-toolchain.sh

test-host:
	python3 -m unittest discover -s tests -p 'test_*.py' -v

build:
	mkdir -p build

build/camera.json: $(RTL) Makefile | build
	$(YOSYS) -ql build/synth.log -p 'read_verilog -sv $(RTL); synth_ice40 -device u -top top -json $@; check -assert'

build/camera.asc: build/camera.json constraints/camera.pcf
	$(NEXTPNR) --up5k --package sg48 --json $< --pcf constraints/camera.pcf --asc $@ --freq 48 --report build/timing.json --detailed-timing-report --seed 1 --opt-timing > build/pnr.log 2>&1

build/camera.bin: build/camera.asc
	$(ICEPACK) $< $@

build/capture.cc: rtl/capture.v Makefile | build
	$(YOSYS) -Qq -p 'read_verilog -sv $<; chparam -set WIDTH 16 -set HEIGHT 4 -set CAPACITY 256 -set TIMEOUT 10000 capture; hierarchy -top capture; write_cxxrtl $@'

build/i2c_register.cc: rtl/i2c_register.v Makefile | build
	$(YOSYS) -Qq -p 'read_verilog -sv $<; chparam -set QUARTER 8 -set TIMEOUT 20000 i2c_register; hierarchy -top i2c_register; write_cxxrtl $@'

build/core.cc: $(RTL) Makefile | build
	$(YOSYS) -Qq -p 'read_verilog -D CXXRTL -sv $(filter-out rtl/top.v,$(RTL)); chparam -set UART_DIV 16 -set I2C_QUARTER 8 -set CAP_TIMEOUT 3000000 camera_core; hierarchy -top camera_core; write_cxxrtl $@'

build/test_capture: tests/test_capture.cc build/capture.cc
	$(CXX) -std=c++17 -O2 -Wall -Wextra -Ibuild -I$(CXXRTL_INCLUDE) $< -o $@

build/test_i2c: tests/test_i2c.cc build/i2c_register.cc
	$(CXX) -std=c++17 -O2 -Wall -Wextra -Ibuild -I$(CXXRTL_INCLUDE) $< -o $@

build/test_core: tests/test_core.cc build/core.cc
	$(CXX) -std=c++17 -O2 -Wall -Wextra -Ibuild -I$(CXXRTL_INCLUDE) $< -o $@

test: build/test_capture build/test_i2c build/test_core
	./build/test_capture
	./build/test_i2c
	./build/test_core
	python3 -m unittest discover -s tests -p 'test_*.py' -v
