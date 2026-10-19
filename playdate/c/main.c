// DEADBALL C extension entry: registers the BallCast 3D renderer (`bc3d`), request
// signing (`dbcrypto`, crypto.c) and the Pennant game engine (`pdsim`, pdsim.c) for Lua.
#include "pd_api.h"
#include "bc3d.h"
#include "crypto.h"
#include "pdsim.h"

#ifdef _WINDLL
__declspec(dllexport)
#endif
int eventHandler(PlaydateAPI* playdate, PDSystemEvent event, uint32_t arg)
{
	if ( event == kEventInitLua ) {
		bc3d_register(playdate);
		dbcrypto_register(playdate);
		pdsim_register(playdate);
	}
	return 0;
}
