// pdsim Lua glue. The Playdate C API can't read or build Lua tables, so everything crosses as
// JSON strings (json.encode/json.decode are native) and source/pdsim/pdsim.lua wraps it.
// The engine itself is pdsim_core.c (no Playdate dependencies).
#include <string.h>
#include "pdsim.h"
#include "pdsim_core.h"

static PlaydateAPI* pd = NULL;
static const char* GAME = "pdsim.game";

// growable output buffer (one per process; outputs are pushed to Lua right away)
static char* obuf = NULL;
static int ocap = 0;

typedef int (*Emit)(PdGame* g, void* arg, char* buf, int cap);

static const char* emit(PdGame* g, void* arg, Emit fn, int* len)
{
	if ( !obuf ) { ocap = 64 * 1024; obuf = pd->system->realloc(NULL, (size_t)ocap); }
	for ( ;; ) {
		int n = fn(g, arg, obuf, ocap);
		if ( n < ocap - 1 || ocap >= 8 * 1024 * 1024 ) { *len = n; return obuf; }
		ocap *= 2;
		obuf = pd->system->realloc(obuf, (size_t)ocap);
	}
}

static int eEvents(PdGame* g, void* a, char* b, int c) { (void)a; return pd_events_json(g, g->evFrom, g->evTo, b, c); }
static int eAllEvents(PdGame* g, void* a, char* b, int c) { (void)a; return pd_events_json(g, 0, g->nev, b, c); }
static int ePause(PdGame* g, void* a, char* b, int c) { (void)a; return pd_pause_json(g, b, c); }
static int eBox(PdGame* g, void* a, char* b, int c) { (void)a; return pd_box_json(g, b, c); }
static int eInfo(PdGame* g, void* a, char* b, int c) { (void)a; return pd_info_json(g, b, c); }
static int eLogc(PdGame* g, void* a, char* b, int c) { return pd_logc(g, *(int*)a, b, c); }
static int eLineup(PdGame* g, void* a, char* b, int c) { (void)g; const PdTeam* t = ((void**)a)[0]; int vs = *(int*)((void**)a)[1]; return pd_auto_lineup_json(t, vs, b, c); }

static void pushOut(PdGame* g, void* arg, Emit fn)
{
	int n;
	const char* s = emit(g, arg, fn, &n);
	pd->lua->pushBytes(s, (size_t)n);
}

static PdGame* newGame(void)
{
	PdGame* g = pd->system->realloc(NULL, sizeof(PdGame));
	if ( g ) memset(g, 0, sizeof *g);
	return g;
}

static PdGame* argGame(int i) { return pd->lua->getArgObject(i, (char*)GAME, NULL); }

// time budget for pd_step
typedef struct { unsigned int t0, ms; } Budget;
static int timeUp(void* ud)
{
	Budget* b = ud;
	return b->ms > 0 && pd->system->getCurrentTimeMilliseconds() - b->t0 >= b->ms;
}

// pdsim._new(specJson) -> game | nil, err
static int l_new(lua_State* L)
{
	(void)L;
	size_t len = 0;
	const char* s = pd->lua->getArgBytes(1, &len);
	PdGame* g = newGame();
	if ( !g ) { pd->lua->pushNil(); pd->lua->pushString("out of memory"); return 2; }
	if ( !s || pd_game_from_json(g, s, len, 1) ) {
		pd->lua->pushNil(); pd->lua->pushString(s ? g->err : "spec must be a JSON string");
		pd->system->realloc(g, 0);
		return 2;
	}
	pd->lua->pushObject(g, (char*)GAME, 0);
	return 1;
}

static int l_gc(lua_State* L)
{
	(void)L;
	PdGame* g = argGame(1);
	if ( g ) pd->system->realloc(g, 0);
	return 0;
}

// pdsim._step(g, maxEvents, budgetMs) -> eventsJson, pauseJson|nil
static int l_step(lua_State* L)
{
	(void)L;
	PdGame* g = argGame(1);
	if ( !g ) return 0;
	int maxEv = pd->lua->argIsNil(2) ? 0 : pd->lua->getArgInt(2);
	Budget b = { pd->system->getCurrentTimeMilliseconds(), pd->lua->argIsNil(3) ? 0u : (unsigned)pd->lua->getArgInt(3) };
	int p = pd_step(g, maxEv, b.ms ? timeUp : NULL, &b);
	pushOut(g, NULL, eEvents);
	if ( p ) pushOut(g, NULL, ePause); else pd->lua->pushNil();
	return 2;
}

static const char* optStr(int i) { return pd->lua->argIsNil(i) ? NULL : pd->lua->getArgString(i); }

// pdsim._decide(g, kind, a1, a2) -> true | false, err
static int l_decide(lua_State* L)
{
	(void)L;
	PdGame* g = argGame(1);
	if ( !g ) return 0;
	if ( pd_decide(g, optStr(2), optStr(3), optStr(4)) ) { pd->lua->pushBool(0); pd->lua->pushString(g->err); return 2; }
	pd->lua->pushBool(1);
	return 1;
}

// pdsim._bat(g, swing, timing, aim, power)
static int l_bat(lua_State* L)
{
	(void)L;
	PdGame* g = argGame(1);
	if ( !g ) return 0;
	if ( g->pause != PAUSE_BAT ) { pd->lua->pushBool(0); pd->lua->pushString("not waiting for a swing"); return 2; }
	pd_bat_input(g, pd->lua->getArgBool(2), pd->lua->getArgFloat(3), pd->lua->getArgFloat(4), pd->lua->getArgBool(5));
	pd->lua->pushBool(1);
	return 1;
}

// pdsim._pitch(g, type, x, z, effort)
static int l_pitch(lua_State* L)
{
	(void)L;
	PdGame* g = argGame(1);
	if ( !g ) return 0;
	if ( g->pause != PAUSE_PITCHSEL ) { pd->lua->pushBool(0); pd->lua->pushString("not waiting for a pitch"); return 2; }
	pd_pitch_input(g, optStr(2), pd->lua->getArgFloat(3), pd->lua->getArgFloat(4), pd->lua->argIsNil(5) ? 0.5f : pd->lua->getArgFloat(5));
	pd->lua->pushBool(1);
	return 1;
}

static int l_box(lua_State* L) { (void)L; PdGame* g = argGame(1); if ( !g ) return 0; pushOut(g, NULL, eBox); return 1; }
static int l_info(lua_State* L) { (void)L; PdGame* g = argGame(1); if ( !g ) return 0; pushOut(g, NULL, eInfo); return 1; }
static int l_log(lua_State* L) { (void)L; PdGame* g = argGame(1); if ( !g ) return 0; pushOut(g, NULL, eAllEvents); return 1; }
static int l_done(lua_State* L) { (void)L; PdGame* g = argGame(1); pd->lua->pushBool(g && g->done); return 1; }
static int l_nev(lua_State* L) { (void)L; PdGame* g = argGame(1); pd->lua->pushInt(g ? g->nev : 0); return 1; }

// pdsim.logc(g [, from]) -> compact log (BallCast ?fmt=c), from = 0-based event index
static int l_logc(lua_State* L)
{
	(void)L;
	PdGame* g = argGame(1);
	if ( !g ) return 0;
	int from = pd->lua->argIsNil(2) ? 0 : pd->lua->getArgInt(2);
	pushOut(g, &from, eLogc);
	return 1;
}

// one scratch game for pdsim.simulate (no log)
static PdGame* simG = NULL;

// pdsim._simulate(specJson) -> boxJson | nil, err
static int l_simulate(lua_State* L)
{
	(void)L;
	size_t len = 0;
	const char* s = pd->lua->getArgBytes(1, &len);
	if ( !simG ) simG = newGame();
	if ( !simG || !s || pd_game_from_json(simG, s, len, 0) ) { pd->lua->pushNil(); pd->lua->pushString(simG ? simG->err : "out of memory"); return 2; }
	for ( int i = 0; i < 2; i++ ) { simG->side[i].t.manage = simG->side[i].t.perPitch = simG->side[i].t.bat = simG->side[i].t.pitch = 0; }
	pd_run_all(simG);
	pushOut(simG, NULL, eBox);
	return 1;
}

// pdsim._simStart(specJson) -> job (a game object, AI only, no log by default)
static int l_simStart(lua_State* L)
{
	(void)L;
	size_t len = 0;
	const char* s = pd->lua->getArgBytes(1, &len);
	PdGame* g = newGame();
	if ( !g ) { pd->lua->pushNil(); pd->lua->pushString("out of memory"); return 2; }
	if ( !s || pd_game_from_json(g, s, len, 0) ) { pd->lua->pushNil(); pd->lua->pushString(g->err); pd->system->realloc(g, 0); return 2; }
	for ( int i = 0; i < 2; i++ ) { g->side[i].t.manage = g->side[i].t.perPitch = g->side[i].t.bat = g->side[i].t.pitch = 0; }
	pd->lua->pushObject(g, (char*)GAME, 0);
	return 1;
}

// pdsim._simSlice(job, budgetMs) -> done, boxJson|nil
static int l_simSlice(lua_State* L)
{
	(void)L;
	PdGame* g = argGame(1);
	if ( !g ) return 0;
	Budget b = { pd->system->getCurrentTimeMilliseconds(), pd->lua->argIsNil(2) ? 5u : (unsigned)pd->lua->getArgInt(2) };
	if ( b.ms == 0 ) b.ms = 1;
	while ( !g->done ) {
		pd_step(g, 0, timeUp, &b);
		g->emitted = g->nev;
		if ( timeUp(&b) ) break;
	}
	pd->lua->pushBool(g->done);
	if ( g->done ) { pushOut(g, NULL, eBox); return 2; }
	return 1;
}

// pdsim._autoLineup(teamJson, vs) -> json
static PdTeam scratchTeam;
static int l_autoLineup(lua_State* L)
{
	(void)L;
	size_t len = 0;
	const char* s = pd->lua->getArgBytes(1, &len);
	const char* vs = optStr(2);
	char err[96];
	if ( !s || pd_team_from_json(&scratchTeam, s, len, err, sizeof err) ) { pd->lua->pushNil(); pd->lua->pushString(s ? err : "team must be JSON"); return 2; }
	int v = vs && (vs[0] == 'L' || vs[0] == 'R') ? vs[0] : 0;
	void* arg[2] = { &scratchTeam, &v };
	pushOut(NULL, arg, eLineup);
	return 1;
}

static const lua_reg pdsimLib[] = {
	{ "_new", l_new }, { "_step", l_step }, { "_decide", l_decide }, { "_bat", l_bat }, { "_pitch", l_pitch },
	{ "_box", l_box }, { "_info", l_info }, { "_log", l_log }, { "done", l_done }, { "eventCount", l_nev },
	{ "logc", l_logc }, { "_simulate", l_simulate }, { "_simStart", l_simStart }, { "_simSlice", l_simSlice },
	{ "_autoLineup", l_autoLineup },
	{ NULL, NULL }
};
static const lua_reg gameClass[] = { { "__gc", l_gc }, { NULL, NULL } };

void pdsim_register(PlaydateAPI* playdate)
{
	pd = playdate;
	const char* err = NULL;
	if ( !pd->lua->registerClass(GAME, gameClass, NULL, 0, &err) )
		pd->system->logToConsole("pdsim: registerClass(game) failed: %s", err ? err : "?");
	if ( !pd->lua->registerClass("pdsim", pdsimLib, NULL, 1, &err) )
		pd->system->logToConsole("pdsim: registerClass failed: %s", err ? err : "?");
}
