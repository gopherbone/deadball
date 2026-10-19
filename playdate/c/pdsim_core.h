// pdsim core: DEADBALL's game engine (packages/sim/src/game.ts & co.) in C, for Pennant mode.
// Pure C99, float math, fixed-size arrays; no Playdate API, no allocation (the caller owns the
// PdGame memory). Contract: docs/PENNANT_ENGINE.md.
#ifndef PDSIM_CORE_H
#define PDSIM_CORE_H

#include <stdint.h>
#include <stddef.h>

#define PD_MAXP      40    // roster size per team
#define PD_MAXPITCH  8     // pitch types per pitcher
#define PD_IDLEN     24
#define PD_MAXEV     4096  // log events per game
#define PD_MAXPATH   24576 // int16 path values per game (x,y,z triples)
#define PD_MAXBAT    32    // batting lines per team
#define PD_MAXPIT    20    // pitching lines per team
#define PD_MAXINJ    8
#define PD_MAXINN    40

// positions
enum { POS_P, POS_C, POS_1B, POS_2B, POS_3B, POS_SS, POS_LF, POS_CF, POS_RF, POS_DH, POS_N, POS_NONE = 255 };
// pitch kinds
enum { PK_FB, PK_SI, PK_CT, PK_SL, PK_CB, PK_CH, PK_SPL, PK_KN, PK_SPIT, PK_N };
// traits the engine reads
enum { TR_CLUTCH = 1, TR_CHOKER = 2, TR_SHOWBOAT = 4, TR_HOTHEAD = 8, TR_LAZY = 16 };
// bullpen roles
enum { ROLE_NONE, ROLE_CL, ROLE_SU, ROLE_MR };

typedef struct { uint8_t kind; float quality, velo, usage; } PdPitch;

typedef struct {
	char id[PD_IDLEN];
	char bats, throws;          // 'L' 'R' 'S'
	uint8_t pos;                // primary position
	float contact, power, eye, gap, lift, pull, speed, baserunning, vsL;
	float range, hands, arm, accuracy, reaction, framing;
	float fam[POS_N];           // familiarity per position, <0 = not listed
	uint8_t hasPitching;
	float stuff, control, command, movement, stamina, groundball, hold;
	uint8_t npitch;
	PdPitch pitch[PD_MAXPITCH];
	uint16_t traits;
	float mood;
	int16_t recent[5];          // recentPitches (TS): [0] today, [1] yesterday...
	int16_t injuryDays;
} PdPlayer;

typedef struct {
	char id[PD_IDLEN], abbr[12];
	PdPlayer pl[PD_MAXP];
	int np;
	// optional explicit lineup / staff (counts 0 = let the engine's manager AI fill them)
	int nlineup;  int lineup[9]; uint8_t lineupPos[9];
	int nbench;   int bench[PD_MAXP]; int benchGiven;
	int starter;  // -1 = auto
	int npen;     int pen[PD_MAXP]; uint8_t penRole[PD_MAXP];
	// human control
	uint8_t manage, perPitch, bat, pitch;
} PdTeam;

typedef struct { float fences[5], walls[5], altitudeFt, foulTerritory; uint8_t turf; } PdPark;
typedef struct { float tempF, windDir, windMph; } PdWeather;
typedef struct { float zoneWidth, consistency; } PdUmp;

typedef struct { uint32_t a, b, c, d; float spare; uint8_t hasSpare; } PdRng;

// --- log events
enum { EV_HALF, EV_PA, EV_P, EV_BIP, EV_MV, EV_SB, EV_WP, EV_SUB, EV_END };
enum { BIP_HR, BIP_1B, BIP_2B, BIP_3B, BIP_OUT, BIP_DP, BIP_FC, BIP_ROE, BIP_FOUL, BIP_FOUL_OUT, BIP_SF };
enum { OT_NONE, OT_GO, OT_FO, OT_LO, OT_PO, OT_DP, OT_FC };
enum { WHY_SAVE, WHY_SETUP, WHY_SHELLED, WHY_TIRED, WHY_MATCHUP, WHY_MANAGER, WHY_PH, WHY_PR, WHY_N };

typedef struct {
	uint8_t k;
	uint8_t a, b, c, d, e;   // small fields (see pdsim_core.c emitters)
	int16_t i0, i1, i2, i3;
	int16_t p0, p1;          // player refs (side<<8 | index), -1 none
	uint16_t pathOff, pathN; // into g->path, in triples
} PdEvent;

typedef struct {
	int16_t pl; uint8_t pos;
	int16_t ab, r, h, d, t, hr, rbi, bb, k, sb, cs, hbp, sf, sh;
} PdBatLine;
typedef struct {
	int16_t pl;
	int16_t outs, h, r, er, bb, k, hr, hbp, pitches, bf;
} PdPitLine;

typedef struct { int16_t pl; int8_t side; int16_t days; uint8_t kind; } PdInjury;

typedef struct { uint8_t pos; int16_t pl; float x, y, speed, reaction, hands, arm, accuracy; } PdFielder;

// runner on base
typedef struct { int16_t pl; int16_t resp; uint8_t unearned; uint8_t on; } PdRunner;

typedef struct {
	PdTeam t;
	int order[9]; uint8_t opos[9];
	int def[POS_N];               // player index per field position (P = current pitcher)
	int bench[PD_MAXP]; int nbench;
	// staff (indices into t.pl)
	int rotation[5], nrot;
	int closer;                   // -1 none
	int setup[PD_MAXP], nsetup;
	int middle[PD_MAXP], nmiddle;
	int penIsExplicit;
	// in-game
	int idx;
	int pitcher; uint8_t isStarter;
	int enteredOuts, plannedOuts;
	uint8_t used[PD_MAXP];        // has appeared (pitchers) / left the game (hitters)
	int runsAllowedByPitcher;
	int outsRecorded;
	float fatigueLoad[PD_MAXP];   // effort-weighted pitch counts
	int16_t pitches[PD_MAXP];     // pitch counts this game
	// box
	PdBatLine bat[PD_MAXBAT]; int nbat;
	PdPitLine pit[PD_MAXPIT]; int npit;
	int runs, hits, errors, lob, dp;
	int8_t line[PD_MAXINN]; int nline;
} PdSide;

// pause reasons
enum { PAUSE_NONE, PAUSE_PA, PAUSE_PITCH, PAUSE_PITCHSEL, PAUSE_BAT, PAUSE_DONE };

typedef struct {
	uint8_t bunt, squeeze, hitrun, steal;           // offense (steal = base the runner is on, 0 none)
	uint8_t infieldIn, shift, pitchAround;          // defense
	uint8_t ibb;
} PdOrders;

typedef struct {
	uint8_t has; uint8_t swing, power; float timing, aim;
} PdBatIn;
typedef struct {
	uint8_t has; int kind; float x, z, effort;
} PdPitchIn;

typedef struct PdGame {
	PdSide side[2];               // 0 home, 1 away
	PdPark park; PdWeather wx; PdUmp ump;
	PdRng rng;
	uint8_t logOn;
	int maxInnings;
	// state machine
	int phase;
	int inning; uint8_t top;
	int outs, balls, strikes;
	PdRunner bases[4];
	int runsBefore;
	uint8_t walkoffPossible;
	uint8_t paOver;
	int16_t paFlags;              // which pauses this PA/pitch already happened
	PdOrders ord;
	PdBatIn batIn; PdPitchIn pitchIn;
	// the pitch in flight (between PAUSE_BAT and resolution)
	int pk; float velo, px, pz; int zone; float stuffNow, fNow;
	// pause
	int pause, pendPause; int pauseSide; uint8_t pauseRole; // role 0 off 1 def
	uint8_t done;
	int winner; // 0 home 1 away
	int dw, dl, ds; // decisions: refs (side<<8|pl), -1
	// injuries
	PdInjury inj[PD_MAXINJ]; int ninj;
	// log
	PdEvent ev[PD_MAXEV]; int nev; int emitted;
	int16_t path[PD_MAXPATH]; int npath;
	// fielders for the current PA (built at PA start / after a change of alignment or pitcher)
	PdFielder fld[9]; int nfld;
	int16_t tmpPath[130 * 3]; int ntmp;
	int evFrom, evTo;             // events delivered by the last pd_step
	char err[96];
} PdGame;

// --- API --------------------------------------------------------------------------------

// JSON → spec. Fills a whole game (teams, park, weather, umpire, seed), then starts it.
// Returns 0 on success, else -1 with g->err set.
int  pd_game_from_json(PdGame* g, const char* json, size_t len, int logDefault);
// Programmatic setup (host harness): teams are copied.
void pd_game_init(PdGame* g, const PdTeam* home, const PdTeam* away, const PdPark* park,
                  const PdWeather* wx, const PdUmp* ump, const char* seed, int logOn);
// Parse one team object (the spec's `team` shape) into t. 0 ok, -1 error (msg in err).
int  pd_team_from_json(PdTeam* t, const char* json, size_t len, char* err, int errlen);

// Advance. Stops after maxEvents new events (<=0: no limit), when timeUp(ud) returns nonzero
// (checked between pitches; may be NULL), at a pause, or at the end. Returns the pause reason.
int  pd_step(PdGame* g, int maxEvents, int (*timeUp)(void*), void* ud);
// Run to the end ignoring pauses (AI makes every call).
void pd_run_all(PdGame* g);

// manager decisions; returns 0 ok else -1 with g->err
int  pd_decide(PdGame* g, const char* kind, const char* arg1, const char* arg2);
void pd_bat_input(PdGame* g, int swing, float timing, float aim, int power);
int  pd_pitch_input(PdGame* g, const char* type, float x, float z, float effort);

// Output (JSON / compact log) into buf; return length written (truncated at cap-1, NUL-terminated).
int  pd_events_json(PdGame* g, int from, int to, char* buf, int cap);  // events [from,to)
int  pd_logc(PdGame* g, int from, char* buf, int cap);                 // BallCast compact log
int  pd_box_json(PdGame* g, char* buf, int cap);
int  pd_info_json(PdGame* g, char* buf, int cap);
int  pd_pause_json(PdGame* g, char* buf, int cap);
// The engine's lineup/staff choice for a team (lineup.ts), as JSON. vsThrows 0/'L'/'R'.
int  pd_auto_lineup_json(const PdTeam* t, int vsThrows, char* buf, int cap);

// rng (exposed for the harness)
void  pd_rng_seed(PdRng* r, const char* s);
uint32_t pd_rng_u32(PdRng* r);
float pd_rng_float(PdRng* r);
int   pd_rng_int(PdRng* r, int n);

const char* pd_pos_name(int pos);
const char* pd_player_id(const PdGame* g, int ref);

#endif
