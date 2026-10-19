# DEADBALL Playdate client (Lua + C extension)
#   make            Simulator build: compile the C extension (clang) + pdc → build/deadball.pdx
#   make device     Device build: compile the C extension (arm-none-eabi-gcc) + pdc
#                   (DEV_FIXTURES=0 also leaves out source/fixtures_dev)
#   make universal  both pdex.dylib and pdex.elf in one .pdx
#   make lua        pdc-only build (no C; BallCast falls back to static backgrounds)
#   make run        build and open in the Simulator
#   make deploy     device build + install on a USB Playdate (tools/device.sh)
#   make tour       build, run the shell's screenshot tour headlessly, write PNGs to docs/screens/
#   make fixtures   regenerate the shell's dev fixtures (source/fixtures_dev/*.json)
#   make fonts      regenerate the Navigator UI fonts from the SDK's Nontendo fonts
#   make clean-data forget the Simulator's saved token/settings (fresh first run)
#   make clean      remove build products (also source/pdex.*)
#
# C sources live in c/ (BallCast 3D renderer, owned by the ballcast agent; pdsim*.c: the Pennant
# game engine, docs/PENNANT_ENGINE.md, host tests in c/pdsim_test/).
#
# Every build compiles a staged copy of source/ (build/stage), not source/ itself: the device's
# data disk is very slow per file, so the ~4,800 loose face/archive PNGs and ~160 fixture JSONs
# are swapped for a few dozen packed imagetables + one JSON blob per fixtures dir
# (tools/assets/pack.py -> build/packed; read by source/ui/packs.lua, which also still reads
# the loose files, so a plain `pdc source` build works too).

SDK      ?= $(HOME)/Developer/PlaydateSDK
PLAYDATE_SDK_PATH ?= $(SDK)
# common.mk invokes $(PDC) on `Source`; the wrapper compiles $(STAGE) instead.
export REAL_PDC := $(SDK)/bin/pdc
override PDC := $(CURDIR)/tools/pdc-staged.sh
SIM_APP  ?= $(SDK)/bin/Playdate Simulator.app
SIM_BIN  ?= $(SIM_APP)/Contents/MacOS/Playdate Simulator
PDX      := build/deadball.pdx
DATA     := $(SDK)/Disk/Data/com.deadball.game
SCREENS  ?= $(abspath ../docs/screens)
export STAGE_DIR := build/stage
STAGE    := $(STAGE_DIR)
PACKED   := build/packed
PACK     := ../tools/assets/pack.py
DEV_FIXTURES ?= 1
PACK_DIRS := source/images/faces source/images/archive source/fixtures source/fixtures_dev source/fixtures_dev/ballcast
# the dirs themselves too, so deleting a file re-packs
PACK_INPUTS := $(PACK) $(wildcard $(PACK_DIRS)) $(wildcard $(addsuffix /*.png,$(PACK_DIRS)) $(addsuffix /*.json,$(PACK_DIRS)))
# loose files that $(PACKED) replaces; faces.json / archive index.json are pipeline manifests the
# game never reads (images/archive/credits.json stays: the Credits page reads it)
STAGE_EXCLUDE := --exclude '/images/faces/[0-9]*.png' --exclude '/images/faces/faces.json' \
  --exclude '/images/archive/*.png' --exclude '/images/archive/index.json' \
  --exclude '/fixtures/*.json' --exclude '/fixtures_dev/*.json' --exclude '/fixtures_dev/ballcast/*.json' \
  --exclude '*.md' --exclude '.DS_Store'
DEVICE_EXCLUDE := --exclude '/pdex.dylib' $(if $(filter 0,$(DEV_FIXTURES)),--exclude '/fixtures_dev/')

# --- C extension (SDK buildsupport) --------------------------------------------
HEAP_SIZE  = 8388208
STACK_SIZE = 61800
PRODUCT    = $(PDX)
SRC        = c/main.c c/bc3d.c c/crypto.c c/pdsim.c c/pdsim_core.c
UINCDIR    = c
UDEFS      =
ASRC       = setup.s
override OBJDIR = build/obj
# keep unknown files out of the pdx (README.md etc.)
override PDCFLAGS = -k
# The newest CommandLineTools SDK can be too new for this clang's linker ("unknown architecture
# arm64e.x1"); link the Simulator dylib against the first older SDK that exists.
MACSDK ?= $(firstword $(wildcard /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX14.4.sdk))
override CLANGFLAGS = -g -O2 $(if $(MACSDK),-isysroot $(MACSDK))

# Device toolchain: Homebrew's arm-none-eabi-gcc has no newlib; prefer the full Arm GNU toolchain.
ARMBIN ?= $(firstword $(wildcard /Applications/ArmGNUToolchain/*/arm-none-eabi/bin/) $(wildcard /usr/local/playdate/gcc-arm-none-eabi-*/bin/))
ifneq ($(ARMBIN),)
override GCC := $(ARMBIN)
override OJBCPY := $(ARMBIN)
endif

include $(SDK)/C_API/buildsupport/common.mk

# common.mk passes `Source` to pdc; our tree is `source` (same dir on macOS' case-insensitive FS).
.DEFAULT_GOAL := sim

.PHONY: sim universal lua run deploy tour fixtures fonts clean-data pack stage-sim stage-device clean-stage

# $(call stage,<extra rsync excludes>): source/ minus the packed loose files, plus $(PACKED).
define stage
	@mkdir -p $(STAGE)
	@rsync -a --delete --delete-excluded $(STAGE_EXCLUDE) $(1) source/ $(STAGE)/
	@rsync -a $(1) $(PACKED)/ $(STAGE)/
	@echo "staged $(STAGE): $$(find $(STAGE) -type f | wc -l | tr -d ' ') files"
endef

$(PACKED)/.stamp: $(PACK_INPUTS)
	python3 $(PACK) $(PACKED)
	@touch $@

pack: $(PACKED)/.stamp

stage-sim: $(PACKED)/.stamp
	$(call stage,)

# common.mk owns the `device` recipe; this only adds the staging step before its pdc call
# (the old .pdx is removed because pdc doesn't delete stale files from its output)
stage-device: device_bin $(PACKED)/.stamp
	$(call stage,$(DEVICE_EXCLUDE))
	@rm -rf $(PDX)
device: stage-device

sim: simulator_bin $(PACKED)/.stamp
	$(call stage,)
	@rm -rf $(PDX)
	"$(PDC)" -k source $(PDX)

universal: device_bin simulator_bin $(PACKED)/.stamp
	$(call stage,)
	@rm -rf $(PDX)
	"$(PDC)" -k source $(PDX)

lua: $(PACKED)/.stamp
	$(call stage,)
	@rm -rf $(PDX)
	"$(PDC)" -k source $(PDX)

clean: clean-stage
clean-stage:
	rm -rf $(STAGE) $(PACKED)

run: sim
	open -a "$(SIM_APP)" $(PDX)

deploy: device
	../tools/device.sh $(PDX)

tour: sim
	@mkdir -p "$(DATA)" "$(SCREENS)"
	@echo "$(SCREENS)" > "$(DATA)/tour.flag"
	@touch "$(DATA)/debug.flag"
	@rm -f "$(DATA)/tour.done" "$(DATA)/auth.json"
	@echo '{"fixtures":"dev-token-123"}' > "$(DATA)/auth.json"
	@"$(SIM_BIN)" $(abspath $(PDX)) >/dev/null 2>&1 & echo $$! > build/sim.pid; \
	for i in $$(seq 1 1800); do [ -f "$(DATA)/tour.done" ] && break; sleep 1; done; \
	kill $$(cat build/sim.pid) 2>/dev/null; rm -f build/sim.pid "$(DATA)/tour.flag" "$(DATA)/debug.flag"
	@echo "screens in $(SCREENS)"; tail -n 40 "$(DATA)/debug.log" | grep -iE "error|tour\] step" || true

fixtures:
	python3 tools/make_dev_fixtures.py

fonts:
	python3 tools/build_fonts.py

clean-data:
	rm -rf "$(DATA)"
