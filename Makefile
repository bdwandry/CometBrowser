SDK = $(shell egrep '^\s*SDKRoot' ~/.Playdate/config 2>/dev/null | head -n 1 | cut -c9-)
ifeq ($(SDK),)
SDK = /Users/bwandrych/Developer/PlaydateSDK
endif

PDC = $(SDK)/bin/pdc
SIM = $(SDK)/bin/Playdate\ Simulator.app

PROJECT = CometBrowser
SOURCE_DIR = Source
OUTPUT_PDX = $(PROJECT).pdx

all: build

build:
	@echo "Compiling $(PROJECT)..."
	$(PDC) $(SOURCE_DIR) $(OUTPUT_PDX)
	@echo "Build successful: $(OUTPUT_PDX)"

sim: build
	@echo "Launching in Playdate Simulator..."
	open -a $(SIM) $(OUTPUT_PDX)

clean:
	@echo "Cleaning build artifacts..."
	rm -rf $(OUTPUT_PDX)

.PHONY: all build sim clean
