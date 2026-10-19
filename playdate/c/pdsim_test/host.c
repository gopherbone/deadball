// pdsim host harness: compiles pdsim_core.c natively and checks it against the TS engine's
// calibration (packages/sim/tools/calibrate.ts), determinism, log consistency (BallCast
// timeline semantics), human-input bots, manager-decision fuzzing and speed.
//
//   ./run.sh                      build + dump worlds + everything
//   ./host calib <worlddir> <seasons> [seed]      league rates vs calibrate.ts targets
//   ./host perf <worlddir> <games>                engine time per game
//   ./host bots <worlddir> <games>                human batting/pitching bots by skill
//   ./host fuzz <worlddir> <games>                random manager decisions + log verifier
//   ./host det <worlddir>                         determinism + JSON spec path == struct path
//   ./host dumpspec <worlddir> <out.json> [seed]  a spec JSON (for the Simulator test)
//   ./host game <spec.json>                       run one spec, print box + compact log
#include "../pdsim_core.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

// --- world -------------------------------------------------------------------------------
typedef struct { PdTeam t; PdPark park; char* json; } WTeam;
typedef struct { WTeam team[16]; int nt; PdUmp ump[64]; int nu; } World;

static char* readFile(const char* path, size_t* len)
{
	FILE* f = fopen(path, "rb");
	if ( !f ) return NULL;
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	char* b = malloc((size_t)n + 1);
	if ( fread(b, 1, (size_t)n, f) != (size_t)n ) { fclose(f); free(b); return NULL; }
	b[n] = 0; fclose(f);
	if ( len ) *len = (size_t)n;
	return b;
}

static int loadWorld(World* w, const char* dir, int s)
{
	char path[512]; snprintf(path, sizeof path, "%s/world-%d.txt", dir, s);
	char* txt = readFile(path, NULL);
	if ( !txt ) { fprintf(stderr, "no %s\n", path); return -1; }
	memset(w, 0, sizeof *w);
	PdPark park = { 0 };
	for ( char* line = strtok(txt, "\n"); line; line = strtok(NULL, "\n") ) {
		if ( !strncmp(line, "UMPS ", 5) ) {
			char* p = line + 5;
			while ( *p && w->nu < 64 ) {
				float z, c; int n = 0;
				if ( sscanf(p, "%f,%f%n", &z, &c, &n) != 2 ) break;
				w->ump[w->nu].zoneWidth = z; w->ump[w->nu].consistency = c; w->nu++;
				p += n; while ( *p == ' ' ) p++;
			}
		} else if ( !strncmp(line, "PARK ", 5) ) {
			char id[32]; int turf;
			sscanf(line + 5, "%31s %f %f %f %f %f %f %f %f %f %f %f %f %d", id,
				&park.fences[0], &park.fences[1], &park.fences[2], &park.fences[3], &park.fences[4],
				&park.walls[0], &park.walls[1], &park.walls[2], &park.walls[3], &park.walls[4],
				&park.altitudeFt, &park.foulTerritory, &turf);
			park.turf = (uint8_t)turf;
		} else if ( !strncmp(line, "TEAM ", 5) ) {
			WTeam* t = &w->team[w->nt++];
			char err[96];
			if ( pd_team_from_json(&t->t, line + 5, strlen(line + 5), err, sizeof err) ) { fprintf(stderr, "team: %s\n", err); return -1; }
			t->park = park;
			t->json = strdup(line + 5);
		}
	}
	free(txt);
	return 0;
}

// rng helpers mirroring rng.ts for the schedule
static float rrange(PdRng* r, float lo, float hi) { return lo + (hi - lo) * pd_rng_float(r); }

static void advanceDay(World* w)
{
	for ( int i = 0; i < w->nt; i++ ) for ( int j = 0; j < w->team[i].t.np; j++ ) {
		PdPlayer* p = &w->team[i].t.pl[j];
		for ( int d = 4; d > 0; d-- ) p->recent[d] = p->recent[d - 1];
		p->recent[0] = 0;
		if ( p->injuryDays > 0 ) p->injuryDays--;
	}
}

static void applyGame(World* w, PdGame* g, int hi, int ai)
{
	int ti[2] = { hi, ai };
	for ( int s = 0; s < 2; s++ ) {
		PdSide* sd = &g->side[s];
		PdTeam* t = &w->team[ti[s]].t;
		for ( int i = 0; i < t->np; i++ ) t->pl[i].recent[0] = (int16_t)(t->pl[i].recent[0] + sd->pitches[i]);
		int won = g->winner == s;
		for ( int b = 0; b < sd->nbat; b++ ) {
			PdBatLine* l = &sd->bat[b];
			PdPlayer* p = &t->pl[l->pl];
			float day = (won ? 0.3f : -0.2f) + (l->h >= 2 ? 0.4f : 0) + (l->hr ? 0.4f : 0) - (l->k >= 3 ? 0.5f : 0);
			float m = p->mood * 0.9f + day;
			p->mood = m < -5 ? -5 : m > 5 ? 5 : m;
		}
	}
	for ( int i = 0; i < g->ninj; i++ ) w->team[ti[g->inj[i].side]].t.pl[g->inj[i].pl].injuryDays = g->inj[i].days;
}

// --- stats ---------------------------------------------------------------------------------
typedef struct {
	double pa, ab, h, d, tr, hr, bb, k, hbp, sf, r, sb, cs, e, dp, pitches, games, spOuts, sh;
	double n, zone, swing, zswing, oswing, contact, zcontact, ocontact, called, foul;
	double innings, extra;
} Stats;

static void addBox(Stats* t, PdGame* g, int onlySide)
{
	for ( int s = 0; s < 2; s++ ) {
		if ( onlySide >= 0 && s != onlySide ) continue;
		PdSide* sd = &g->side[s];
		for ( int i = 0; i < sd->nbat; i++ ) {
			PdBatLine* l = &sd->bat[i];
			t->ab += l->ab; t->h += l->h; t->d += l->d; t->tr += l->t; t->hr += l->hr; t->bb += l->bb; t->k += l->k;
			t->hbp += l->hbp; t->sf += l->sf; t->sb += l->sb; t->cs += l->cs; t->sh += l->sh;
			t->pa += l->ab + l->bb + l->hbp + l->sf + l->sh;
		}
		t->r += sd->runs;
		PdSide* def = &g->side[1 - s];
		t->e += def->errors;
		t->dp += def->dp;
		for ( int i = 0; i < def->npit; i++ ) t->pitches += def->pit[i].pitches;
		t->spOuts += def->pit[0].outs;
	}
	t->games++;
	t->innings += g->inning;
	if ( g->inning > 9 ) t->extra++;
}

static void addPitchStats(Stats* t, PdGame* g, int onlyBatSide)
{
	int top = 1;
	for ( int i = 0; i < g->nev; i++ ) {
		PdEvent* e = &g->ev[i];
		if ( e->k == EV_HALF ) top = e->a;
		if ( e->k != EV_P || e->c == 'H' || (e->i3 & 1) ) continue;
		if ( onlyBatSide >= 0 && (top ? 1 : 0) != onlyBatSide ) continue;
		int inZ = e->b <= 1, sw = e->c == 'S' || e->c == 'F' || e->c == 'X', con = e->c == 'F' || e->c == 'X';
		t->n++; if ( inZ ) t->zone++;
		if ( sw ) { t->swing++; if ( inZ ) t->zswing++; else t->oswing++; }
		if ( con ) { t->contact++; if ( inZ ) t->zcontact++; else t->ocontact++; }
		if ( e->c == 'C' ) t->called++;
		if ( e->c == 'F' ) t->foul++;
	}
}

typedef struct { const char* name; double v, target, tol; } Row;

static int report(Stats* t, int perTeam, const char* title, int print)
{
	double teamGames = t->games * (perTeam ? 2 : 1);
	double obpDen = t->ab + t->bb + t->hbp + t->sf;
	double tb = t->h + t->d + 2 * t->tr + 3 * t->hr;
	Row rows[] = {
		{ "R/G (per team)", t->r / teamGames, 4.5, 0.25 },
		{ "AVG", t->h / t->ab, 0.245, 0.008 },
		{ "OBP", (t->h + t->bb + t->hbp) / obpDen, 0.315, 0.008 },
		{ "SLG", tb / t->ab, 0.405, 0.015 },
		{ "K%", t->k / t->pa, 0.225, 0.012 },
		{ "BB%", t->bb / t->pa, 0.083, 0.006 },
		{ "HBP%", t->hbp / t->pa, 0.011, 0.003 },
		{ "HR/PA", t->hr / t->pa, 0.03, 0.003 },
		{ "BABIP", (t->h - t->hr) / (t->ab - t->k - t->hr + t->sf), 0.29, 0.008 },
		{ "2B/PA", t->d / t->pa, 0.044, 0.005 },
		{ "3B/PA", t->tr / t->pa, 0.004, 0.0015 },
		{ "SB/G", t->sb / t->games, 0.65, 0.2 },
		{ "E/G", t->e / t->games, 0.55, 0.15 },
		{ "DP/G", t->dp / t->games, 0.8, 0.15 },
		{ "P/PA", t->pitches / t->pa, 3.9, 0.12 },
		{ "SP IP/GS", t->spOuts / 3 / teamGames, 5.5, 0.4 },
	};
	int bad = 0;
	if ( print ) printf("%s (%.0f games)\n", title, t->games);
	for ( size_t i = 0; i < sizeof rows / sizeof rows[0]; i++ ) {
		int ok = fabs(rows[i].v - rows[i].target) <= rows[i].tol;
		if ( !ok ) bad++;
		if ( print ) printf("%s %-16s %7.3f   target %.3f +-%.3f\n", ok ? "  " : "!!", rows[i].name, rows[i].v, rows[i].target, rows[i].tol);
	}
	if ( print && t->n > 0 ) {
		printf("\npitch level (MLB reference)\n");
		printf("   Zone%%           %7.3f   ref 0.490\n", t->zone / t->n);
		printf("   Swing%%          %7.3f   ref 0.470\n", t->swing / t->n);
		printf("   Z-Swing%%        %7.3f   ref 0.670\n", t->zswing / t->zone);
		printf("   O-Swing%%        %7.3f   ref 0.300\n", t->oswing / (t->n - t->zone));
		printf("   Contact%%        %7.3f   ref 0.760\n", t->contact / t->swing);
		printf("   Z-Contact%%      %7.3f   ref 0.850\n", t->zcontact / t->zswing);
		printf("   O-Contact%%      %7.3f   ref 0.590\n", t->ocontact / t->oswing);
		printf("   CalledStr%%      %7.3f   ref 0.165\n", t->called / t->n);
		printf("   Foul%%           %7.3f   ref 0.180\n", t->foul / t->n);
		printf("   innings/G       %7.3f   extra-inning games %.1f%%\n", t->innings / t->games, 100 * t->extra / t->games);
	}
	if ( print ) printf(bad ? "\n%d stats out of range\n" : "\nall stats in range\n", bad);
	return bad;
}

// --- log verifier: BallCast timeline.lua semantics ------------------------------------------
// Rebuilds bases/outs/score from the log alone, like the replay viewer does, and checks it
// against the engine's own state: every half ends on 3 outs (except a walk-off / the end),
// the final score matches, and no two runners share a base.
typedef struct { int b[4]; int outs, home, away, top, bat; int halfOuts[100]; int nh; } TL;
static int verifyLog(PdGame* g, char* why, int whyLen)
{
	TL st; memset(&st, 0, sizeof st);
	for ( int i = 0; i < 4; i++ ) st.b[i] = -1;
#define FAIL(...) do { snprintf(why, (size_t)whyLen, __VA_ARGS__); return -1; } while ( 0 )
	int i = 0;
	while ( i < g->nev ) {
		PdEvent* e = &g->ev[i];
		// collect trailing mvs
		int j = i + 1;
		while ( j < g->nev && g->ev[j].k == EV_MV ) j++;
		int pre[4]; memcpy(pre, st.b, sizeof pre);
		int preOuts = st.outs;
		int* score = st.top ? &st.away : &st.home;
		if ( e->k == EV_HALF ) {
			if ( st.nh > 0 && st.outs != 3 ) FAIL("half %d ended with %d outs (ev %d)", st.nh, st.outs, i);
			st.halfOuts[st.nh++ % 100] = 0;
			st.top = e->a; st.outs = 0; for ( int b = 0; b < 4; b++ ) st.b[b] = -1;
		} else if ( e->k == EV_PA ) {
			st.bat = e->p0;
		} else if ( e->k == EV_BIP ) {
			int parts = 1 + (pre[1] >= 0) + (pre[2] >= 0) + (pre[3] >= 0), safe = 0, scored = 0;
			for ( int b = 1; b <= 3; b++ ) st.b[b] = -1;
			for ( int m = i + 1; m < j; m++ ) {
				PdEvent* v = &g->ev[m];
				if ( v->b == 4 ) { scored++; (*score)++; }
				else if ( v->b >= 1 && v->b <= 3 ) {
					safe++;
					if ( st.b[v->b] >= 0 ) FAIL("two runners on base %d after bip (ev %d)", v->b, i);
					st.b[v->b] = v->p0;
				}
			}
			int outs = parts - safe - scored;
			if ( outs < 0 ) FAIL("negative outs on bip (ev %d)", i);
			st.outs = preOuts + outs > 3 ? 3 : preOuts + outs;   // timeline.lua clamps (a run that didn't count leaves no mv)
		} else {
			int walk = 0;
			if ( e->k == EV_P ) {
				walk = (e->c == 'B' && e->d >= 4) || e->c == 'H';
				int k = (e->c == 'C' || e->c == 'S') && e->e >= 3;
				if ( k && st.outs < 3 ) st.outs++;
			}
			if ( e->k == EV_SB ) {
				int from = -1;
				for ( int b = 1; b <= 3; b++ ) if ( st.b[b] == e->p0 ) from = b;
				if ( from < 0 ) FAIL("sb by a runner not on base (ev %d)", i);
				st.b[from] = -1;
				if ( e->b ) { if ( e->a <= 3 ) { if ( st.b[e->a] >= 0 ) FAIL("sb into an occupied base (ev %d)", i); st.b[e->a] = e->p0; } }   // home: the run comes as an mv
				else if ( st.outs < 3 ) st.outs++;
			}
			if ( e->k == EV_END ) {
				if ( e->i0 != st.home || e->i1 != st.away ) FAIL("final %d-%d but the log says %d-%d", e->i0, e->i1, st.home, st.away);
				if ( st.outs != 3 && !(st.top == 0 && st.home > st.away) ) FAIL("last half ended with %d outs", st.outs);
			}
			for ( int m = i + 1; m < j; m++ ) {
				PdEvent* v = &g->ev[m];
				if ( walk && v->a == 0 && v->b == 1 && v->p0 == st.bat ) {
					if ( st.b[1] >= 0 ) { if ( st.b[2] >= 0 ) { if ( st.b[3] >= 0 ) FAIL("walk forced a runner home without his mv (ev %d)", i); st.b[3] = st.b[2]; } st.b[2] = st.b[1]; }
					st.b[1] = v->p0;
					continue;
				}
				int from = -1;
				for ( int b = 1; b <= 3; b++ ) if ( st.b[b] == v->p0 ) from = b;
				if ( v->b == 4 ) { if ( from > 0 ) st.b[from] = -1; (*score)++; }
				else {
					if ( from > 0 ) st.b[from] = -1; else if ( v->a > 0 ) st.b[v->a] = -1;
					if ( v->b >= 1 && v->b <= 3 ) { if ( st.b[v->b] >= 0 && st.b[v->b] != v->p0 ) FAIL("mv onto occupied base %d (ev %d)", v->b, m); st.b[v->b] = v->p0; }
				}
			}
		}
		i = j;
	}
	if ( st.home != g->side[0].runs || st.away != g->side[1].runs ) FAIL("score mismatch: engine %d-%d log %d-%d", g->side[0].runs, g->side[1].runs, st.home, st.away);
	// box consistency
	for ( int s = 0; s < 2; s++ ) {
		int r = 0, outs = 0, bf = 0, pa = 0;
		for ( int b = 0; b < g->side[s].nbat; b++ ) { PdBatLine* l = &g->side[s].bat[b]; r += l->r; pa += l->ab + l->bb + l->hbp + l->sf + l->sh; }
		for ( int b = 0; b < g->side[1 - s].npit; b++ ) { bf += g->side[1 - s].pit[b].bf; }
		for ( int b = 0; b < g->side[s].npit; b++ ) outs += g->side[s].pit[b].outs;
		if ( r != g->side[s].runs ) FAIL("side %d: batting runs %d != runs %d", s, r, g->side[s].runs);
		if ( bf < pa ) FAIL("side %d: bf %d vs pa %d", s, bf, pa);
		(void)outs;
	}
#undef FAIL
	return 0;
}

// --- season driver ------------------------------------------------------------------------
typedef void (*GameHook)(PdGame* g, PdRng* bot, void* ud);
static PdGame G;

static void setupGame(World* w, PdRng* sched, int hi, int ai, const char* seed, int logOn)
{
	PdUmp ump = w->ump[pd_rng_int(sched, w->nu)];
	PdWeather wx;
	wx.tempF = 50.f + (float)pd_rng_int(sched, 45);
	wx.windDir = rrange(sched, -180, 180);
	wx.windMph = (float)pd_rng_int(sched, 15);
	(void)pd_rng_float(sched);   // rain (incidents only)
	pd_game_init(&G, &w->team[hi].t, &w->team[ai].t, &w->team[hi].park, &wx, &ump, seed, logOn);
}

typedef int (*Driver)(PdGame* g, void* ud);   // runs the game; nonzero = failure

static int runSeasons(const char* dir, int seasons, const char* seed, Stats* st, Driver drv, void* ud, int verify, double* simTime)
{
	World* w = malloc(sizeof(World));
	int fails = 0;
	for ( int s = 0; s < seasons; s++ ) {
		if ( loadWorld(w, dir, s) ) { free(w); return -1; }
		char sseed[64]; snprintf(sseed, sizeof sseed, "%s-sched-%d", seed, s);
		PdRng sched; pd_rng_seed(&sched, sseed);
		int ord[16];
		for ( int day = 0; day < 162; day++ ) {
			advanceDay(w);
			for ( int i = 0; i < w->nt; i++ ) ord[i] = i;
			for ( int i = w->nt - 1; i > 0; i-- ) { int j = pd_rng_int(&sched, i + 1); int x = ord[i]; ord[i] = ord[j]; ord[j] = x; }
			for ( int gi = 0; gi + 1 < w->nt; gi += 2 ) {
				char gseed[96]; snprintf(gseed, sizeof gseed, "%s-%d-%d-%d", seed, s, day, gi);
				setupGame(w, &sched, ord[gi], ord[gi + 1], gseed, 1);
				double t0 = now();
				if ( drv ) { if ( drv(&G, ud) ) fails++; }
				else pd_run_all(&G);
				if ( simTime ) *simTime += now() - t0;
				if ( verify ) {
					char why[160];
					if ( verifyLog(&G, why, sizeof why) ) {
						if ( fails < 10 ) fprintf(stderr, "verify %s: %s\n", gseed, why);
						if ( fails == 0 && getenv("PDSIM_DUMP") ) {
							static char lb[1 << 20];
							FILE* df = fopen(getenv("PDSIM_DUMP"), "w");
							pd_logc(&G, 0, lb, sizeof lb);
							fprintf(df, "%s\n%s\n", why, lb); fclose(df);
						}
						fails++;
					}
				}
				if ( st ) { addBox(st, &G, -1); addPitchStats(st, &G, -1); }
				applyGame(w, &G, ord[gi], ord[gi + 1]);
			}
		}
		for ( int i = 0; i < w->nt; i++ ) free(w->team[i].json);
	}
	free(w);
	return fails;
}

// --- human bots ---------------------------------------------------------------------------------
typedef struct { float sdT, sdA, zSwing, oSwing; int side; int bat, pitch; float aimEdge; PdRng r; Stats st; } Bot;

static float nrm(PdRng* r) { float u = pd_rng_float(r) + 1e-7f, v = pd_rng_float(r); return sqrtf(-2.f * logf(u)) * cosf(6.2831853f * v); }

static int botDriver(PdGame* g, void* ud)
{
	Bot* b = ud;
	g->side[b->side].t.bat = (uint8_t)b->bat;
	g->side[b->side].t.pitch = (uint8_t)b->pitch;
	for ( int guard = 0; guard < 100000; guard++ ) {
		int p = pd_step(g, 0, NULL, NULL);
		if ( p == PAUSE_DONE ) return 0;
		if ( p == PAUSE_BAT ) {
			int inZ = g->zone <= 1;
			int swing = pd_rng_float(&b->r) < (inZ ? b->zSwing : b->oSwing) + (g->strikes == 2 ? 0.12f : 0) - (g->balls == 3 && g->strikes == 0 ? 0.5f : 0);
			pd_bat_input(g, swing, b->sdT * nrm(&b->r), g->pz + b->sdA * nrm(&b->r), 0);
		} else if ( p == PAUSE_PITCHSEL ) {
			PdSide* d = &g->side[b->side];
			const PdPlayer* P = &d->t.pl[d->pitcher];
			float tot = 0; for ( int i = 0; i < P->npitch; i++ ) tot += P->pitch[i].usage;
			float x = pd_rng_float(&b->r) * tot; int k = 0;
			for ( int i = 0; i < P->npitch; i++ ) { x -= P->pitch[i].usage; if ( x < 0 ) { k = i; break; } }
			static const char* KN[] = { "FB", "SI", "CT", "SL", "CB", "CH", "SPL", "KN", "SPIT" };
			// aim: mostly the edges, sometimes a chase pitch, behind in the count more strikes
			float r = pd_rng_float(&b->r), m = r < 0.15f ? 0.3f : r < 0.85f ? b->aimEdge : 1.25f;
			if ( g->balls == 3 ) m = 0.5f;
			float sx = pd_rng_float(&b->r) < 0.5f ? -1.f : 1.f, sz = pd_rng_float(&b->r) < 0.6f ? -1.f : 1.f;
			pd_pitch_input(g, P->npitch ? KN[P->pitch[k].kind] : "FB", sx * m * (0.6f + 0.4f * pd_rng_float(&b->r)), sz * m, 0.5f);
		}
	}
	return 1;
}

static void botBatStats(Stats* st, PdGame* g, int side)
{
	addBox(st, g, side);
	addPitchStats(st, g, side);
}

static int botSeasonDriver(PdGame* g, void* ud)
{
	Bot* b = ud;
	int r = botDriver(g, ud);
	if ( b->bat ) botBatStats(&b->st, g, b->side);
	if ( b->pitch ) botBatStats(&b->st, g, 1 - b->side);
	return r;
}

static void lineFor(const char* label, Stats* t)
{
	double tb = t->h + t->d + 2 * t->tr + 3 * t->hr;
	printf("%-28s AVG %.3f OBP %.3f SLG %.3f K%% %.3f BB%% %.3f HR/PA %.3f R/G %.2f P/PA %.2f\n", label,
		t->h / t->ab, (t->h + t->bb + t->hbp) / (t->ab + t->bb + t->hbp + t->sf), tb / t->ab, t->k / t->pa, t->bb / t->pa, t->hr / t->pa,
		t->r / t->games, t->pitches / t->pa);
}

// --- manager fuzz ---------------------------------------------------------------------------------
static int fuzzDriver(PdGame* g, void* ud)
{
	PdRng* r = ud;
	for ( int s = 0; s < 2; s++ ) { g->side[s].t.manage = 1; g->side[s].t.perPitch = (uint8_t)(pd_rng_float(r) < 0.5f); g->side[s].t.bat = (uint8_t)(pd_rng_float(r) < 0.3f); g->side[s].t.pitch = (uint8_t)(pd_rng_float(r) < 0.3f); }
	static const char* OFF[] = { "none", "steal", "bunt", "squeeze", "hitrun", "pinch_hit", "pinch_run" };
	static const char* DEF[] = { "none", "ibb", "pitch_change", "infield_in", "shift", "pitch_around" };
	for ( int guard = 0; guard < 200000; guard++ ) {
		int p = pd_step(g, 1 + pd_rng_int(r, 3), NULL, NULL);
		if ( p == PAUSE_DONE ) return 0;
		if ( p == PAUSE_PA || p == PAUSE_PITCH ) {
			if ( pd_rng_float(r) < 0.7f ) continue;
			PdSide* me = &g->side[g->pauseSide];
			if ( g->pauseRole == 0 ) {
				const char* k = OFF[pd_rng_int(r, 7)];
				char a1[PD_IDLEN] = "", a2[4] = "";
				if ( !strcmp(k, "pinch_hit") || !strcmp(k, "pinch_run") ) { if ( me->nbench ) strcpy(a1, me->t.pl[me->bench[pd_rng_int(r, me->nbench)]].id); a2[0] = (char)('1' + pd_rng_int(r, 3)); }
				else if ( !strcmp(k, "steal") ) a1[0] = (char)('1' + pd_rng_int(r, 2));
				pd_decide(g, k, a1, a2);
			} else {
				const char* k = DEF[pd_rng_int(r, 6)];
				char a1[PD_IDLEN] = "";
				if ( !strcmp(k, "pitch_change") ) strcpy(a1, me->t.pl[pd_rng_int(r, me->t.np)].id);
				if ( !strcmp(k, "ibb") && pd_rng_float(r) < 0.8f ) k = "none";
				pd_decide(g, k, a1, NULL);
			}
		} else if ( p == PAUSE_BAT && pd_rng_float(r) < 0.5f ) {
			pd_bat_input(g, pd_rng_float(r) < 0.6f, nrm(r) * 0.3f, g->pz + nrm(r) * 0.4f, pd_rng_float(r) < 0.2f);
		} else if ( p == PAUSE_PITCHSEL && pd_rng_float(r) < 0.5f ) {
			pd_pitch_input(g, pd_rng_float(r) < 0.5f ? "FB" : "XX", nrm(r), nrm(r), pd_rng_float(r));
		}
	}
	return 1;
}

// --- tactics: a manager bot that bunts/squeezes/steals/hit-and-runs whenever it fits ---------
typedef struct { PdRng r; long buntBip[11], buntMiss, buntFoul, sbOk[5], sbN[5], sq, sqRuns, hr, hrDP, hrK, hrBip; } Tac;
static int tacDriver(PdGame* g, void* ud)
{
	Tac* t = ud;
	g->side[0].t.manage = 1; g->side[0].t.perPitch = 1;
	for ( int guard = 0; guard < 200000; guard++ ) {
		int n0 = g->nev;
		int p = pd_step(g, 0, NULL, NULL);
		(void)n0;
		if ( p == PAUSE_DONE ) return 0;
		if ( (p == PAUSE_PA || p == PAUSE_PITCH) && g->pauseRole == 0 ) {
			int on1 = g->bases[1].on, on2 = g->bases[2].on, on3 = g->bases[3].on;
			float u = pd_rng_float(&t->r);
			if ( on3 && g->outs < 2 && u < 0.3f ) { if ( !pd_decide(g, "squeeze", NULL, NULL) ) t->sq++; }
			else if ( (on1 || on2) && !on3 && g->outs == 0 && g->strikes < 2 && u < 0.5f ) pd_decide(g, "bunt", NULL, NULL);
			else if ( on1 && !on2 && g->outs < 2 && u < 0.6f ) pd_decide(g, "hitrun", NULL, NULL);
			else if ( on1 && !on2 && u < 0.75f ) pd_decide(g, "steal", "1", NULL);
			else if ( on2 && !on3 && u < 0.8f ) pd_decide(g, "steal", "2", NULL);
		}
	}
	return 1;
}
static void tacScan(Tac* t, PdGame* g)
{
	int top = 1, hitrunPA = 0;
	for ( int i = 0; i < g->nev; i++ ) {
		PdEvent* e = &g->ev[i];
		if ( e->k == EV_HALF ) top = e->a;
		if ( top ) continue;   // home offense only (the bot)
		if ( e->k == EV_BIP && e->d ) t->buntBip[e->a]++;
		if ( e->k == EV_P && (e->i3 & 2) && e->c == 'S' ) t->buntMiss++;
		if ( e->k == EV_P && (e->i3 & 2) && e->c == 'F' ) t->buntFoul++;
		if ( e->k == EV_SB ) { t->sbN[e->a]++; if ( e->b ) t->sbOk[e->a]++; }
		(void)hitrunPA;
	}
}
static int tacSeason(PdGame* g, void* ud) { int r = tacDriver(g, ud); tacScan(ud, g); return r; }

static int jsonGame(const char* path)
{
	size_t n; char* s = readFile(path, &n);
	if ( !s ) return 1;
	if ( pd_game_from_json(&G, s, n, 1) ) { fprintf(stderr, "%s\n", G.err); return 1; }
	pd_run_all(&G);
	static char buf[1 << 20];
	pd_box_json(&G, buf, sizeof buf); printf("%s\n", buf);
	pd_logc(&G, 0, buf, sizeof buf); printf("%s\n", buf);
	return 0;
}

int main(int argc, char** argv)
{
	if ( argc < 2 ) { fprintf(stderr, "usage: see host.c\n"); return 2; }
	const char* mode = argv[1];
	const char* dir = argc > 2 ? argv[2] : ".";
	if ( !strcmp(mode, "calib") ) {
		int seasons = argc > 3 ? atoi(argv[3]) : 1;
		const char* seed = argc > 4 ? argv[4] : "calib";
		Stats st; memset(&st, 0, sizeof st);
		double sim = 0, t0 = now();
		int fails = runSeasons(dir, seasons, seed, &st, NULL, NULL, 1, &sim);
		printf("%.0f games in %.2fs (engine %.3f ms/game), %d log-verify failures\n\n", st.games, now() - t0, 1000 * sim / st.games, fails);
		return report(&st, 1, "pdsim C engine", 1) ? 1 : 0;
	}
	if ( !strcmp(mode, "perf") ) {
		int games = argc > 3 ? atoi(argv[3]) : 2000;
		World* w = malloc(sizeof(World));
		loadWorld(w, dir, 0);
		PdRng sched; pd_rng_seed(&sched, "perf");
		static char buf[1 << 20];
		double tRun = 0, tLog = 0, tJson = 0, tBox = 0; long evs = 0, bytes = 0, logcBytes = 0;
		for ( int i = 0; i < games; i++ ) {
			char seed[32]; snprintf(seed, sizeof seed, "perf-%d", i);
			int h = i % w->nt, a = (i + 1 + i / w->nt) % w->nt; if ( a == h ) a = (a + 1) % w->nt;
			setupGame(w, &sched, h, a, seed, 0);
			double t0 = now(); pd_run_all(&G); tRun += now() - t0;
			setupGame(w, &sched, h, a, seed, 1);
			t0 = now(); pd_run_all(&G); tLog += now() - t0;
			evs += G.nev;
			t0 = now(); logcBytes += pd_logc(&G, 0, buf, sizeof buf); bytes += pd_events_json(&G, 0, G.nev, buf, sizeof buf); tBox += now() - t0;
			// the Lua path for an AI game: spec JSON parse + run + box JSON
			char spec[200000];
			int n = snprintf(spec, sizeof spec, "{\"seed\":\"%s\",\"home\":%s,\"away\":%s}", seed, w->team[h].json, w->team[a].json);
			t0 = now();
			pd_game_from_json(&G, spec, (size_t)n, 0);
			pd_run_all(&G);
			pd_box_json(&G, buf, sizeof buf);
			tJson += now() - t0;
		}
		printf("sizeof(PdGame) = %zu bytes\n", sizeof(PdGame));
		printf("%d games: run (no log) %.3f ms/game, run with log %.3f ms/game, %.0f events/game\n", games, 1000 * tRun / games, 1000 * tLog / games, (double)evs / games);
		printf("spec JSON parse + run + box JSON: %.3f ms/game\n", 1000 * tJson / games);
		printf("log as JSON %.0f bytes/game, as compact %.0f bytes/game, emit both %.3f ms/game\n", (double)bytes / games, (double)logcBytes / games, 1000 * tBox / games);
		return 0;
	}
	if ( !strcmp(mode, "bots") ) {
		int seasons = argc > 3 ? atoi(argv[3]) : 1;
		struct { const char* name; float sdT, sdA; } skills[] = {
			{ "perfect (0 error)", 0, 0 }, { "great (t .08 a .15)", 0.08f, 0.15f }, { "good (t .15 a .3)", 0.15f, 0.3f },
			{ "average (t .25 a .45)", 0.25f, 0.45f }, { "poor (t .4 a .7)", 0.4f, 0.7f },
		};
		Stats base; memset(&base, 0, sizeof base);
		runSeasons(dir, seasons, "bots", &base, NULL, NULL, 0, NULL);
		lineFor("AI vs AI (reference)", &base);
		for ( size_t i = 0; i < sizeof skills / sizeof skills[0]; i++ ) {
			Bot b; memset(&b, 0, sizeof b);
			b.sdT = skills[i].sdT; b.sdA = skills[i].sdA; b.zSwing = 0.68f; b.oSwing = 0.28f; b.side = 0; b.bat = 1;
			pd_rng_seed(&b.r, skills[i].name);
			int f = runSeasons(dir, seasons, "bots", NULL, botSeasonDriver, &b, 1, NULL);
			char label[64]; snprintf(label, sizeof label, "bat %s", skills[i].name);
			lineFor(label, &b.st);
			if ( f ) printf("  %d failures\n", f);
		}
		float edges[] = { 0.55f, 0.8f, 1.0f };
		for ( size_t i = 0; i < 3; i++ ) {
			Bot b; memset(&b, 0, sizeof b);
			b.side = 0; b.pitch = 1; b.aimEdge = edges[i];
			pd_rng_seed(&b.r, "pitchbot");
			int f = runSeasons(dir, seasons, "bots", NULL, botSeasonDriver, &b, 1, NULL);
			char label[64]; snprintf(label, sizeof label, "pitch, aims at %.2f", edges[i]);
			lineFor(label, &b.st);
			if ( f ) printf("  %d failures\n", f);
		}
		return 0;
	}
	if ( !strcmp(mode, "fuzz") ) {
		int seasons = argc > 3 ? atoi(argv[3]) : 1;
		PdRng r; pd_rng_seed(&r, "fuzz");
		Stats st; memset(&st, 0, sizeof st);
		int f = runSeasons(dir, seasons, "fuzz", &st, fuzzDriver, &r, 1, NULL);
		printf("fuzz: %.0f games, %d failures\n", st.games, f);
		lineFor("fuzzed managers", &st);
		printf("  SB/G %.2f CS/G %.2f SH/G %.2f\n", st.sb / st.games, st.cs / st.games, st.sh / st.games);
		return f ? 1 : 0;
	}
	if ( !strcmp(mode, "det") ) {
		World* w = malloc(sizeof(World));
		loadWorld(w, dir, 0);
		static char a[1 << 20], b[1 << 20], spec[200000];
		int bad = 0;
		for ( int i = 0; i < 200; i++ ) {
			char seed[32]; snprintf(seed, sizeof seed, "det-%d", i);
			int h = i % w->nt, aw = (h + 1 + i % 3) % w->nt;
			PdPark park = w->team[h].park;
			PdWeather wx = { 72, 0, 0 }; PdUmp ump = { 50, 50 };
			pd_game_init(&G, &w->team[h].t, &w->team[aw].t, &park, &wx, &ump, seed, 1);
			pd_run_all(&G); pd_logc(&G, 0, a, sizeof a);
			pd_game_init(&G, &w->team[h].t, &w->team[aw].t, &park, &wx, &ump, seed, 1);
			pd_run_all(&G); pd_logc(&G, 0, b, sizeof b);
			if ( strcmp(a, b) ) { bad++; printf("nondeterministic: %s\n", seed); }
			int n = snprintf(spec, sizeof spec, "{\"seed\":\"%s\",\"home\":%s,\"away\":%s,\"park\":{\"fences\":[%g,%g,%g,%g,%g],\"walls\":[%g,%g,%g,%g,%g],\"altitudeFt\":%g,\"foulTerritory\":%g,\"turf\":%s},\"weather\":{\"tempF\":72,\"windDir\":0,\"windMph\":0}}",
				seed, w->team[h].json, w->team[aw].json, park.fences[0], park.fences[1], park.fences[2], park.fences[3], park.fences[4],
				park.walls[0], park.walls[1], park.walls[2], park.walls[3], park.walls[4], park.altitudeFt, park.foulTerritory, park.turf ? "true" : "false");
			if ( pd_game_from_json(&G, spec, (size_t)n, 1) ) { printf("json: %s\n", G.err); bad++; continue; }
			pd_run_all(&G); pd_logc(&G, 0, b, sizeof b);
			if ( strcmp(a, b) ) { bad++; if ( bad < 4 ) printf("json path differs: %s\n", seed); }
			// stepping one event at a time gives the same log as running straight through
			pd_game_from_json(&G, spec, (size_t)n, 1);
			while ( pd_step(&G, 1, NULL, NULL) != PAUSE_DONE ) {}
			pd_logc(&G, 0, b, sizeof b);
			if ( strcmp(a, b) ) { bad++; if ( bad < 4 ) printf("stepped log differs: %s\n", seed); }
		}
		printf("determinism: %d problems in 200 games x 4 runs\n", bad);
		return bad ? 1 : 0;
	}
	if ( !strcmp(mode, "dumpspec") ) {
		World* w = malloc(sizeof(World));
		loadWorld(w, dir, 0);
		FILE* f = fopen(argv[3], "w");
		PdPark p = w->team[0].park;
		fprintf(f, "{\"seed\":\"%s\",\"home\":%s,\"away\":%s,\"park\":{\"name\":\"Bellwood Park\",\"fences\":[%g,%g,%g,%g,%g],\"walls\":[%g,%g,%g,%g,%g],\"altitudeFt\":%g,\"foulTerritory\":%g,\"turf\":%s},\"weather\":{\"tempF\":74,\"windDir\":10,\"windMph\":6}}\n",
			argc > 4 ? argv[4] : "sim-demo", w->team[0].json, w->team[1].json, p.fences[0], p.fences[1], p.fences[2], p.fences[3], p.fences[4],
			p.walls[0], p.walls[1], p.walls[2], p.walls[3], p.walls[4], p.altitudeFt, p.foulTerritory, p.turf ? "true" : "false");
		fclose(f);
		return 0;
	}
	if ( !strcmp(mode, "game") ) return jsonGame(dir);
	if ( !strcmp(mode, "tactics") ) {
		Tac t; memset(&t, 0, sizeof t); pd_rng_seed(&t.r, "tac");
		Stats st; memset(&st, 0, sizeof st);
		int f = runSeasons(dir, 1, "tac", &st, tacSeason, &t, 1, NULL);
		static const char* BN[] = { "HR", "1B", "2B", "3B", "OUT", "DP", "FC", "ROE", "FOUL", "FOUL_OUT", "SF" };
		long nb = 0; for ( int i = 0; i < 11; i++ ) nb += t.buntBip[i];
		printf("tactics: %.0f games, %d failures\nbunts in play %ld:", st.games, f, nb);
		for ( int i = 0; i < 11; i++ ) if ( t.buntBip[i] ) printf(" %s %.1f%%", BN[i], 100.0 * t.buntBip[i] / nb);
		printf("\n  missed bunts %ld, foul bunts %ld (per bunt in play %.2f / %.2f)\n", t.buntMiss, t.buntFoul, (double)t.buntMiss / nb, (double)t.buntFoul / nb);
		for ( int b = 2; b <= 4; b++ ) if ( t.sbN[b] ) printf("steal of %s: %ld attempts, %.1f%% safe\n", b == 4 ? "home (squeeze miss)" : b == 3 ? "3B" : "2B", t.sbN[b], 100.0 * t.sbOk[b] / t.sbN[b]);
		printf("squeezes ordered %ld\n", t.sq);
		return f ? 1 : 0;
	}
	fprintf(stderr, "unknown mode\n");
	return 2;
}
