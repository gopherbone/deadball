// pdsim: the Pennant-mode game engine for Lua (docs/PENNANT_ENGINE.md). Registers the static
// class `pdsim` (low-level `pdsim._*` functions; source/pdsim/pdsim.lua builds the public API).
#ifndef PDSIM_H
#define PDSIM_H
#include "pd_api.h"
void pdsim_register(PlaydateAPI* pd);
#endif
