// pdsim core: a C port of packages/sim/src/{game,fielding,physics,tuning,lineup,rng}.ts for the
// Playdate (Pennant mode). See docs/PENNANT_ENGINE.md for the contract and pdsim_core.h for the
// data model. Float math only, no allocation, no Playdate API.
//
// Structure: the TS game loop (simulateGame/playHalf) is unrolled into a resumable state machine
// (advance(): one "unit" per call) so the game can stop at manager decision points and wait for
// a human's batting/pitching input. Everything the TS engine does in clean mode (no modifiers,
// incidents, powers) is kept; dropped features are marked "SEAM:".
#include "pdsim_core.h"
#include <math.h>
#include <string.h>
#include <stdlib.h>

#define PI_F 3.14159265f
static inline float rr(float x) { return (x - 50.f) * 0.1f; }
static inline float clampf(float x, float lo, float hi) { return x < lo ? lo : x > hi ? hi : x; }
static inline float maxf(float a, float b) { return a > b ? a : b; }
static inline float minf(float a, float b) { return a < b ? a : b; }
static inline int jsround(float x) { return (int)floorf(x + 0.5f); }

// --- tuning.ts --------------------------------------------------------------------------
#define T_zoneBase        0.502f
#define T_heartShare      0.34f
#define T_edgeOutShare    0.42f
#define T_swingHeart      0.76f
#define T_swingEdgeIn     0.62f
#define T_swingEdgeOut    0.44f
#define T_swingWaste      0.21f
#define T_contactHeart    0.9f
#define T_contactEdgeIn   0.8f
#define T_contactEdgeOut  0.67f
#define T_contactWaste    0.46f
#define T_foulHeart       0.38f
#define T_foulEdge        0.47f
#define T_foulOut         0.5f
#define T_twoStrikeContact 0.09f
#define T_twoStrikeFoul   0.17f
#define T_edgeStrikeCall  0.14f
#define T_edgeBallCall    0.12f
#define T_hbpPerPitch     0.0032f
#define T_wildPitch       0.0045f
#define T_evMean          93.f
#define T_laPenalty       0.012f
#define T_laPenaltyCap    25.f
#define T_evSd            13.5f
#define T_evUpper         0.62f
#define T_evLower         1.25f
#define T_laMean          11.f
#define T_laSd            25.f
#define T_sprayPull       9.f
#define T_spraySd         21.f
#define T_groundLA        9.f
#define T_catchBias       0.0f
#define T_infieldReach    3.f
#define T_groundCleanBase 0.96f
#define T_transfer        0.75f
#define T_pivot           0.75f
#define T_throwErr        0.012f
#define T_homeToFirst     4.35f
#define T_baseToBase      3.45f
#define T_sendMargin      0.12f
#define T_stealAttempt    0.06f
#define T_fatigueRamp     22.f

// Human input (Pennant addition; tuned with pdsim_test `host bots`): timing/aim windows, the
// contact multiplier at zero quality (C0) and its gain (C1), EV per unit quality, extra fouls
// when mistimed, and the human pitcher's target scatter.
#define HB_WT   0.45f
#define HB_WA   0.70f
#define HB_C0   0.55f
#define HB_C1   0.60f
#define HB_EV   5.f
#define HB_EV0  0.75f
#define HB_FOUL 0.2f
#define HP_SD   0.55f

// TS bug fixes (see the report / docs): runners vanished on a foul pop-out; two runners could
// end on third after a ground out. 1 = fixed (default), 0 = TS behaviour.
#ifndef PD_FIX_FOULOUT
#define PD_FIX_FOULOUT 1
#endif
#ifndef PD_FIX_GO_COLLIDE
#define PD_FIX_GO_COLLIDE 1
#endif

// --- rng.ts: sfc32 seeded with cyrb128 --------------------------------------------------
void pd_rng_seed(PdRng* r, const char* str)
{
	uint32_t h1 = 1779033703u, h2 = 3144134277u, h3 = 1013904242u, h4 = 2773480762u;
	for ( const unsigned char* s = (const unsigned char*)str; *s; s++ ) {
		uint32_t k = *s;
		h1 = h2 ^ ((h1 ^ k) * 597399067u);
		h2 = h3 ^ ((h2 ^ k) * 2869860233u);
		h3 = h4 ^ ((h3 ^ k) * 951274213u);
		h4 = h1 ^ ((h4 ^ k) * 2716044179u);
	}
	h1 = (h3 ^ (h1 >> 18)) * 597399067u;
	h2 = (h4 ^ (h2 >> 22)) * 2869860233u;
	h3 = (h1 ^ (h3 >> 17)) * 951274213u;
	h4 = (h2 ^ (h4 >> 19)) * 2716044179u;
	r->a = h1 ^ h2 ^ h3 ^ h4; r->b = h2 ^ h1; r->c = h3 ^ h1; r->d = h4 ^ h1;
	r->hasSpare = 0;
	for ( int i = 0; i < 12; i++ ) pd_rng_u32(r);
}

uint32_t pd_rng_u32(PdRng* r)
{
	uint32_t t = r->a + r->b + r->d;
	r->d = r->d + 1;
	r->a = r->b ^ (r->b >> 9);
	r->b = r->c + (r->c << 3);
	r->c = (r->c << 21) | (r->c >> 11);
	r->c = r->c + t;
	return t;
}

float pd_rng_float(PdRng* r) { return (float)(pd_rng_u32(r) >> 8) * (1.0f / 16777216.0f); }
int pd_rng_int(PdRng* r, int n) { int v = (int)(pd_rng_float(r) * (float)n); return v >= n ? n - 1 : v; }
static inline int chance(PdRng* r, float p) { return pd_rng_float(r) < p; }
static float normal(PdRng* r, float mean, float sd)
{
	if ( r->hasSpare ) { r->hasSpare = 0; return mean + sd * r->spare; }
	float u, v, s;
	do {
		u = pd_rng_float(r) * 2.f - 1.f;
		v = pd_rng_float(r) * 2.f - 1.f;
		s = u * u + v * v;
	} while ( s >= 1.f || s == 0.f );
	float m = sqrtf(-2.f * logf(s) / s);
	r->spare = v * m; r->hasSpare = 1;
	return mean + sd * u * m;
}

// --- physics.ts -------------------------------------------------------------------------
#define MPH 1.46667f
#define GRAV 32.174f
#define RHO0 0.0023769f
#define KD ((0.5f * RHO0 * 0.35f * 0.0459f) / 0.00994f)
#define KL ((0.5f * RHO0 * 0.0459f) / 0.00994f)
#define DT 0.01f

typedef struct { float distance, hang, apex, landX, landY, hFence; } Flight;

static void sprayDir(float spray, float* x, float* y)
{
	float r = spray * PI_F / 180.f;
	*x = sinf(r); *y = cosf(r);
}

static float liftCoefficient(float la)
{
	if ( la < 0 ) return -0.06f;
	if ( la < 10 ) return 0.0f;
	if ( la < 20 ) return 0.1f;
	if ( la < 50 ) return 0.18f;
	return 0.05f;
}

static void fenceAt(const PdPark* park, float spray, float* dist, float* height)
{
	float s = clampf(spray, -45.f, 45.f);
	float idx = (s + 45.f) / 22.5f;
	int i = (int)floorf(idx); if ( i > 3 ) i = 3; if ( i < 0 ) i = 0;
	float f = idx - (float)i;
	*dist = park->fences[i] + (park->fences[i + 1] - park->fences[i]) * f;
	*height = park->walls[i] + (park->walls[i + 1] - park->walls[i]) * f;
}

static void pathPush(PdGame* g, float x, float y, float z)
{
	if ( g->ntmp >= 130 ) return;
	int16_t* p = &g->tmpPath[g->ntmp * 3];
	p[0] = (int16_t)jsround(x); p[1] = (int16_t)jsround(y); p[2] = (int16_t)jsround(z);
	g->ntmp++;
}

// Batted-ball flight; also the height where it crosses `fenceDist` (or -1) and the replay path.
static void fly(PdGame* g, float evMph, float la, float spray, float fenceDist, Flight* o)
{
	float rho = (529.67f / (459.67f + g->wx.tempF)) * expf(-g->park.altitudeFt / 27000.f);
	float dx, dy, wx, wy;
	sprayDir(spray, &dx, &dy);
	sprayDir(g->wx.windDir, &wx, &wy);
	float wind = g->wx.windMph * MPH;
	float v0 = evMph * MPH;
	float laR = la * PI_F / 180.f;
	float h = 0, z = 3, vh = v0 * cosf(laR), vz = v0 * sinf(laR);
	float windAlong = wind * (wx * dx + wy * dy);
	float cl = liftCoefficient(la);
	float kd = KD * rho, kl = KL * rho * cl;
	float t = 0, apex = z, next = 0.1f;
	float ph = 0, pz = 3, hf = -1;
	g->ntmp = 0;
	pathPush(g, 0, 0, 3);
	int steps = 0;
	while ( z > 0 && steps < 1200 ) {
		float rh = vh - windAlong;
		float speed = sqrtf(rh * rh + vz * vz);
		float drag = kd * speed, lift = kl * speed;
		float ah = -drag * rh - lift * vz;
		float az = -drag * vz + lift * rh - GRAV;
		vh += ah * DT; vz += az * DT;
		h += vh * DT; z += vz * DT;
		steps++; t = (float)steps * DT;
		if ( z > apex ) apex = z;
		if ( hf < 0 && h >= fenceDist ) {
			float d = h - ph; if ( d == 0 ) d = 1;
			hf = pz + (z - pz) * ((fenceDist - ph) / d);
		}
		ph = h; pz = z;
		if ( t >= next - 1e-4f ) { pathPush(g, h * dx, h * dy, maxf(0, z)); next += 0.1f; }
	}
	pathPush(g, h * dx, h * dy, 0);
	o->distance = h; o->hang = t; o->apex = apex; o->landX = h * dx; o->landY = h * dy; o->hFence = hf;
}

static float groundDistance(float ev, float la, float t, int turf)
{
	float loss = la < -5 ? 0.62f : la < 3 ? 0.78f : 0.7f;
	float v0 = ev * MPH * loss;
	float c = turf ? 0.16f : 0.24f;
	return (v0 * (1.f - expf(-c * t))) / c;
}

// --- fielding.ts --------------------------------------------------------------------------
static const float BASEX[4] = { 0, 63.64f, 0, -63.64f };
static const float BASEY[4] = { 0, 63.64f, 127.28f, 63.64f };
static inline float dist2(float ax, float ay, float bx, float by) { float x = ax - bx, y = ay - by; return sqrtf(x * x + y * y); }

// default alignment: depth (ft) and spray angle (deg), P/C absolute
static const float ALIGN_D[POS_N] = { 0, 0, 108, 150, 106, 150, 285, 315, 285, 0 };
static const float ALIGN_S[POS_N] = { 0, 0, 36, 13, -36, -14, -27, 0, 27, 0 };

static inline int isOF(int pos) { return pos == POS_LF || pos == POS_CF || pos == POS_RF; }

static float famOf(const PdPlayer* p, int pos, float dflt) { return p->fam[pos] < 0 ? dflt : p->fam[pos]; }

// align: 0 normal, bit1 infield in, bit2 shift (pullSign in `ps`)
static void buildFielder(PdFielder* f, int pos, const PdPlayer* p, int plIdx, int align, float ps)
{
	float fam = famOf(p, pos, 0.3f);
	float k = 0.6f + 0.4f * fam, pen = (1.f - fam) * 12.f;
#define ADJ(x) (50.f + ((x) - 50.f) * k - pen)
	int of = isOF(pos);
	f->pos = (uint8_t)pos; f->pl = (int16_t)plIdx;
	if ( pos == POS_P ) { f->x = 0; f->y = 58; }
	else if ( pos == POS_C ) { f->x = 0; f->y = -3; }
	else {
		float d = ALIGN_D[pos], s = ALIGN_S[pos];
		if ( (align & 1) && !of ) d = (pos == POS_2B || pos == POS_SS) ? 112.f : 92.f;
		if ( (align & 2) && !of && pos != POS_1B ) {
			// shade the left side toward the pull field, 2B to short right/up the middle
			s += ps * (pos == POS_2B ? 13.f : 22.f);
			if ( pos == POS_2B && ps > 0 && !(align & 1) ) d = 165.f;
			s = clampf(s, -42.f, 42.f);
		}
		float sx, sy; sprayDir(s, &sx, &sy);
		f->x = sx * d; f->y = sy * d;
	}
	f->speed = (of ? 22.f : 14.f) + 0.9f * rr(ADJ(p->range)) + 0.5f * rr(p->speed);   // SEAM: WARP_RUN
	f->reaction = (pos == POS_P ? 0.62f : of ? 0.6f : 0.26f) - 0.035f * rr(ADJ(p->reaction));
	f->hands = ADJ(p->hands);
	f->arm = (of ? 92.f : 112.f) + 6.f * rr(ADJ(p->arm));                                // SEAM: LASER_ARM
	f->accuracy = ADJ(p->accuracy);
#undef ADJ
}

typedef struct { int8_t from, to; } Move;   // from 0 = batter; to 1..3 base, 4 scored, -1 out

typedef struct {
	int kind, fielder, outType, outs;
	Move mv[4]; int nmv;
	int error;            // 0 none, 1 fielding, 2 throwing
	float landX, landY, hang, dist;
	int hasPath;
	uint8_t bunt;
} Bip;

typedef struct {
	PdGame* g;
	const PdSide* off;
	int batter;           // player index on off
	int on[4];            // player index per base (1..3), -1 empty
	int outs;
	uint8_t hitRun, infieldIn, squeeze;
} Ctx;

static const PdPlayer* ctxRunner(const Ctx* c, int base) { return &c->off->t.pl[c->on[base]]; }

static float batterTimeTo(const PdPlayer* b, int bases)
{
	float s = rr(b->speed);
	float first = T_homeToFirst - 0.11f * s + (b->bats == 'L' ? -0.06f : 0.f);
	return first + (float)(bases - 1) * (T_baseToBase - 0.1f * s);
}

static float runnerTime(const PdPlayer* p, int from, int to, int going)
{
	float s = rr(p->speed);
	return (float)(to - from) * (T_baseToBase - 0.1f * s) - (going ? 0.45f : 0.f);
}

static float throwTimeXY(float ax, float ay, float bx, float by, const PdFielder* f)
{
	float d = dist2(ax, ay, bx, by);
	return d / f->arm + (d > 220.f ? 0.75f : 0.f);
}

static float aggression(const PdPlayer* p)
{
	float a = T_sendMargin - 0.04f * rr(p->baserunning);
	if ( p->traits & (TR_HOTHEAD | TR_SHOWBOAT) ) a -= 0.15f;
	if ( p->traits & TR_LAZY ) a += 0.2f;
	return a;
}

static const PdFielder* bestCatcher(const Ctx* c, float lx, float ly, float hang, float* margin)
{
	const PdFielder* best = NULL; float bm = 0;
	for ( int i = 0; i < c->g->nfld; i++ ) {
		const PdFielder* f = &c->g->fld[i];
		float need = f->reaction + dist2(f->x, f->y, lx, ly) / f->speed;
		float m = hang - need;
		if ( !best || m > bm ) { best = f; bm = m; }
	}
	*margin = bm;
	return best;
}

static float catchProb(const PdFielder* f, float margin)
{
	float base = 1.f / (1.f + expf(-(margin + T_catchBias) * 8.f));
	float hands = 0.985f + 0.004f * rr(f->hands);
	return minf(0.998f, base * hands);   // SEAM: shaky (incidents)
}

static const PdFielder* fielderAt(const Ctx* c, int pos)
{
	for ( int i = 0; i < c->g->nfld; i++ ) if ( c->g->fld[i].pos == pos ) return &c->g->fld[i];
	return NULL;
}

// nearest by time among fielders whose pos is in mask
static const PdFielder* nearestTo(const Ctx* c, unsigned mask, float x, float y)
{
	const PdFielder* best = NULL; float bt = 1e9f;
	for ( int i = 0; i < c->g->nfld; i++ ) {
		const PdFielder* f = &c->g->fld[i];
		if ( !(mask & (1u << f->pos)) ) continue;
		float t = f->reaction + dist2(f->x, f->y, x, y) / f->speed;
		if ( !best || t < bt ) { bt = t; best = f; }
	}
	return best;
}
#define M_OF ((1u << POS_LF) | (1u << POS_CF) | (1u << POS_RF))
#define M_NOT_CP (0x1FFu & ~((1u << POS_C) | (1u << POS_P)))

static void addMove(Bip* b, int from, int to) { b->mv[b->nmv].from = (int8_t)from; b->mv[b->nmv].to = (int8_t)to; b->nmv++; }

static int isForced(const Ctx* c, int base)
{
	for ( int b = 1; b <= base; b++ ) if ( c->on[b] < 0 ) return 0;
	return 1;
}

static void advanceAll(const Ctx* c, Bip* b, int batterTo, int adv)
{
	addMove(b, 0, batterTo);
	for ( int base = 1; base <= 3; base++ ) if ( c->on[base] >= 0 ) addMove(b, base, base + adv > 4 ? 4 : base + adv);
}

static void advanceForced(const Ctx* c, Bip* b, int batterTo)
{
	addMove(b, 0, batterTo);
	for ( int base = 1; base <= 3; base++ ) {
		if ( c->on[base] < 0 ) continue;
		int forced = isForced(c, base);
		int to = (forced || batterTo > 1) ? base + (batterTo > 1 ? 2 : 1) : base;
		addMove(b, base, to > 4 ? 4 : to);
	}
}

static void setLand(Bip* b, const Flight* fl)
{
	b->landX = fl->landX; b->landY = fl->landY; b->hang = fl->hang; b->dist = fl->distance; b->hasPath = 1;
}

static void doFoul(const Ctx* c, const Flight* fl, Bip* b)
{
	PdGame* g = c->g;
	setLand(b, fl);
	float room = 25.f + 0.6f * (g->park.foulTerritory - 50.f);
	if ( fl->hang > 2.6f && fl->distance < 260.f ) {
		float beyond = fabsf(fabsf(fl->landX) - fl->landY) * 0.70710678f;
		if ( beyond < room ) {
			float m; const PdFielder* best = bestCatcher(c, fl->landX, fl->landY, fl->hang, &m);
			if ( best && m > 0 && chance(&g->rng, catchProb(best, m) * 0.92f) ) {
				b->kind = BIP_FOUL_OUT; b->fielder = best->pos; b->outType = OT_PO; b->outs = 1;
				addMove(b, 0, -1);
#if PD_FIX_FOULOUT
				for ( int base = 3; base >= 1; base-- ) if ( c->on[base] >= 0 ) addMove(b, base, base);
#endif
				return;
			}
		}
	}
	b->kind = BIP_FOUL;
}

static void caughtFly(const Ctx* c, const PdFielder* f, int outType, const Flight* fl, Bip* b)
{
	PdGame* g = c->g;
	setLand(b, fl);
	b->kind = BIP_OUT; b->fielder = f->pos; b->outType = outType; b->outs = 1;
	addMove(b, 0, -1);
	int occ[5] = { 0, c->on[1] >= 0, c->on[2] >= 0, c->on[3] >= 0, 0 };
	for ( int base = 3; base >= 1; base-- ) {
		if ( c->on[base] < 0 ) continue;
		const PdPlayer* rp = ctxRunner(c, base);
		int to = base, target = base + 1;
		int open = target == 4 || !occ[target];
		if ( c->outs + b->outs < 3 && outType == OT_FO && open ) {
			float runT = runnerTime(rp, base, target, 0);
			float ballT = 0.5f + throwTimeXY(fl->landX, fl->landY, BASEX[target % 4], BASEY[target % 4], f);
			float margin = ballT - runT;
			if ( margin > aggression(rp) + (target == 4 ? 0.f : 0.5f) ) {
				float actual = margin + normal(&g->rng, 0, 0.3f);
				if ( actual > 0 ) {
					to = target; occ[base] = 0; if ( target < 4 ) occ[target] = 1;
					if ( target == 4 ) b->kind = BIP_SF;
				} else { to = -1; b->outs++; occ[base] = 0; }
			}
		} else if ( c->hitRun && base == 1 && outType == OT_LO && c->outs + b->outs < 3 && chance(&g->rng, 0.3f) ) {
			// hit-and-run: the runner was going on a line drive and gets doubled off
			to = -1; b->outs++; occ[base] = 0;
		}
		addMove(b, base, to);
	}
}

static void hitWithAdvance(const Ctx* c, float fieldT, float ax, float ay, const PdFielder* f, Bip* b)
{
	PdGame* g = c->g;
	const PdPlayer* bat = &c->off->t.pl[c->batter];
	int batterBase = 1;
	for ( int bb = 2; bb <= 4; bb++ ) {
		float runT = batterTimeTo(bat, bb);
		float ballT = fieldT + throwTimeXY(ax, ay, BASEX[bb % 4], BASEY[bb % 4], f);
		if ( ballT - runT > aggression(bat) + (bb == 4 ? 0.6f : 0.1f) ) batterBase = bb; else break;
	}
	int ends[4] = { 0, 0, 0, 0 };
	int blockAt = 5;
	for ( int base = 3; base >= 1; base-- ) {
		if ( c->on[base] < 0 ) continue;
		const PdPlayer* rp = ctxRunner(c, base);
		int forcedTo = base + 1 > 4 ? 4 : base + 1;
		int to = forcedTo;
		float extra = (c->hitRun && base == 1) ? 0.5f : 0.f;   // hit-and-run: the runner was off with the pitch
		for ( int bb = forcedTo + 1; bb <= 4; bb++ ) {
			if ( bb >= blockAt ) break;
			float runT = runnerTime(rp, base, bb, 1) - extra;
			float ballT = fieldT + throwTimeXY(ax, ay, BASEX[bb % 4], BASEY[bb % 4], f);
			if ( ballT - runT > aggression(rp) + (bb == 4 ? 0.f : 0.25f) ) to = bb; else break;
		}
		if ( to > forcedTo ) {
			float runT = runnerTime(rp, base, to, 1) - extra;
			float ballT = fieldT + throwTimeXY(ax, ay, BASEX[to % 4], BASEY[to % 4], f);
			if ( ballT - runT + normal(&g->rng, 0, 0.35f) < 0 ) { to = -1; b->outs++; }
		}
		if ( to != -1 && to < 4 ) blockAt = to;
		ends[base] = to;
	}
	for ( int base = 3; base >= 1; base-- ) {
		if ( c->on[base] < 0 ) continue;
		int e = ends[base];
		if ( e > 0 && e < 4 && batterBase >= e ) batterBase = e - 1 < 1 ? 1 : e - 1;
	}
	addMove(b, 0, batterBase);
	for ( int base = 3; base >= 1; base-- ) if ( c->on[base] >= 0 ) addMove(b, base, ends[base]);
	b->kind = batterBase >= 4 ? BIP_HR : batterBase == 3 ? BIP_3B : batterBase == 2 ? BIP_2B : BIP_1B;
	b->fielder = f->pos;
}

static float rollAfterLanding(const Flight* fl, float la)
{
	return maxf(5.f, 70.f - la * 1.6f) * (fl->distance > 200.f ? 1.f : 0.5f);
}

static void airBall(const Ctx* c, const Flight* fl, float spray, float fenceD, float fenceH, Bip* b)
{
	PdGame* g = c->g;
	setLand(b, fl);
	if ( fl->distance >= fenceD ) {
		float h = fl->hFence;
		if ( h > fenceH ) {
			// SEAM: LEAP_CATCH (an Enhanced outfielder climbing the wall)
			advanceAll(c, b, 4, 4);
			b->kind = BIP_HR;
			return;
		}
	}
	float m; const PdFielder* best = bestCatcher(c, fl->landX, fl->landY, fl->hang, &m);
	float la = atan2f(fl->apex, fl->distance / 2.f) * (180.f / PI_F);
	if ( best && chance(&g->rng, catchProb(best, m)) ) {
		int ot = fl->apex > 60.f && fl->distance < 200.f ? OT_PO : fl->apex < 25.f ? OT_LO : OT_FO;
		caughtFly(c, best, ot, fl, b);
		return;
	}
	if ( best && m > 0.6f && chance(&g->rng, 0.5f) ) {
		advanceAll(c, b, 1, 1);
		b->kind = BIP_ROE; b->fielder = best->pos; b->error = 1;
		return;
	}
	float dx, dy; sprayDir(spray, &dx, &dy);
	const PdFielder* nof = nearestTo(c, M_OF, fl->landX, fl->landY);
	float ofDepth = sqrtf(nof->x * nof->x + nof->y * nof->y);
	int pastThem = fl->distance > ofDepth - 15.f || dist2(nof->x, nof->y, fl->landX, fl->landY) > 70.f;
	float roll = pastThem ? rollAfterLanding(fl, la) + 60.f : 12.f;
	float wallDist = minf(fenceD, fl->distance + roll);
	float rx = dx * wallDist, ry = dy * wallDist;
	int atWall = wallDist >= fenceD - 1.f;
	float ballAt = fl->hang + maxf(0, wallDist - fl->distance) / 55.f + (atWall ? 1.3f : 0.f);
	const PdFielder* ret = nearestTo(c, M_NOT_CP, rx, ry);
	float fieldT = maxf(ballAt, ret->reaction + dist2(ret->x, ret->y, rx, ry) / ret->speed) + 0.45f;
	hitWithAdvance(c, fieldT, rx, ry, ret, b);
}

static void infieldSingle(const Ctx* c, const PdFielder* f, Bip* b)
{
	advanceForced(c, b, 1);
	b->kind = BIP_1B; b->fielder = f->pos;
}

static void groundBall(const Ctx* c, float ev, float la, float spray, Bip* b)
{
	PdGame* g = c->g;
	int turf = g->park.turf;
	float dx, dy; sprayDir(spray, &dx, &dy);
	static const int INF[5] = { POS_1B, POS_2B, POS_3B, POS_SS, POS_P };
	const PdFielder* pick = NULL; float pt = 0, px = 0, py = 0;
	for ( int step = 1; step < 80; step++ ) {
		float t = 0.05f * (float)step;
		float d = groundDistance(ev, la, t, turf);
		float x = dx * d, y = dy * d;
		if ( d > 170.f ) break;
		for ( int i = 0; i < 5; i++ ) {
			const PdFielder* f = fielderAt(c, INF[i]);
			if ( !f ) continue;
			if ( f->pos == POS_P && d > 70.f ) continue;
			float reach = f->pos == POS_P ? 1.5f : T_infieldReach;
			float need = f->reaction + maxf(0, dist2(f->x, f->y, x, y) - reach) / f->speed;
			if ( need <= t && !pick ) { pick = f; pt = t; px = x; py = y; }
		}
		if ( pick ) break;
	}
	float landD = groundDistance(ev, la, 0.6f, turf);
	b->landX = dx * landD; b->landY = dy * landD; b->hang = 0.6f; b->dist = landD; b->hasPath = 0;

	if ( !pick ) {
		int dtl = fabsf(spray) > 37.f;
		float fd, fh; fenceAt(&g->park, spray, &fd, &fh);
		float reachD = dtl ? minf(fd, 300.f) : 220.f;
		float ax = dx * reachD, ay = dy * reachD;
		const PdFielder* of = nearestTo(c, M_OF, ax, ay);
		float ballAt = dtl ? 4.2f : 2.3f;
		float fieldT = maxf(ballAt, of->reaction + dist2(of->x, of->y, ax, ay) / of->speed) + 0.4f + (dtl ? 0.9f : 0.f);
		hitWithAdvance(c, fieldT, ax, ay, of, b);
		return;
	}
	const PdFielder* f = pick;
	float t = pt;
	float ballSpeed = maxf(10.f, (groundDistance(ev, la, t + 0.05f, turf) - groundDistance(ev, la, t, turf)) / 0.05f);
	float lateral = maxf(0, dist2(f->x, f->y, px, py) - 2.f);
	float difficulty = lateral / 25.f + maxf(0, ballSpeed - 80.f) / 60.f;
	float cleanP = T_groundCleanBase + 0.006f * rr(f->hands) - 0.03f * difficulty;   // SEAM: shaky
	int outs = c->outs;
	if ( !chance(&g->rng, cleanP) ) {
		if ( difficulty > 0.6f || chance(&g->rng, 0.45f) ) { infieldSingle(c, f, b); return; }
		advanceForced(c, b, 1);
		b->kind = BIP_ROE; b->fielder = f->pos; b->error = 1;
		return;
	}
	float transfer = T_transfer - 0.05f * rr(f->hands) + minf(0.5f, lateral / 40.f);
	float tReady = t + transfer;
	const PdPlayer* bat = &c->off->t.pl[c->batter];
	float batterT = batterTimeTo(bat, 1);

	if ( c->on[1] >= 0 && outs < 2 ) {
		float toSecond = tReady + throwTimeXY(px, py, BASEX[2], BASEY[2], f);
		float runT = runnerTime(ctxRunner(c, 1), 1, 2, 1) + 0.25f - (c->hitRun ? 0.6f : 0.f);
		if ( toSecond + 0.1f < runT ) {
			const PdFielder* pivot = fielderAt(c, spray < 0 ? POS_2B : POS_SS);
			if ( !pivot ) pivot = f;
			float toFirst = toSecond + T_pivot - 0.04f * rr(pivot->hands) + throwTimeXY(BASEX[2], BASEY[2], BASEX[1], BASEY[1], pivot);
			int dp = toFirst + normal(&g->rng, 0, 0.12f) < batterT;
			addMove(b, 0, dp ? -1 : 1);
			addMove(b, 1, -1);
			int on2 = c->on[2] >= 0;
			for ( int base = 2; base <= 3; base++ ) {
				if ( c->on[base] < 0 ) continue;
				int forced = base == 2 ? 3 : (base == 3 && on2) ? 4 : base;
				int to = forced;
				if ( outs + (dp ? 2 : 1) < 3 && to < 4 ) {
					if ( base == 3 && chance(&g->rng, 0.65f + 0.05f * rr(ctxRunner(c, 3)->speed)) ) to = 4;
					else if ( base == 2 ) to = 3;
				}
				addMove(b, base, to);
			}
			b->kind = dp ? BIP_DP : BIP_FC; b->fielder = f->pos; b->outType = dp ? OT_DP : OT_FC; b->outs = dp ? 2 : 1;
			return;
		}
	}
	float d1 = dist2(px, py, BASEX[1], BASEY[1]);
	float toFirst = (f->pos == POS_1B && d1 < 30.f) ? tReady + d1 / 22.f : tReady + throwTimeXY(px, py, BASEX[1], BASEY[1], f);
	float throwErrP = (T_throwErr - 0.002f * rr(f->accuracy)) * (toFirst > batterT - 0.25f ? 2.f : 1.f);
	if ( chance(&g->rng, throwErrP) ) {
		advanceForced(c, b, 2);
		b->kind = BIP_ROE; b->fielder = f->pos; b->error = 2;
		return;
	}
	if ( toFirst + normal(&g->rng, 0, 0.1f) < batterT ) {
		addMove(b, 0, -1);
		int to3 = 0;   // where the runner from third ended (for the collision fix)
		for ( int base = 3; base >= 1; base-- ) {
			if ( c->on[base] < 0 ) continue;
			int to = base;
			if ( isForced(c, base) ) to = base + 1;
			else if ( outs + 1 < 3 ) {
				if ( base == 3 ) {
					if ( c->infieldIn ) {
						// infield in: he goes only if the throw home can't get him
						float toHome = tReady + throwTimeXY(px, py, 0, 0, f);
						float run = runnerTime(ctxRunner(c, 3), 3, 4, 1) + 0.3f;
						to = (toHome - run > 0.2f) ? 4 : 3;
					} else {
						to = chance(&g->rng, 0.45f + 0.08f * rr(ctxRunner(c, 3)->speed) + (spray > 0 ? 0.1f : -0.1f)) ? 4 : 3;
					}
				} else if ( base == 2 && spray > -10.f ) to = 3;
			}
#if PD_FIX_GO_COLLIDE
			if ( base == 2 && to == 3 && c->on[3] >= 0 && to3 == 3 ) to = 2;
#endif
			if ( base == 3 ) to3 = to;
			addMove(b, base, to);
		}
		b->kind = BIP_OUT; b->fielder = f->pos; b->outType = OT_GO; b->outs = 1;
		return;
	}
	infieldSingle(c, f, b);
}

static void resolveBip(const Ctx* c, float ev, float la, float spray, Bip* b)
{
	memset(b, 0, sizeof *b);
	b->fielder = POS_NONE;
	float fd, fh; fenceAt(&c->g->park, spray, &fd, &fh);
	Flight fl;
	fly(c->g, ev, la, spray, fd, &fl);
	int fair = fabsf(spray) <= 45.f;
	int ground = la < T_groundLA || (fl.apex < 9.f && fl.distance < 130.f);
	if ( !fair ) { doFoul(c, &fl, b); return; }
	if ( ground ) { groundBall(c, ev, la, spray, b); return; }
	airBall(c, &fl, spray, fd, fh, b);
}

// --- bunts (Pennant addition) --------------------------------------------------------------
// A bunt dies within ~45 ft; the corners and the battery charge it. Throw to the lead base if
// it beats the runner clearly, else take the out at first.
static void buntBall(const Ctx* c, Bip* b)
{
	PdGame* g = c->g;
	PdRng* R = &g->rng;
	memset(b, 0, sizeof *b);
	b->bunt = 1; b->fielder = POS_NONE;
	const PdPlayer* bat = &c->off->t.pl[c->batter];
	float ev = clampf(normal(R, 21.f, 5.f), 10.f, 38.f);
	float la = normal(R, -14.f, 7.f);
	float side = chance(R, 0.55f) ? -1.f : 1.f;
	float spray = clampf(normal(R, side * 24.f, 10.f), -44.f, 44.f);
	b->landX = 0; b->landY = 0; b->hang = 0.4f; b->hasPath = 0;
	// popped up?
	if ( la > 8.f || chance(R, 0.06f) ) {
		const PdFielder* f = fielderAt(c, chance(R, 0.5f) ? POS_C : POS_P);
		b->kind = BIP_OUT; b->outType = OT_PO; b->outs = 1; b->fielder = f ? f->pos : POS_C;
		addMove(b, 0, -1);
		for ( int base = 3; base >= 1; base-- ) {
			if ( c->on[base] < 0 ) continue;
			int to = base;
			if ( base == 3 && c->squeeze && c->outs + b->outs < 3 && chance(R, 0.6f) ) { to = -1; b->outs++; b->kind = BIP_DP; b->outType = OT_DP; }
			addMove(b, base, to);
		}
		b->dist = 15.f;
		return;
	}
	float dx, dy; sprayDir(spray, &dx, &dy);
	float v0 = ev * MPH * 0.62f, cfr = 0.45f;
	static const int CH[4] = { POS_P, POS_C, POS_1B, POS_3B };
	const PdFielder* pick = NULL; float pt = 0, px = 0, py = 0;
	for ( int step = 1; step <= 80 && !pick; step++ ) {
		float t = 0.05f * (float)step;
		float d = v0 * (1.f - expf(-cfr * t)) / cfr;
		float x = dx * d, y = dy * d;
		for ( int i = 0; i < 4; i++ ) {
			const PdFielder* f = fielderAt(c, CH[i]);
			if ( !f ) continue;
			float react = f->pos == POS_C ? 0.35f : f->reaction;
			float need = react + maxf(0, dist2(f->x, f->y, x, y) - 2.f) / f->speed;
			if ( need <= t && !pick ) { pick = f; pt = t; px = x; py = y; }
		}
	}
	if ( !pick ) { pick = fielderAt(c, POS_P); pt = 2.5f; px = dx * 40.f; py = dy * 40.f; }
	const PdFielder* f = pick;
	b->landX = px; b->landY = py; b->dist = sqrtf(px * px + py * py); b->fielder = f->pos;
	if ( !chance(R, 0.975f + 0.005f * rr(f->hands)) ) {
		// bobbled: everybody safe
		if ( chance(R, 0.5f) ) { advanceForced(c, b, 1); b->kind = BIP_ROE; b->error = 1; }
		else { advanceForced(c, b, 1); b->kind = BIP_1B; }
		return;
	}
	float tReady = pt + 0.55f - 0.05f * rr(f->hands);
	float batterT = batterTimeTo(bat, 1) - 0.1f;
	// squeeze: the runner from third was going with the pitch
	int sqOut = 0;
	if ( c->squeeze && c->on[3] >= 0 ) {
		float toHome = tReady + throwTimeXY(px, py, 0, 0, f);
		float run = runnerTime(ctxRunner(c, 3), 3, 4, 1) - 0.5f;
		if ( toHome + normal(R, 0, 0.15f) < run ) sqOut = 1;
	}
	// lead forced runner
	int lead = 0;
	if ( !sqOut ) {
		if ( c->on[1] >= 0 && c->on[2] >= 0 && c->on[3] < 0 ) lead = 2;
		else if ( c->on[1] >= 0 && c->on[2] < 0 ) lead = 1;
	}
	if ( sqOut ) {
		addMove(b, 0, 1);
		for ( int base = 3; base >= 1; base-- ) if ( c->on[base] >= 0 ) addMove(b, base, base == 3 ? -1 : base + 1);
		b->kind = BIP_FC; b->outType = OT_FC; b->outs = 1;
		return;
	}
	if ( lead ) {
		float toBase = tReady + throwTimeXY(px, py, BASEX[lead + 1], BASEY[lead + 1], f);
		float run = runnerTime(ctxRunner(c, lead), lead, lead + 1, 1) + 0.25f;
		if ( toBase + 0.15f < run ) {
			addMove(b, 0, 1);
			for ( int base = 3; base >= 1; base-- ) {
				if ( c->on[base] < 0 ) continue;
				addMove(b, base, base == lead ? -1 : base < lead ? base + 1 : (c->squeeze && base == 3 ? 4 : base + (isForced(c, base) ? 1 : 0)));
			}
			b->kind = BIP_FC; b->outType = OT_FC; b->outs = 1;
			return;
		}
	}
	float toFirst = tReady + throwTimeXY(px, py, BASEX[1], BASEY[1], f);
	if ( chance(R, (T_throwErr - 0.002f * rr(f->accuracy)) * (toFirst > batterT - 0.25f ? 2.f : 1.f)) ) {
		advanceForced(c, b, 2);
		b->kind = BIP_ROE; b->error = 2;
		return;
	}
	int out = toFirst + normal(R, 0, 0.1f) < batterT;
	addMove(b, 0, out ? -1 : 1);
	for ( int base = 3; base >= 1; base-- ) {
		if ( c->on[base] < 0 ) continue;
		int to;
		if ( base == 3 ) to = (c->squeeze || isForced(c, 3)) ? 4 : 3;
		else to = base + 1;
		if ( base == 2 && to == 3 && c->on[3] >= 0 && !(c->squeeze || isForced(c, 3)) ) to = 2;
		addMove(b, base, to);
	}
	b->kind = out ? BIP_OUT : BIP_1B; b->outType = out ? OT_GO : OT_NONE; b->outs = out ? 1 : 0;
}

// --- lineup.ts ------------------------------------------------------------------------------
static inline int isPitcherP(const PdPlayer* p) { return p->pos == POS_P; }
static inline int healthy(const PdPlayer* p) { return p->injuryDays <= 0; }

static float offenseOf(const PdPlayer* p)
{
	return p->contact * 0.32f + p->power * 0.3f + p->eye * 0.22f + p->gap * 0.08f + p->speed * 0.08f;
}

static char effSide(const PdPlayer* b, char throws)
{
	if ( b->bats == 'S' ) return throws == 'R' ? 'L' : 'R';
	return b->bats;
}

static float platoonAdj(const PdPlayer* b, const PdPlayer* p)
{
	char side = effSide(b, p->throws);
	float adj = side != p->throws ? 2.5f : -2.5f;
	if ( p->throws == 'L' ) adj += b->vsL;
	return adj;
}

static float defenseAt(const PdPlayer* p, int pos)
{
	float fam = famOf(p, pos, 0.f);
	float skill = pos == POS_C ? p->arm * 0.3f + p->hands * 0.3f + p->framing * 0.4f
		: pos == POS_1B ? p->hands * 0.7f + p->range * 0.3f
		: (pos == POS_LF || pos == POS_RF) ? p->range * 0.5f + p->arm * 0.3f + p->hands * 0.2f
		: p->range * 0.45f + p->hands * 0.3f + p->arm * 0.25f;
	return skill * (0.4f + 0.6f * fam) - (fam < 0.3f ? 25.f : 0.f);
}

static const int FILL[8] = { POS_C, POS_SS, POS_CF, POS_2B, POS_3B, POS_RF, POS_LF, POS_1B };
static float defWeight(int pos)
{
	switch ( pos ) {
		case POS_C: return 0.9f; case POS_SS: return 0.8f; case POS_CF: return 0.7f; case POS_2B: return 0.6f;
		case POS_3B: return 0.5f; case POS_RF: return 0.4f; case POS_LF: return 0.35f; default: return 0.25f;
	}
}

// offense with an optional platoon edge vs a pitcher's hand (vs = 0: plain TS offense)
static float offenseVs(const PdPlayer* p, int vs)
{
	float o = offenseOf(p);
	if ( vs ) {
		char side = effSide(p, (char)vs);
		float adj = side != vs ? 2.5f : -2.5f;
		if ( vs == 'L' ) adj += p->vsL;
		o += 0.62f * adj;
	}
	return o;
}

// stable insertion sort of idx[] by key desc
static void sortDesc(int* idx, float* key, int n)
{
	for ( int i = 1; i < n; i++ ) {
		int vi = idx[i]; float vk = key[i]; int j = i - 1;
		while ( j >= 0 && key[j] < vk ) { idx[j + 1] = idx[j]; key[j + 1] = key[j]; j--; }
		idx[j + 1] = vi; key[j + 1] = vk;
	}
}

// lineup.ts buildLineup. Fills order/opos (count returned) and bench.
static int autoLineup(const PdTeam* t, int vs, const uint8_t* exclude, int* order, uint8_t* opos, int* bench, int* nbench)
{
	int hit[PD_MAXP], nh = 0;
	for ( int i = 0; i < t->np; i++ ) {
		const PdPlayer* p = &t->pl[i];
		if ( !isPitcherP(p) && healthy(p) && !(exclude && exclude[i]) ) hit[nh++] = i;
	}
	uint8_t used[PD_MAXP] = { 0 };
	int defp[POS_N]; for ( int i = 0; i < POS_N; i++ ) defp[i] = -1;
	for ( int k = 0; k < 8; k++ ) {
		int pos = FILL[k], best = -1; float bv = -1e9f;
		for ( int j = 0; j < nh; j++ ) {
			int i = hit[j];
			if ( used[i] ) continue;
			float v = offenseVs(&t->pl[i], vs) + defenseAt(&t->pl[i], pos) * defWeight(pos);
			if ( v > bv ) { bv = v; best = i; }
		}
		if ( best >= 0 ) { defp[pos] = best; used[best] = 1; }
	}
	int rem[PD_MAXP]; float rk[PD_MAXP]; int nr = 0;
	for ( int j = 0; j < nh; j++ ) if ( !used[hit[j]] ) { rem[nr] = hit[j]; rk[nr] = offenseVs(&t->pl[hit[j]], vs); nr++; }
	sortDesc(rem, rk, nr);
	int nine[9]; uint8_t npos[9]; int nn = 0;
	for ( int k = 0; k < 8; k++ ) if ( defp[FILL[k]] >= 0 ) { nine[nn] = defp[FILL[k]]; npos[nn] = (uint8_t)FILL[k]; nn++; }
	int ri = 0;
	if ( nr > 0 ) { nine[nn] = rem[0]; npos[nn] = POS_DH; nn++; ri = 1; }
	// batting order: OBP-and-speed leadoff among the best five, then by offense
	int by[9]; float bk[9]; uint8_t bpos[9];
	for ( int i = 0; i < nn; i++ ) { by[i] = i; bk[i] = offenseVs(&t->pl[nine[i]], vs); }
	sortDesc(by, bk, nn);
	int lead = 0; float ls = -1e9f;
	for ( int i = 0; i < nn && i < 5; i++ ) {
		const PdPlayer* q = &t->pl[nine[by[i]]];
		float s = q->eye + q->contact + q->speed;
		if ( i == 0 || s > ls ) { ls = s; lead = i; }
	}
	int o = 0;
	order[o] = nine[by[lead]]; opos[o] = npos[by[lead]]; o++;
	for ( int i = 0; i < nn; i++ ) if ( i != lead ) { order[o] = nine[by[i]]; opos[o] = npos[by[i]]; o++; }
	(void)bpos;
	*nbench = 0;
	for ( int j = ri; j < nr; j++ ) bench[(*nbench)++] = rem[j];
	return nn;
}

static float pitchCap(const PdPlayer* p) { float s = p->hasPitching ? p->stamina : 30.f; return 30.f + (s - 20.f) * 1.4f; }
static float pitchValue(const PdPlayer* p) { return p->stuff * 0.4f + p->control * 0.25f + p->command * 0.15f + p->movement * 0.2f; }
static int relieverAvailable(const PdPlayer* p) { return p->recent[0] < 25 && p->recent[0] + p->recent[1] + p->recent[2] < 55; }

// lineup.ts buildStaff (exclude: pen members given explicitly)
static void autoStaff(const PdTeam* t, const uint8_t* exclude, int* rot, int* nrot, int* closer, int* setup, int* nsetup, int* middle, int* nmiddle)
{
	int arms[PD_MAXP]; float k[PD_MAXP]; int na = 0;
	for ( int i = 0; i < t->np; i++ ) {
		const PdPlayer* p = &t->pl[i];
		if ( isPitcherP(p) && p->hasPitching && healthy(p) && !(exclude && exclude[i]) ) { arms[na] = i; k[na] = pitchValue(p) + p->stamina * 0.6f; na++; }
	}
	int byS[PD_MAXP]; for ( int i = 0; i < na; i++ ) byS[i] = arms[i];
	sortDesc(byS, k, na);
	*nrot = na < 5 ? na : 5;
	uint8_t inRot[PD_MAXP] = { 0 };
	for ( int i = 0; i < *nrot; i++ ) { rot[i] = byS[i]; inRot[byS[i]] = 1; }
	int pen[PD_MAXP]; float pk[PD_MAXP]; int np = 0;
	for ( int i = 0; i < na; i++ ) if ( !inRot[arms[i]] ) { pen[np] = arms[i]; pk[np] = pitchValue(&t->pl[arms[i]]); np++; }
	sortDesc(pen, pk, np);
	*closer = np > 0 ? pen[0] : -1;
	*nsetup = 0; *nmiddle = 0;
	for ( int i = 1; i < np; i++ ) { if ( i < 3 ) setup[(*nsetup)++] = pen[i]; else middle[(*nmiddle)++] = pen[i]; }
}

static int pickStarter(const PdTeam* t, const int* rot, int nrot)
{
	int best = nrot > 0 ? rot[0] : -1, bestRest = -1;
	for ( int i = 0; i < nrot; i++ ) {
		const PdPlayer* p = &t->pl[rot[i]];
		int idx = -1;
		for ( int d = 0; d < 5; d++ ) if ( p->recent[d] > 40 ) { idx = d; break; }
		int rest = idx == -1 ? 99 : idx;
		if ( rest > bestRest ) { bestRest = rest; best = rot[i]; }
	}
	return best;
}

// --- game -----------------------------------------------------------------------------------
enum { PH_START, PH_HALF, PH_PA, PH_PA_GO, PH_PITCH_PRE, PH_PITCH_SEL, PH_SWING, PH_PA_END, PH_HALF_END, PH_END, PH_DONE };
// paFlags
enum { F_AIPC = 1, F_DEFPA = 2, F_OFFPA = 4, F_DEFP = 8, F_OFFP = 16, F_PSEL = 32, F_BAT = 64, F_FIRSTP = 128 };

static inline int REF(int side, int pl) { return (side << 8) | pl; }
static inline PdSide* OFFS(PdGame* g) { return &g->side[g->top ? 1 : 0]; }
static inline PdSide* DEFS(PdGame* g) { return &g->side[g->top ? 0 : 1]; }
static inline int offK(const PdGame* g) { return g->top ? 1 : 0; }
static inline int defK(const PdGame* g) { return g->top ? 0 : 1; }

static PdEvent dummyEv;
static PdEvent* logEv(PdGame* g, int k)
{
	if ( !g->logOn || g->nev >= PD_MAXEV ) { memset(&dummyEv, 0, sizeof dummyEv); return &dummyEv; }
	PdEvent* e = &g->ev[g->nev++];
	memset(e, 0, sizeof *e);
	e->k = (uint8_t)k; e->p0 = e->p1 = -1;
	return e;
}

static PdBatLine* batLine(PdSide* s, int pl)
{
	for ( int i = 0; i < s->nbat; i++ ) if ( s->bat[i].pl == pl ) return &s->bat[i];
	return NULL;
}
static PdBatLine* addBatLine(PdSide* s, int pl, int pos)
{
	PdBatLine* l = batLine(s, pl);
	if ( l ) return l;
	if ( s->nbat >= PD_MAXBAT ) return &s->bat[PD_MAXBAT - 1];
	l = &s->bat[s->nbat++];
	memset(l, 0, sizeof *l);
	l->pl = (int16_t)pl; l->pos = (uint8_t)pos;
	return l;
}
static PdPitLine* pitLine(PdSide* s, int pl)
{
	for ( int i = 0; i < s->npit; i++ ) if ( s->pit[i].pl == pl ) return &s->pit[i];
	return NULL;
}
static PdPitLine* addPitLine(PdSide* s, int pl)
{
	PdPitLine* l = pitLine(s, pl);
	if ( l ) return l;
	if ( s->npit >= PD_MAXPIT ) return &s->pit[PD_MAXPIT - 1];
	l = &s->pit[s->npit++];
	memset(l, 0, sizeof *l);
	l->pl = (int16_t)pl;
	return l;
}

// effective batting ratings: rating + mood (SEAM: modifier deltas, mods.rating)
static float effContact(const PdPlayer* p) { return p->contact + p->mood * 0.6f; }
static float effPower(const PdPlayer* p) { return p->power + p->mood * 0.6f; }
static float effEye(const PdPlayer* p) { return p->eye + p->mood * 0.6f; }
static float effSpeed(const PdPlayer* p) { return p->speed + p->mood * 0.6f; }

static float fatigueOf(const PdSide* s)
{
	const PdPlayer* p = &s->t.pl[s->pitcher];
	float pc = s->fatigueLoad[s->pitcher];
	float cap = pitchCap(p);                // SEAM: stamina modifiers
	float tired = p->recent[0] > 0 ? 8.f : 0.f;
	return maxf(0, (pc + tired - cap) / T_fatigueRamp);
}

static int curBatter(const PdSide* off) { return off->order[off->idx % 9]; }

static void buildFielders(PdGame* g)
{
	PdSide* d = DEFS(g);
	PdSide* o = OFFS(g);
	const PdPlayer* bat = &o->t.pl[curBatter(o)];
	float ps = effSide(bat, d->t.pl[d->pitcher].throws) == 'R' ? -1.f : 1.f;
	int align = (g->ord.infieldIn ? 1 : 0) | (g->ord.shift ? 2 : 0);
	g->nfld = 0;
	static const int ORDER[8] = { POS_C, POS_1B, POS_2B, POS_3B, POS_SS, POS_LF, POS_CF, POS_RF };
	for ( int i = 0; i < 8; i++ ) {
		int pl = d->def[ORDER[i]];
		if ( pl < 0 ) continue;
		buildFielder(&g->fld[g->nfld++], ORDER[i], &d->t.pl[pl], pl, align, ps);
	}
	buildFielder(&g->fld[g->nfld++], POS_P, &d->t.pl[d->pitcher], d->pitcher, align, ps);
}

static void changePitcher(PdGame* g, PdSide* s, int next, int why)
{
	int sk = (int)(s - g->side);
	PdEvent* e = logEv(g, EV_SUB);
	e->a = (uint8_t)sk; e->p0 = (int16_t)REF(sk, s->pitcher); e->p1 = (int16_t)REF(sk, next); e->b = POS_P; e->c = (uint8_t)why;
	// a pitcher batting for himself (no DH): the new one takes his slot
	for ( int i = 0; i < 9; i++ ) if ( s->order[i] == s->pitcher && s->opos[i] == POS_P ) { s->order[i] = next; addBatLine(s, next, POS_P); }
	s->pitcher = next;
	s->def[POS_P] = next;
	s->isStarter = 0;
	s->used[next] = 1;
	s->enteredOuts = s->outsRecorded;
	s->runsAllowedByPitcher = 0;
	s->plannedOuts = next == s->closer ? 3 : (chance(&g->rng, 0.6f) ? 3 : 6);
	addPitLine(s, next);
	if ( s == DEFS(g) && g->phase != PH_HALF ) buildFielders(g);
}

static int inList(const int* a, int n, int v) { for ( int i = 0; i < n; i++ ) if ( a[i] == v ) return 1; return 0; }

static int availablePen(const PdSide* s, int* out)
{
	int n = 0;
	int cand[PD_MAXP * 2], nc = 0;
	if ( s->closer >= 0 ) cand[nc++] = s->closer;
	for ( int i = 0; i < s->nsetup; i++ ) cand[nc++] = s->setup[i];
	for ( int i = 0; i < s->nmiddle; i++ ) cand[nc++] = s->middle[i];
	if ( !s->penIsExplicit ) for ( int i = 1; i < s->nrot; i++ ) cand[nc++] = s->rotation[i];
	for ( int i = 0; i < nc; i++ ) {
		int p = cand[i];
		if ( p < 0 || s->used[p] || !relieverAvailable(&s->t.pl[p]) || inList(out, n, p) ) continue;
		out[n++] = p;
	}
	return n;
}

static void considerPitchingChange(PdGame* g, PdSide* def, PdSide* off, int inning, int newInning)
{
	float f = fatigueOf(def);
	int lead = def->runs - off->runs;
	int pen[PD_MAXP * 2]; int np = availablePen(def, pen);
	if ( np == 0 ) return;
	int closer = (def->closer >= 0 && inList(pen, np, def->closer)) ? def->closer : -1;
	int outsHere = def->outsRecorded - def->enteredOuts;
	if ( newInning && inning >= 9 && lead > 0 && lead <= 3 && closer >= 0 && def->pitcher != closer ) {
		changePitcher(g, def, closer, WHY_SAVE);
		return;
	}
	if ( newInning && inning == 8 && lead > 0 && lead <= 3 && def->isStarter && f > 0.15f ) {
		for ( int i = 0; i < def->nsetup; i++ ) if ( inList(pen, np, def->setup[i]) ) { changePitcher(g, def, def->setup[i], WHY_SETUP); return; }
	}
	int shelled = def->isStarter && def->runsAllowedByPitcher >= 5 && inning <= 6;
	int gassed = f > (def->isStarter ? 0.2f : 0.5f);
	int doneRelieving = !def->isStarter && newInning && outsHere >= def->plannedOuts;
	if ( shelled || gassed || doneRelieving ) {
		int next = -1;
		if ( inning >= 8 && lead > 0 && lead <= 3 )
			for ( int i = 0; i < def->nsetup && next < 0; i++ ) if ( inList(pen, np, def->setup[i]) ) next = def->setup[i];
		if ( next < 0 )
			for ( int i = 0; i < np && next < 0; i++ ) if ( pen[i] != closer && !inList(def->setup, def->nsetup, pen[i]) ) next = pen[i];
		if ( next < 0 ) next = pen[np - 1];
		changePitcher(g, def, next, shelled ? WHY_SHELLED : gassed ? WHY_TIRED : WHY_MATCHUP);
	}
}

static void recordOut(PdGame* g, int n)
{
	PdSide* d = DEFS(g);
	g->outs += n;
	d->outsRecorded += n;
	addPitLine(d, d->pitcher)->outs += (int16_t)n;
}

static void scoreRun(PdGame* g, PdRunner br, PdBatLine* rbiTo)
{
	PdSide* off = OFFS(g); PdSide* def = DEFS(g);
	off->runs++;
	PdBatLine* l = batLine(off, br.pl);
	if ( l ) l->r++;
	if ( rbiTo ) rbiTo->rbi++;
	PdPitLine* pl = pitLine(def, br.resp);
	if ( pl ) { pl->r++; if ( !br.unearned ) pl->er++; }
	if ( br.resp == def->pitcher ) def->runsAllowedByPitcher++;
	PdEvent* e = logEv(g, EV_MV);
	e->p0 = (int16_t)REF(offK(g), br.pl); e->a = 0; e->b = 4;
}

static void logMv(PdGame* g, int pl, int from, int to)
{
	PdEvent* e = logEv(g, EV_MV);
	e->p0 = (int16_t)REF(offK(g), pl); e->a = (uint8_t)from; e->b = (uint8_t)to;
}

static void walkBatter(PdGame* g, int batter, int pitcher)
{
	PdSide* off = OFFS(g);
	PdRunner br = { (int16_t)batter, (int16_t)pitcher, 0, 1 };
	if ( g->bases[1].on ) {
		if ( g->bases[2].on ) {
			if ( g->bases[3].on ) scoreRun(g, g->bases[3], batLine(off, batter));
			g->bases[3] = g->bases[2];
		}
		g->bases[2] = g->bases[1];
	}
	g->bases[1] = br;
	logMv(g, batter, 0, 1);
}

static void advanceAllRunners(PdGame* g, int n)
{
	for ( int b = 3; b >= 1; b-- ) {
		if ( !g->bases[b].on ) continue;
		PdRunner br = g->bases[b];
		int to = b + n;
		g->bases[b].on = 0;
		if ( to >= 4 ) scoreRun(g, br, NULL);
		else { g->bases[to] = br; logMv(g, br.pl, b, to); }
	}
}

static int runnersOn(const PdGame* g) { return g->bases[1].on + g->bases[2].on + g->bases[3].on; }

static void applyBip(PdGame* g, const Bip* res, int batter, int pitcher, PdBatLine* bl, PdPitLine* pl, int outsBefore)
{
	PdSide* off = OFFS(g); PdSide* def = DEFS(g);
	int k = res->kind;
	int isHit = k == BIP_1B || k == BIP_2B || k == BIP_3B || k == BIP_HR;
	int noRbi = k == BIP_DP || k == BIP_ROE;
	int sac = 0;
	if ( res->bunt && k == BIP_OUT && res->outType == OT_GO && outsBefore < 2 ) {
		for ( int i = 0; i < res->nmv; i++ ) if ( res->mv[i].from > 0 && res->mv[i].to > res->mv[i].from ) sac = 1;
	}
	if ( k == BIP_SF ) bl->sf++;
	else if ( sac ) bl->sh++;
	else bl->ab++;
	if ( isHit ) {
		bl->h++; pl->h++; off->hits++;
		if ( k == BIP_2B ) bl->d++;
		if ( k == BIP_3B ) bl->t++;
		if ( k == BIP_HR ) { bl->hr++; pl->hr++; }
	}
	if ( res->error ) def->errors++;
	if ( k == BIP_DP ) def->dp++;
	PdRunner old[4]; memcpy(old, g->bases, sizeof old);
	PdRunner next[4]; memset(next, 0, sizeof next);
	for ( int from = 3; from >= 0; from-- ) {
		for ( int i = 0; i < res->nmv; i++ ) {
			const Move* m = &res->mv[i];
			if ( m->from != from ) continue;
			PdRunner br;
			if ( from == 0 ) { br.pl = (int16_t)batter; br.resp = (int16_t)pitcher; br.unearned = k == BIP_ROE; br.on = 1; }
			else { br = old[from]; if ( !br.on ) continue; }
			if ( m->to == -1 ) continue;
			if ( m->to >= 4 ) {
				if ( outsBefore + res->outs >= 3 && k != BIP_HR && !isHit ) continue;
				scoreRun(g, br, noRbi ? NULL : bl);
				continue;
			}
			logMv(g, br.pl, from, m->to);
			next[m->to] = br;
		}
	}
	memcpy(g->bases, next, sizeof next);
	if ( res->outs ) recordOut(g, res->outs);
}

static void logBip(PdGame* g, const Bip* r, float ev, float la, float spray)
{
	PdEvent* e = logEv(g, EV_BIP);
	e->i0 = (int16_t)jsround(ev); e->i1 = (int16_t)jsround(la); e->i2 = (int16_t)jsround(spray);
	e->a = (uint8_t)r->kind; e->b = (uint8_t)r->fielder; e->c = (uint8_t)r->outType; e->d = r->bunt;
	if ( r->hasPath && g->logOn && e != &dummyEv && g->npath + g->ntmp * 3 <= PD_MAXPATH ) {
		e->pathOff = (uint16_t)(g->npath / 3); e->pathN = (uint16_t)g->ntmp;
		memcpy(&g->path[g->npath], g->tmpPath, sizeof(int16_t) * 3 * (size_t)g->ntmp);
		g->npath += g->ntmp * 3;
	}
}

static void logPitch(PdGame* g, char r, int flags)
{
	PdEvent* e = logEv(g, EV_P);
	e->a = (uint8_t)g->pk; e->i0 = (int16_t)g->velo; e->b = (uint8_t)g->zone; e->c = (uint8_t)r;
	e->d = (uint8_t)g->balls; e->e = (uint8_t)g->strikes;
	e->i1 = (int16_t)jsround(g->px * 100.f); e->i2 = (int16_t)jsround(g->pz * 100.f); e->i3 = (int16_t)flags;
}

static void clearPA(PdGame* g)
{
	g->paFlags = 0;
	memset(&g->ord, 0, sizeof g->ord);
	g->batIn.has = 0; g->pitchIn.has = 0;
}

static void endGame(PdGame* g);

static int isFBish(int k) { return k == PK_FB || k == PK_SI || k == PK_CT; }

static const PdPitch* choosePitch(PdGame* g, const PdPlayer* p)
{
	static const PdPitch dflt = { PK_FB, 40.f, 85.f, 1.f };
	if ( p->npitch == 0 ) return &dflt;
	int behind = g->balls - g->strikes >= 2 || g->balls == 3;
	float w[PD_MAXPITCH], tot = 0;
	for ( int i = 0; i < p->npitch; i++ ) {
		float x = p->pitch[i].usage;
		if ( behind && isFBish(p->pitch[i].kind) ) x *= 1.7f;
		if ( g->strikes == 2 && !isFBish(p->pitch[i].kind) ) x *= 1.35f;
		w[i] = maxf(0, x); tot += w[i];
	}
	float r = pd_rng_float(&g->rng) * tot;
	for ( int i = 0; i < p->npitch; i++ ) { r -= w[i]; if ( r < 0 ) return &p->pitch[i]; }
	return &p->pitch[p->npitch - 1];
}

static float countZoneAdj(int b, int s)
{
	switch ( b * 10 + s ) {
		case 30: return 0.2f; case 31: return 0.1f; case 20: return 0.07f; case 21: return 0.05f; case 32: return 0.08f;
		case 10: return 0.02f; case 0: return 0.08f; case 11: return 0.f; case 22: return -0.05f; case 12: return -0.1f;
		case 2: return -0.17f; case 1: return -0.04f;
	}
	return 0;
}

static float swingProb(int zone, int b, int s, float eye, float stuff)
{
	float p = zone == 0 ? T_swingHeart : zone == 1 ? T_swingEdgeIn : zone == 2 ? T_swingEdgeOut : T_swingWaste;
	if ( zone <= 1 ) p += 0.012f * rr(eye);
	else p -= 0.035f * rr(eye) - 0.02f * rr(stuff);
	if ( s == 2 ) p += zone <= 1 ? 0.13f : 0.1f;
	if ( b == 3 && s == 0 ) p -= 0.45f;
	else if ( b == 3 ) p -= zone <= 1 ? 0.f : 0.06f;
	if ( b == 0 && s == 0 ) p -= 0.16f;
	return clampf(p, 0.02f, 0.97f);
}

static float contactProb(int zone, float contact, float stuff, float velo, int kind)
{
	float p = zone == 0 ? T_contactHeart : zone == 1 ? T_contactEdgeIn : zone == 2 ? T_contactEdgeOut : T_contactWaste;
	p += 0.035f * rr(contact) - 0.04f * rr(stuff);
	if ( isFBish(kind) ) p -= (velo - 93.f) * 0.004f;
	return clampf(p, 0.2f, 0.98f);
}

static int zoneOf(float x, float z)
{
	float m = maxf(fabsf(x), fabsf(z));
	return m < 0.6f ? 0 : m < 1.0f ? 1 : m < 1.4f ? 2 : 3;
}

// a plate location inside the given zone ring (for the log and the batting UI)
static void sampleLoc(PdRng* R, int zone, float* x, float* z)
{
	static const float LO[4] = { 0.f, 0.6f, 1.0f, 1.4f }, HI[4] = { 0.6f, 1.0f, 1.4f, 2.4f };
	float m = LO[zone] + (HI[zone] - LO[zone]) * pd_rng_float(R);
	float u = pd_rng_float(R) * 2.f - 1.f;     // position along an edge
	int edge = pd_rng_int(R, 4);
	float a = m, b = u * m;
	if ( zone == 0 ) { a = (pd_rng_float(R) * 2.f - 1.f) * 0.6f; b = (pd_rng_float(R) * 2.f - 1.f) * 0.6f; edge = 0; }
	switch ( edge ) {
		case 0: *x = a; *z = b; break;
		case 1: *x = -a; *z = b; break;
		case 2: *x = b; *z = a; break;
		default: *x = b; *z = -a; break;
	}
	// waste pitches are mostly low and away from the heart; keep them in a believable box
	*x = clampf(*x, -2.6f, 2.6f); *z = clampf(*z, -2.6f, 2.6f);
}

static float clutchAdj(PdGame* g, const PdPlayer* b)
{
	PdSide* off = OFFS(g); PdSide* def = DEFS(g);
	int close = abs(off->runs - def->runs) <= 2;
	int late = g->inning >= 7;
	int risp = g->bases[2].on || g->bases[3].on;
	if ( !(close && (late || risp)) ) return 0;
	if ( b->traits & TR_CLUTCH ) return 4;
	if ( b->traits & TR_CHOKER ) return -5;
	return 0;
}

static const char* INJ_KIND[4] = { "bruised wrist", "bruised ribs", "bruised elbow", "bruised hand" };

// steal attempt by the runner on `base` (TS: 1B → 2B only for the AI). Returns 1 if it happened.
static void doSteal(PdGame* g, int base)
{
	PdSide* off = OFFS(g); PdSide* def = DEFS(g);
	if ( base < 1 || base > 2 || !g->bases[base].on || g->bases[base + 1].on ) return;
	PdRunner r = g->bases[base];
	const PdPlayer* rp = &off->t.pl[r.pl];
	const PdPlayer* pit = &def->t.pl[def->pitcher];
	float spd = effSpeed(rp);
	float arm = def->def[POS_C] >= 0 ? def->t.pl[def->def[POS_C]].arm : 50.f;
	float hold = pit->hasPitching ? pit->hold : 50.f;
	float succ = 0.72f + 0.05f * rr(spd) - 0.05f * rr(arm) - 0.04f * rr(hold) - (base == 2 ? 0.04f : 0.f);
	int ok = chance(&g->rng, clampf(succ, 0.3f, 0.95f));
	PdEvent* e = logEv(g, EV_SB);
	e->p0 = (int16_t)REF(offK(g), r.pl); e->a = (uint8_t)(base + 1); e->b = (uint8_t)ok;
	PdBatLine* l = batLine(off, r.pl);
	g->bases[base].on = 0;
	if ( ok ) { g->bases[base + 1] = r; if ( l ) l->sb++; }
	else { if ( l ) l->cs++; recordOut(g, 1); }
	// double steal: the trailing runner takes the open base
	if ( base == 2 && g->bases[1].on && !g->bases[2].on && g->outs < 3 ) {
		PdRunner t = g->bases[1];
		PdEvent* e2 = logEv(g, EV_SB);
		e2->p0 = (int16_t)REF(offK(g), t.pl); e2->a = 2; e2->b = 1;
		g->bases[1].on = 0; g->bases[2] = t;
		PdBatLine* l2 = batLine(off, t.pl); if ( l2 ) l2->sb++;
	}
}

// the pitch: kind, velocity, location/zone (AI or the human's input)
static void throwPitch(PdGame* g)
{
	PdSide* def = DEFS(g);
	const PdPlayer* pit = &def->t.pl[def->pitcher];
	float f = fatigueOf(def);
	const PdPitch* pitch = NULL;
	float effort = 0.5f;
	if ( g->pitchIn.has ) {
		for ( int i = 0; i < pit->npitch; i++ ) if ( pit->pitch[i].kind == g->pitchIn.kind ) pitch = &pit->pitch[i];
		if ( !pitch && pit->npitch ) {
			pitch = &pit->pitch[0];
			for ( int i = 1; i < pit->npitch; i++ ) if ( pit->pitch[i].usage > pitch->usage ) pitch = &pit->pitch[i];
		}
		effort = clampf(g->pitchIn.effort, 0.f, 1.f);
	}
	if ( !pitch ) pitch = choosePitch(g, pit);
	float pStuff = pit->hasPitching ? pit->stuff : 30.f, pControl = pit->hasPitching ? pit->control : 30.f, pCommand = pit->hasPitching ? pit->command : 30.f;
	float stuff = 0.55f * pStuff + 0.45f * pitch->quality - f * 8.f + (effort - 0.5f) * 8.f;   // SEAM: stuff modifiers
	float control = pControl - f * 9.f;                                                          // SEAM: control modifiers
	float command = pCommand - f * 9.f;
	float velo = (float)jsround(pitch->velo - f * 2.f + (effort - 0.5f) * 4.f + normal(&g->rng, 0, 0.8f));
	// SEAM: pitch powers (FIREBALL/STOPPER/WARP_PITCH/CLOUD_BALL)
	g->pk = pitch->kind; g->velo = velo; g->stuffNow = stuff; g->fNow = f;
	if ( g->pitchIn.has ) {
		float sd = HP_SD - 0.05f * rr(command) - 0.02f * rr(control) + 0.25f * f + 0.25f * maxf(0, effort - 0.5f);
		sd = clampf(sd, 0.12f, 0.9f);
		g->px = clampf(g->pitchIn.x + normal(&g->rng, 0, sd), -2.6f, 2.6f);
		g->pz = clampf(g->pitchIn.z + normal(&g->rng, 0, sd), -2.6f, 2.6f);
		g->zone = zoneOf(g->px, g->pz);
	} else {
		float zp = T_zoneBase + 0.03f * rr(control) + countZoneAdj(g->balls, g->strikes) + (isFBish(pitch->kind) ? 0.04f : -0.04f);
		if ( g->ord.pitchAround ) zp -= 0.22f;
		zp = clampf(zp, g->ord.pitchAround ? 0.08f : 0.25f, 0.8f);
		if ( chance(&g->rng, zp) ) g->zone = chance(&g->rng, T_heartShare - 0.03f * rr(command) + 0.05f * f - (g->ord.pitchAround ? 0.15f : 0.f)) ? 0 : 1;
		else g->zone = chance(&g->rng, T_edgeOutShare + 0.03f * rr(command)) ? 2 : 3;
		sampleLoc(&g->rng, g->zone, &g->px, &g->pz);
	}
	def->pitches[def->pitcher]++;
	def->fatigueLoad[def->pitcher] += 1.f + (effort - 0.5f) * 0.6f;
	addPitLine(def, def->pitcher)->pitches++;
	g->pitchIn.has = 0;
}

static void endPA(PdGame* g) { g->paOver = 1; g->phase = PH_PA_END; }

static void strikeOut(PdGame* g, PdBatLine* bl, PdPitLine* pl)
{
	bl->ab++; bl->k++; pl->k++;
	recordOut(g, 1);
	endPA(g);
}

// a taken pitch: wild pitch chance, the umpire's call
// log flags for the next take: 2 = the batter showed bunt and pulled the bat back (BallCast draws it)
static int takeFlags = 0;
static void takePitch(PdGame* g, PdBatLine* bl, PdPitLine* pl, int batter, int pitcher, float control)
{
	PdSide* def = DEFS(g);
	int zone = g->zone;
	int cat = def->def[POS_C];
	if ( (zone == 3 || zone == 2) && runnersOn(g) > 0 ) {
		float hands = cat >= 0 ? def->t.pl[cat].hands : 50.f;
		if ( chance(&g->rng, (T_wildPitch / 0.45f) * (1.f - 0.12f * rr(hands)) * (1.f - 0.08f * rr(control))) ) {
			PdEvent* e = logEv(g, EV_WP);
			e->a = (uint8_t)chance(&g->rng, 0.25f);
			advanceAllRunners(g, 1);
		}
	}
	float lean = 0.f;   // SEAM: umpire zone lean (bribes, mods.zoneLean)
	float framing = cat >= 0 ? 0.025f * rr(def->t.pl[cat].framing) : 0.f;
	float umpWide = 0.03f * rr(g->ump.zoneWidth);
	float noise = normal(&g->rng, 0, 0.02f * (1.f + (50.f - g->ump.consistency) / 30.f));
	int strike;
	if ( zone == 0 ) strike = 1;
	else if ( zone == 1 ) strike = !chance(&g->rng, maxf(0, T_edgeBallCall - umpWide - framing - lean + noise));
	else if ( zone == 2 ) strike = chance(&g->rng, maxf(0, T_edgeStrikeCall + umpWide + framing + lean + noise));
	else strike = chance(&g->rng, maxf(0, lean * 0.3f));
	if ( strike ) {
		g->strikes++;
		logPitch(g, 'C', takeFlags);
		if ( g->strikes >= 3 ) strikeOut(g, bl, pl);   // SEAM: maybeEject (HOTHEAD on a borderline K)
	} else {
		g->balls++;
		logPitch(g, 'B', takeFlags);
		if ( g->balls >= 4 ) {
			bl->bb++; pl->bb++;
			walkBatter(g, batter, pitcher);
			endPA(g);
		}
	}
}

static void fillCtx(PdGame* g, Ctx* c, int batter)
{
	c->g = g; c->off = OFFS(g); c->batter = batter; c->outs = g->outs;
	for ( int b = 1; b <= 3; b++ ) c->on[b] = g->bases[b].on ? g->bases[b].pl : -1;
	c->hitRun = g->ord.hitrun && g->bases[1].on; c->infieldIn = g->ord.infieldIn; c->squeeze = g->ord.squeeze && g->bases[3].on;
}

// the swing (or take) and everything after it
static void resolvePitch(PdGame* g)
{
	PdSide* off = OFFS(g); PdSide* def = DEFS(g);
	int batter = curBatter(off);
	const PdPlayer* B = &off->t.pl[batter];
	const PdPlayer* P = &def->t.pl[def->pitcher];
	PdBatLine* bl = addBatLine(off, batter, off->opos[off->idx % 9]);
	PdPitLine* pl = addPitLine(def, def->pitcher);
	PdRng* R = &g->rng;
	int zone = g->zone;
	float stuff = g->stuffNow, f = g->fNow;
	float control = (P->hasPitching ? P->control : 30.f) - f * 9.f;
	float platoon = platoonAdj(B, P);
	float clutch = clutchAdj(g, B);
	int timesThrough = (pl->bf - 1) / 9;
	float contact = effContact(B) + platoon + clutch + (timesThrough >= 2 ? 2.f : 0.f);
	float eye = effEye(B);
	float power = effPower(B) + platoon * 0.7f + clutch;
	int hitrun = g->ord.hitrun && g->bases[1].on && !g->bases[2].on;
	int squeeze = g->ord.squeeze && g->bases[3].on;
	int bunting = squeeze || (g->ord.bunt && g->strikes < 2) ;
	int contactMade = 0;

	// --- bunt
	if ( bunting ) {
		int attempt = squeeze || zone <= 1 || (zone == 2 && chance(R, 0.5f));
		if ( !attempt ) {
			takeFlags = 2;      // squared around, pulled it back (log only: no effect on the play)
			takePitch(g, bl, pl, batter, def->pitcher, control);
			takeFlags = 0;
		} else {
			float cP = (zone == 0 ? 0.86f : zone == 1 ? 0.78f : zone == 2 ? 0.6f : 0.35f) + 0.04f * rr(contact) - 0.03f * rr(stuff);
			cP = clampf(cP, 0.1f, 0.97f);
			if ( !chance(R, cP) ) {
				g->strikes++;
				logPitch(g, 'S', 2);
				if ( squeeze && g->bases[3].on ) {
					// hung out to dry
					PdRunner r = g->bases[3];
					int ok = chance(R, 0.15f);
					PdEvent* e = logEv(g, EV_SB);
					e->p0 = (int16_t)REF(offK(g), r.pl); e->a = 4; e->b = (uint8_t)ok;
					g->bases[3].on = 0;
					if ( ok ) scoreRun(g, r, NULL);
					else { PdBatLine* l = batLine(off, r.pl); if ( l ) l->cs++; recordOut(g, 1); }
				}
				if ( g->strikes >= 3 && g->outs < 3 ) strikeOut(g, bl, pl);
				else if ( g->outs >= 3 ) { g->paOver = 0; g->phase = PH_PA_END; }
			} else if ( chance(R, 0.32f) ) {
				if ( g->strikes < 2 ) { g->strikes++; logPitch(g, 'F', 2); }
				else { g->strikes++; logPitch(g, 'S', 2); strikeOut(g, bl, pl); }   // foul bunt with two strikes
			} else {
				logPitch(g, 'X', 2);
				Ctx c; fillCtx(g, &c, batter);
				Bip res; buntBall(&c, &res);
				logBip(g, &res, 0, 0, 0);
				applyBip(g, &res, batter, def->pitcher, bl, pl, g->outs);
				endPA(g);
			}
		}
		goto after;
	}

	// --- swing decision
	int swung;
	int human = g->batIn.has;
	if ( human ) swung = g->batIn.swing;
	else {
		float swingP = swingProb(zone, g->balls, g->strikes, eye, stuff);   // SEAM: pitch power swingAdd
		if ( hitrun ) swingP = maxf(swingP, zone <= 1 ? 0.95f : zone == 2 ? 0.8f : 0.45f);
		swung = chance(R, swingP);
	}
	if ( !swung ) {
		takePitch(g, bl, pl, batter, def->pitcher, control);
		goto after;
	}
	// SEAM: HYPER_HIT
	{
		float cP = contactProb(zone, contact, stuff, g->velo, g->pk) + (g->strikes == 2 ? T_twoStrikeContact : 0.f);
		if ( hitrun ) cP += 0.04f;
		float tf = 1.f, af = 1.f;
		if ( human ) {
			float wT = HB_WT + 0.04f * rr(contact), wA = HB_WA + 0.05f * rr(contact);
			float te = g->batIn.timing / maxf(0.1f, wT), ae = (g->batIn.aim - g->pz) / maxf(0.1f, wA);
			tf = expf(-te * te); af = expf(-ae * ae);
			cP *= HB_C0 + HB_C1 * tf * af;
			if ( g->batIn.power ) cP *= 0.85f;
			cP = clampf(cP, 0.02f, 0.98f);
		}
		if ( !chance(R, cP) ) {
			g->strikes++;
			logPitch(g, 'S', 0);
			if ( g->strikes >= 3 ) strikeOut(g, bl, pl);
			goto after;
		}
		float foulP = (zone == 0 ? T_foulHeart : zone <= 2 ? T_foulEdge : T_foulOut) + (g->strikes == 2 ? T_twoStrikeFoul : 0.f);
		if ( human ) foulP += HB_FOUL * (1.f - tf);
		contactMade = 1;
		if ( chance(R, foulP) ) {
			if ( g->strikes < 2 ) g->strikes++;
			logPitch(g, 'F', 0);
			goto after;
		}
		// ball in play
		float zoneEv = zone == 0 ? 3.f : zone == 1 ? 0.f : zone == 2 ? -4.f : -8.f;
		float z = normal(R, 0, 1);
		float evMean = T_evMean + 2.3f * rr(power) + zoneEv - 1.2f * rr(P->hasPitching ? P->movement : 30.f) - 0.8f * rr(stuff) + f * 2.f;
		float laMean = T_laMean + 4.f * rr(B->lift) - 4.f * rr(P->hasPitching ? P->groundball : 50.f);
		if ( hitrun ) evMean -= 2.f;
		float pullSign = effSide(B, P->throws) == 'R' ? -1.f : 1.f;
		float sprayShift = 0;
		if ( human ) {
			evMean += HB_EV * (tf * af - HB_EV0) + (g->batIn.power ? 3.f : 0.f);
			laMean += 20.f * (g->pz - g->batIn.aim) + (g->batIn.power ? 3.f : 0.f);
			sprayShift = pullSign * (-g->batIn.timing) * 25.f;
		}
		float la = normal(R, laMean, T_laSd);
		float offSweet = minf(T_laPenaltyCap, T_laPenalty * (la - 15.f) * (la - 15.f));
		float ev = clampf(evMean - offSweet + T_evSd * (z > 0 ? z * T_evUpper : z * T_evLower), 25.f, 120.f);
		float spray = normal(R, pullSign * (T_sprayPull + 4.f * rr(B->pull)) * (la < 10.f ? 1.4f : 0.8f) + sprayShift, T_spraySd);
		Ctx c; fillCtx(g, &c, batter);
		Bip res; resolveBip(&c, ev, la, spray, &res);
		if ( res.kind == BIP_FOUL ) {
			if ( g->strikes < 2 ) g->strikes++;
			logPitch(g, 'F', 0);
			goto after;
		}
		logPitch(g, 'X', 0);
		logBip(g, &res, ev, la, spray);
		applyBip(g, &res, batter, def->pitcher, bl, pl, g->outs);
		endPA(g);
	}
after:
	// hit-and-run that didn't put the ball in play: the runner was stealing
	if ( hitrun && !bunting && !contactMade && g->outs < 3 && g->bases[1].on && !g->bases[2].on && !(g->paOver && g->balls >= 4) )
		doSteal(g, 1);
	if ( g->outs >= 3 && !g->paOver ) g->phase = PH_PA_END;
}

static void doIBB(PdGame* g)
{
	PdSide* off = OFFS(g); PdSide* def = DEFS(g);
	int batter = curBatter(off);
	const PdPlayer* P = &def->t.pl[def->pitcher];
	PdBatLine* bl = addBatLine(off, batter, off->opos[off->idx % 9]);
	PdPitLine* pl = addPitLine(def, def->pitcher);
	g->pk = P->npitch ? P->pitch[0].kind : PK_FB;
	g->velo = (float)jsround((P->npitch ? P->pitch[0].velo : 85.f) * 0.7f); g->zone = 3; g->px = 2.f; g->pz = 0.f;
	g->balls = 4;
	logPitch(g, 'B', 1);
	bl->bb++; pl->bb++;
	walkBatter(g, batter, def->pitcher);
	endPA(g);
}

static int sideHuman(const PdSide* s) { return s->t.manage; }

// one unit of work; returns a pause reason or 0
static int advance(PdGame* g)
{
	PdSide* off = OFFS(g); PdSide* def = DEFS(g);
	switch ( g->phase ) {
	case PH_START:
		g->inning = 1; g->top = 1;
		g->phase = PH_HALF;
		return 0;
	case PH_HALF: {
		if ( !g->top && g->inning >= 9 && g->side[0].runs > g->side[1].runs ) {
			PdSide* h = &g->side[0];
			if ( h->nline < PD_MAXINN ) h->line[h->nline++] = -1;
			g->phase = PH_END;
			return 0;
		}
		memset(g->bases, 0, sizeof g->bases);
		g->outs = 0;
		PdEvent* e = logEv(g, EV_HALF);
		e->i0 = (int16_t)g->inning; e->a = g->top;
		g->walkoffPossible = !g->top && g->inning >= 9;
		// SEAM: rollClockIncidents
		clearPA(g);
		if ( !sideHuman(def) ) considerPitchingChange(g, def, off, g->inning, 1);
		g->runsBefore = off->runs;
		g->phase = PH_PA;
		return 0;
	}
	case PH_PA:
		if ( g->outs >= 3 ) { g->phase = PH_HALF_END; return 0; }
		if ( g->walkoffPossible && off->runs > def->runs ) { g->phase = PH_HALF_END; return 0; }
		if ( !(g->paFlags & F_AIPC) ) {
			g->paFlags |= F_AIPC;
			if ( !sideHuman(def) ) considerPitchingChange(g, def, off, g->inning, 0);
			buildFielders(g);
		}
		if ( sideHuman(def) && !(g->paFlags & F_DEFPA) ) { g->paFlags |= F_DEFPA; g->pauseSide = defK(g); g->pauseRole = 1; return PAUSE_PA; }
		if ( sideHuman(off) && !(g->paFlags & F_OFFPA) ) { g->paFlags |= F_OFFPA; g->pauseSide = offK(g); g->pauseRole = 0; return PAUSE_PA; }
		g->phase = PH_PA_GO;
		return 0;
	case PH_PA_GO: {
		int batter = curBatter(off);
		PdEvent* e = logEv(g, EV_PA);
		e->p0 = (int16_t)REF(offK(g), batter); e->p1 = (int16_t)REF(defK(g), def->pitcher);
		addPitLine(def, def->pitcher)->bf++;
		addBatLine(off, batter, off->opos[off->idx % 9]);
		g->balls = g->strikes = 0;
		g->paOver = 0;
		g->paFlags |= F_FIRSTP;
		buildFielders(g);
		if ( g->ord.ibb ) { doIBB(g); return 0; }
		g->phase = PH_PITCH_PRE;
		return 0;
	}
	case PH_PITCH_PRE: {
		if ( g->walkoffPossible && off->runs > def->runs ) { g->phase = PH_HALF_END; return 0; }
		int first = g->paFlags & F_FIRSTP;
		if ( !first ) {
			if ( sideHuman(def) && def->t.perPitch && !(g->paFlags & F_DEFP) ) { g->paFlags |= F_DEFP; g->pauseSide = defK(g); g->pauseRole = 1; return PAUSE_PITCH; }
			if ( sideHuman(off) && off->t.perPitch && !(g->paFlags & F_OFFP) ) { g->paFlags |= F_OFFP; g->pauseSide = offK(g); g->pauseRole = 0; return PAUSE_PITCH; }
		}
		if ( g->ord.ibb ) { doIBB(g); return 0; }
		// stolen base attempts happen between pitches
		if ( sideHuman(off) ) {
			if ( g->ord.steal ) { doSteal(g, g->ord.steal); g->ord.steal = 0; }
		} else if ( g->bases[1].on && !g->bases[2].on && g->outs < 2 ) {
			const PdPlayer* rp = &off->t.pl[g->bases[1].pl];
			float spd = effSpeed(rp);
			if ( spd > 52.f ) {
				float tryP = T_stealAttempt * maxf(0, (spd - 50.f) / 15.f) * ((rp->traits & TR_SHOWBOAT) ? 1.5f : 1.f);
				if ( chance(&g->rng, tryP) ) doSteal(g, 1);
			}
		}
		if ( g->outs >= 3 ) { g->paOver = 0; g->phase = PH_PA_END; return 0; }
		g->phase = PH_PITCH_SEL;
		return 0;
	}
	case PH_PITCH_SEL: {
		if ( def->t.pitch && !g->pitchIn.has && !(g->paFlags & F_PSEL) ) {
			g->paFlags |= F_PSEL; g->pauseSide = defK(g); g->pauseRole = 1;
			return PAUSE_PITCHSEL;
		}
		throwPitch(g);
		// hit by pitch
		const PdPlayer* P = &def->t.pl[def->pitcher];
		float control = (P->hasPitching ? P->control : 30.f) - g->fNow * 9.f;
		float hbpMult = 1.f;   // SEAM: grudges/retaliation (mods "hbp")
		if ( g->zone == 3 && chance(&g->rng, (T_hbpPerPitch / 0.3f) * (1.f - 0.15f * rr(control)) * hbpMult) ) {
			int batter = curBatter(off);
			PdBatLine* bl = addBatLine(off, batter, off->opos[off->idx % 9]);
			PdPitLine* pl = addPitLine(def, def->pitcher);
			logPitch(g, 'H', 0);
			bl->hbp++; pl->hbp++;
			walkBatter(g, batter, def->pitcher);
			if ( chance(&g->rng, 0.03f) && g->ninj < PD_MAXINJ ) {
				PdInjury* in = &g->inj[g->ninj++];
				in->pl = (int16_t)batter; in->side = (int8_t)offK(g);
				in->kind = (uint8_t)pd_rng_int(&g->rng, 4); in->days = (int16_t)(2 + pd_rng_int(&g->rng, 9));
			}
			// SEAM: maybeBrawl
			endPA(g);
			return 0;
		}
		g->phase = PH_SWING;
		int bunting = (g->ord.squeeze && g->bases[3].on) || (g->ord.bunt && g->strikes < 2);
		if ( off->t.bat && !bunting && !g->batIn.has && !(g->paFlags & F_BAT) ) {
			g->paFlags |= F_BAT; g->pauseSide = offK(g); g->pauseRole = 0;
			return PAUSE_BAT;
		}
		return 0;
	}
	case PH_SWING:
		g->phase = PH_PITCH_PRE;
		resolvePitch(g);
		// per-pitch state
		g->paFlags &= ~(F_DEFP | F_OFFP | F_PSEL | F_BAT | F_FIRSTP);
		g->batIn.has = 0;
		g->ord.hitrun = 0; g->ord.squeeze = 0; g->ord.steal = 0;
		if ( g->strikes >= 2 ) g->ord.bunt = 0;
		if ( g->walkoffPossible && off->runs > def->runs && g->phase != PH_PA_END ) g->phase = PH_HALF_END;
		return 0;
	case PH_PA_END:
		if ( g->paOver ) off->idx++;
		clearPA(g);
		g->phase = g->outs >= 3 ? PH_HALF_END : PH_PA;
		return 0;
	case PH_HALF_END: {
		if ( off->nline < PD_MAXINN ) off->line[off->nline++] = (int8_t)(off->runs - g->runsBefore);
		off->lob += runnersOn(g);
		clearPA(g);
		if ( g->top ) { g->top = 0; g->phase = PH_HALF; return 0; }
		if ( g->inning >= 9 && g->side[0].runs != g->side[1].runs ) { g->phase = PH_END; return 0; }
		g->inning++;
		if ( g->inning > g->maxInnings ) { g->inning--; g->phase = PH_END; return 0; }
		g->top = 1;
		g->phase = PH_HALF;
		return 0;
	}
	case PH_END:
		endGame(g);
		g->phase = PH_DONE;
		return PAUSE_DONE;
	default:
		return PAUSE_DONE;
	}
}

static int refOfLine(int side, const PdPitLine* l) { return l ? REF(side, l->pl) : -1; }

static void endGame(PdGame* g)
{
	PdSide* h = &g->side[0]; PdSide* a = &g->side[1];
	PdEvent* e = logEv(g, EV_END);
	e->i0 = (int16_t)h->runs; e->i1 = (int16_t)a->runs;
	g->winner = h->runs > a->runs ? 0 : 1;
	PdSide* win = &g->side[g->winner]; PdSide* lose = &g->side[1 - g->winner];
	// game.ts decide(): simplified decisions
	const PdPitLine* w = &win->pit[0];
	if ( w->outs < 15 && win->npit > 1 ) {
		const PdPitLine* best = NULL;
		for ( int i = 1; i < win->npit; i++ ) if ( !best || win->pit[i].outs > best->outs ) best = &win->pit[i];
		if ( best ) w = best;
	}
	const PdPitLine* l = NULL;
	for ( int i = 0; i < lose->npit; i++ ) {
		const PdPitLine* x = &lose->pit[i];
		if ( !l || x->r > l->r || (x->r == l->r && x->er > l->er) ) l = x;
	}
	const PdPitLine* last = &win->pit[win->npit - 1];
	int margin = win->runs - lose->runs;
	g->dw = refOfLine(g->winner, w);
	g->dl = refOfLine(1 - g->winner, l);
	g->ds = (last->pl != w->pl && margin <= 3 && last->outs >= 3) ? REF(g->winner, last->pl) : -1;
	g->done = 1;
}

// --- setup ------------------------------------------------------------------------------------
static int findPl(const PdTeam* t, const char* id)
{
	for ( int i = 0; i < t->np; i++ ) if ( strcmp(t->pl[i].id, id) == 0 ) return i;
	return -1;
}

static void setupSide(PdGame* g, PdSide* s)
{
	PdTeam* t = &s->t;
	for ( int i = 0; i < POS_N; i++ ) s->def[i] = -1;
	uint8_t inPen[PD_MAXP] = { 0 };
	for ( int i = 0; i < t->npen; i++ ) inPen[t->pen[i]] = 1;
	// staff
	int closer, nsetup, nmiddle;
	autoStaff(t, t->npen ? inPen : NULL, s->rotation, &s->nrot, &closer, s->setup, &nsetup, s->middle, &nmiddle);
	if ( t->npen ) {
		s->penIsExplicit = 1;
		s->closer = -1; s->nsetup = 0; s->nmiddle = 0;
		for ( int i = 0; i < t->npen; i++ ) {
			int p = t->pen[i];
			if ( t->penRole[i] == ROLE_CL && s->closer < 0 ) s->closer = p;
			else if ( t->penRole[i] == ROLE_SU ) s->setup[s->nsetup++] = p;
			else s->middle[s->nmiddle++] = p;
		}
	} else {
		s->penIsExplicit = 0;
		s->closer = closer; s->nsetup = nsetup; s->nmiddle = nmiddle;
	}
	int starter = t->starter >= 0 ? t->starter : pickStarter(t, s->rotation, s->nrot);
	if ( starter < 0 ) {   // no pitchers at all: anybody
		for ( int i = 0; i < t->np && starter < 0; i++ ) if ( t->pl[i].hasPitching ) starter = i;
		if ( starter < 0 ) starter = 0;
	}
	// lineup
	if ( t->nlineup == 9 ) {
		for ( int i = 0; i < 9; i++ ) { s->order[i] = t->lineup[i]; s->opos[i] = t->lineupPos[i]; }
	} else {
		uint8_t ex[PD_MAXP] = { 0 };
		int nb = 0, bench[PD_MAXP];
		int n = autoLineup(t, 0, ex, s->order, s->opos, bench, &nb);
		for ( int i = n; i < 9; i++ ) { s->order[i] = starter; s->opos[i] = POS_P; }   // short roster: the pitcher hits
	}
	for ( int i = 0; i < 9; i++ ) {
		if ( s->opos[i] == POS_P ) s->order[i] = starter;
		if ( s->opos[i] != POS_DH && s->opos[i] < POS_N ) s->def[s->opos[i]] = s->order[i];
	}
	// bench
	s->nbench = 0;
	if ( t->benchGiven ) {
		for ( int i = 0; i < t->nbench; i++ ) s->bench[s->nbench++] = t->bench[i];
	} else {
		int rem[PD_MAXP]; float rk[PD_MAXP]; int nr = 0;
		for ( int i = 0; i < t->np; i++ ) {
			const PdPlayer* p = &t->pl[i];
			if ( isPitcherP(p) || !healthy(p) || inList(s->order, 9, i) ) continue;
			rem[nr] = i; rk[nr] = offenseOf(p); nr++;
		}
		sortDesc(rem, rk, nr);
		for ( int i = 0; i < nr; i++ ) s->bench[s->nbench++] = rem[i];
	}
	s->pitcher = starter; s->def[POS_P] = starter;
	s->isStarter = 1; s->enteredOuts = 0; s->plannedOuts = 27;
	memset(s->used, 0, sizeof s->used);
	s->used[starter] = 1;
	for ( int i = 0; i < 9; i++ ) s->used[s->order[i]] = 1;
	s->idx = 0; s->runsAllowedByPitcher = 0; s->outsRecorded = 0;
	memset(s->fatigueLoad, 0, sizeof s->fatigueLoad);
	memset(s->pitches, 0, sizeof s->pitches);
	s->nbat = 0; s->npit = 0;
	for ( int i = 0; i < 9; i++ ) addBatLine(s, s->order[i], s->opos[i]);
	addPitLine(s, starter);
	s->runs = s->hits = s->errors = s->lob = s->dp = 0;
	s->nline = 0;
	(void)g;
}

static void startGame(PdGame* g, const char* seed)
{
	pd_rng_seed(&g->rng, seed);
	setupSide(g, &g->side[0]);
	setupSide(g, &g->side[1]);
	g->phase = PH_START;
	g->inning = 1; g->top = 1;
	g->outs = g->balls = g->strikes = 0;
	memset(g->bases, 0, sizeof g->bases);
	clearPA(g);
	g->pause = PAUSE_NONE; g->done = 0;
	g->dw = g->dl = g->ds = -1;
	g->ninj = 0; g->nev = 0; g->emitted = 0; g->npath = 0; g->nfld = 0;
	g->evFrom = g->evTo = 0;
	if ( g->maxInnings <= 0 || g->maxInnings > PD_MAXINN - 2 ) g->maxInnings = 30;
}

void pd_game_init(PdGame* g, const PdTeam* home, const PdTeam* away, const PdPark* park,
                  const PdWeather* wx, const PdUmp* ump, const char* seed, int logOn)
{
	memset(g, 0, sizeof *g);
	g->side[0].t = *home; g->side[1].t = *away;
	g->park = *park; g->wx = *wx; g->ump = *ump;
	g->logOn = (uint8_t)logOn;
	g->maxInnings = 30;
	startGame(g, seed);
}

// --- stepping ---------------------------------------------------------------------------------
int pd_step(PdGame* g, int maxEvents, int (*timeUp)(void*), void* ud)
{
	g->pause = PAUSE_NONE;
	if ( g->emitted >= g->nev && !g->pendPause ) {
		int start = g->nev;
		for ( ;; ) {
			if ( g->done ) break;
			int p = advance(g);
			if ( p ) { g->pendPause = p; break; }
			if ( maxEvents > 0 && g->nev - start >= maxEvents ) break;
			if ( timeUp && timeUp(ud) ) break;
		}
	}
	g->evFrom = g->emitted;
	g->evTo = maxEvents > 0 && g->nev - g->emitted > maxEvents ? g->emitted + maxEvents : g->nev;
	g->emitted = g->evTo;
	if ( g->emitted < g->nev ) return PAUSE_NONE;   // deliver the rest first; the pause stays pending
	int p = g->pendPause;
	g->pendPause = 0;
	if ( g->done ) p = PAUSE_DONE;
	g->pause = p;
	return p;
}

void pd_run_all(PdGame* g)
{
	for ( int i = 0; i < 200000 && !g->done; i++ ) advance(g);
	g->emitted = g->nev;
}

// --- manager decisions and direct control ----------------------------------------------------
static int fail(PdGame* g, const char* msg) { strncpy(g->err, msg, sizeof g->err - 1); g->err[sizeof g->err - 1] = 0; return -1; }

// "1".."3" → base, else a runner id → his base; 0 if none
static int runnerBase(PdGame* g, const char* a)
{
	if ( !a || !*a ) return 0;
	if ( a[0] >= '1' && a[0] <= '3' && a[1] == 0 ) return g->bases[a[0] - '0'].on ? a[0] - '0' : 0;
	PdSide* off = OFFS(g);
	for ( int b = 1; b <= 3; b++ ) if ( g->bases[b].on && strcmp(off->t.pl[g->bases[b].pl].id, a) == 0 ) return b;
	return 0;
}

static int benchIndex(PdSide* s, const char* id)
{
	for ( int i = 0; i < s->nbench; i++ ) if ( strcmp(s->t.pl[s->bench[i]].id, id) == 0 && !s->used[s->bench[i]] ) return i;
	return -1;
}

static void benchRemove(PdSide* s, int i)
{
	for ( int j = i; j + 1 < s->nbench; j++ ) s->bench[j] = s->bench[j + 1];
	s->nbench--;
}

int pd_decide(PdGame* g, const char* kind, const char* a1, const char* a2)
{
	if ( g->pause != PAUSE_PA && g->pause != PAUSE_PITCH ) return fail(g, "not at a decision point");
	if ( !kind || strcmp(kind, "none") == 0 ) return 0;
	int offSide = g->pauseRole == 0;
	PdSide* off = OFFS(g); PdSide* def = DEFS(g);
	int sk = g->pauseSide;
#define NEED_OFF() if ( !offSide ) return fail(g, "offense only")
#define NEED_DEF() if ( offSide ) return fail(g, "defense only")
	if ( strcmp(kind, "steal") == 0 ) {
		NEED_OFF();
		int b = runnerBase(g, a1);
		if ( !b ) { b = g->bases[2].on && !g->bases[3].on ? 2 : g->bases[1].on && !g->bases[2].on ? 1 : 0; if ( a1 && *a1 ) b = 0; }
		if ( b < 1 || b > 2 ) return fail(g, "no runner who can steal");
		if ( g->bases[b + 1].on ) return fail(g, "the next base is occupied");
		g->ord.steal = (uint8_t)b;
		return 0;
	}
	if ( strcmp(kind, "bunt") == 0 ) { NEED_OFF(); g->ord.bunt = 1; return 0; }
	if ( strcmp(kind, "squeeze") == 0 ) {
		NEED_OFF();
		if ( !g->bases[3].on ) return fail(g, "nobody on third");
		g->ord.squeeze = 1; return 0;
	}
	if ( strcmp(kind, "hitrun") == 0 ) {
		NEED_OFF();
		if ( !g->bases[1].on || g->bases[2].on ) return fail(g, "needs a runner on first and second open");
		g->ord.hitrun = 1; return 0;
	}
	if ( strcmp(kind, "pinch_hit") == 0 ) {
		NEED_OFF();
		if ( g->pause != PAUSE_PA ) return fail(g, "pinch hit before the plate appearance");
		int bi = a1 ? benchIndex(off, a1) : -1;
		if ( bi < 0 ) return fail(g, "not on the bench");
		int slot = off->idx % 9;
		int newp = off->bench[bi], oldp = off->order[slot], pos = off->opos[slot];
		benchRemove(off, bi);
		PdEvent* e = logEv(g, EV_SUB);
		e->a = (uint8_t)sk; e->p0 = (int16_t)REF(sk, oldp); e->p1 = (int16_t)REF(sk, newp); e->b = (uint8_t)pos; e->c = WHY_PH;
		off->order[slot] = newp;
		if ( pos != POS_DH && pos < POS_N ) off->def[pos] = newp;
		if ( pos == POS_P ) off->opos[slot] = POS_DH;   // a pinch hitter for the pitcher bats; the next pitcher comes in for defence
		off->used[newp] = 1;
		addBatLine(off, newp, pos);
		return 0;
	}
	if ( strcmp(kind, "pinch_run") == 0 ) {
		NEED_OFF();
		int bi = a1 ? benchIndex(off, a1) : -1;
		if ( bi < 0 ) return fail(g, "not on the bench");
		int b = runnerBase(g, a2);
		if ( !b ) for ( int x = 3; x >= 1 && !b; x-- ) if ( g->bases[x].on ) b = x;
		if ( !b ) return fail(g, "no runner");
		int newp = off->bench[bi], oldp = g->bases[b].pl;
		benchRemove(off, bi);
		int pos = POS_DH;
		for ( int i = 0; i < 9; i++ ) if ( off->order[i] == oldp ) { pos = off->opos[i]; off->order[i] = newp; }
		if ( pos != POS_DH && pos < POS_N ) off->def[pos] = newp;
		PdEvent* e = logEv(g, EV_SUB);
		e->a = (uint8_t)sk; e->p0 = (int16_t)REF(sk, oldp); e->p1 = (int16_t)REF(sk, newp); e->b = (uint8_t)pos; e->c = WHY_PR;
		g->bases[b].pl = (int16_t)newp;
		logMv(g, newp, b, b);
		off->used[newp] = 1;
		addBatLine(off, newp, pos);
		return 0;
	}
	if ( strcmp(kind, "ibb") == 0 ) { NEED_DEF(); g->ord.ibb = 1; return 0; }
	if ( strcmp(kind, "pitch_change") == 0 ) {
		NEED_DEF();
		int p = a1 ? findPl(&def->t, a1) : -1;
		if ( p < 0 ) return fail(g, "unknown pitcher");
		if ( def->used[p] ) return fail(g, "already used");
		changePitcher(g, def, p, WHY_MANAGER);
		return 0;
	}
	if ( strcmp(kind, "infield_in") == 0 ) { NEED_DEF(); g->ord.infieldIn = 1; buildFielders(g); return 0; }
	if ( strcmp(kind, "shift") == 0 ) { NEED_DEF(); g->ord.shift = 1; buildFielders(g); return 0; }
	if ( strcmp(kind, "pitch_around") == 0 ) { NEED_DEF(); g->ord.pitchAround = 1; return 0; }
#undef NEED_OFF
#undef NEED_DEF
	return fail(g, "unknown decision");
}

void pd_bat_input(PdGame* g, int swing, float timing, float aim, int power)
{
	g->batIn.has = 1; g->batIn.swing = (uint8_t)(swing != 0); g->batIn.power = (uint8_t)(power != 0);
	g->batIn.timing = clampf(timing, -1.f, 1.f); g->batIn.aim = clampf(aim, -3.f, 3.f);
}

static int pitchKindOf(const char* s)
{
	static const char* K[PK_N] = { "FB", "SI", "CT", "SL", "CB", "CH", "SPL", "KN", "SPIT" };
	if ( !s ) return -1;
	for ( int i = 0; i < PK_N; i++ ) if ( strcmp(K[i], s) == 0 ) return i;
	return -1;
}

int pd_pitch_input(PdGame* g, const char* type, float x, float z, float effort)
{
	g->pitchIn.has = 1; g->pitchIn.kind = pitchKindOf(type);
	g->pitchIn.x = clampf(x, -3.f, 3.f); g->pitchIn.z = clampf(z, -3.f, 3.f); g->pitchIn.effort = clampf(effort, 0.f, 1.f);
	return 0;
}

// --- JSON reader (no allocation; walks the text) ------------------------------------------
typedef struct { const char* p; const char* e; int err; } JR;

static void jws(JR* j) { while ( j->p < j->e && (*j->p == ' ' || *j->p == '\t' || *j->p == '\n' || *j->p == '\r') ) j->p++; }
static int jpeek(JR* j) { jws(j); return j->p < j->e ? *j->p : 0; }
static int jeat(JR* j, char c) { if ( jpeek(j) == c ) { j->p++; return 1; } return 0; }

static int jstr(JR* j, char* out, int cap)
{
	int n = 0;
	if ( !jeat(j, '"') ) { j->err = 1; if ( cap ) out[0] = 0; return 0; }
	while ( j->p < j->e && *j->p != '"' ) {
		char c = *j->p++;
		if ( c == '\\' && j->p < j->e ) {
			char x = *j->p++;
			c = x == 'n' ? '\n' : x == 't' ? '\t' : x == 'r' ? '\r' : x == 'b' ? '\b' : x == 'f' ? '\f' : x;
			if ( x == 'u' ) { c = '?'; for ( int k = 0; k < 4 && j->p < j->e; k++ ) j->p++; }
		}
		if ( n < cap - 1 ) out[n++] = c;
	}
	if ( j->p < j->e ) j->p++;
	if ( cap ) out[n] = 0;
	return n;
}

static float jnum(JR* j)
{
	jws(j);
	const char* p = j->p;
	if ( p < j->e && (*p == 't' || *p == 'f' || *p == 'n') ) {   // true/false/null as numbers
		float v = *p == 't' ? 1.f : 0.f;
		while ( p < j->e && *p >= 'a' && *p <= 'z' ) p++;
		j->p = p; return v;
	}
	if ( p < j->e && *p == '"' ) { char b[32]; jstr(j, b, sizeof b); JR k = { b, b + strlen(b), 0 }; return jnum(&k); }
	float sign = 1, v = 0;
	if ( p < j->e && (*p == '-' || *p == '+') ) { if ( *p == '-' ) sign = -1; p++; }
	while ( p < j->e && *p >= '0' && *p <= '9' ) v = v * 10.f + (float)(*p++ - '0');
	if ( p < j->e && *p == '.' ) {
		p++;
		float sc = 0.1f;
		while ( p < j->e && *p >= '0' && *p <= '9' ) { v += sc * (float)(*p++ - '0'); sc *= 0.1f; }
	}
	if ( p < j->e && (*p == 'e' || *p == 'E') ) {
		p++;
		int es = 1, ex = 0;
		if ( p < j->e && (*p == '-' || *p == '+') ) { if ( *p == '-' ) es = -1; p++; }
		while ( p < j->e && *p >= '0' && *p <= '9' ) ex = ex * 10 + (*p++ - '0');
		while ( ex-- > 0 ) v = es > 0 ? v * 10.f : v * 0.1f;
	}
	if ( p == j->p ) { j->err = 1; if ( p < j->e ) p++; }
	j->p = p;
	return sign * v;
}

static void jskip(JR* j)
{
	int c = jpeek(j);
	if ( c == '"' ) { char d[2]; jstr(j, d, 0 * sizeof d); return; }
	if ( c == '{' || c == '[' ) {
		int depth = 0;
		while ( j->p < j->e ) {
			char x = *j->p;
			if ( x == '"' ) { jstr(j, NULL, 0); continue; }
			j->p++;
			if ( x == '{' || x == '[' ) depth++;
			else if ( x == '}' || x == ']' ) { if ( --depth == 0 ) return; }
		}
		return;
	}
	jnum(j);
}

// object iteration: call jobj_begin, then while (jobj_key(j, key)) { value }
static int jcont_begin(JR* j) { int c = jpeek(j); if ( c == '{' || c == '[' ) { j->p++; return c; } j->err = 1; return 0; }
static int jobj_key(JR* j, char* key, int cap)
{
	jeat(j, ',');
	int c = jpeek(j);
	if ( c == '}' || c == ']' || c == 0 ) { if ( c ) j->p++; return 0; }
	if ( c != '"' ) { j->err = 1; return 0; }
	jstr(j, key, cap);
	if ( !jeat(j, ':') ) { j->err = 1; return 0; }
	return 1;
}
// array iteration (also accepts {} for an empty Lua table): while (jarr_next(j)) { value }
static int jarr_next(JR* j)
{
	jeat(j, ',');
	int c = jpeek(j);
	if ( c == ']' || c == '}' || c == 0 ) { if ( c ) j->p++; return 0; }
	return 1;
}
static int jbool(JR* j) { return jnum(j) != 0.f; }

static int posOf(const char* s)
{
	static const char* P[POS_N] = { "P", "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "DH" };
	for ( int i = 0; i < POS_N; i++ ) if ( strcmp(P[i], s) == 0 ) return i;
	return POS_NONE;
}
const char* pd_pos_name(int pos)
{
	static const char* P[POS_N] = { "P", "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "DH" };
	return pos < POS_N ? P[pos] : "";
}

static void playerDefaults(PdPlayer* p)
{
	memset(p, 0, sizeof *p);
	p->bats = 'R'; p->throws = 'R'; p->pos = POS_DH;
	p->contact = p->power = p->eye = p->gap = p->lift = p->pull = p->speed = p->baserunning = 50;
	p->range = p->hands = p->arm = p->accuracy = p->reaction = p->framing = 50;
	for ( int i = 0; i < POS_N; i++ ) p->fam[i] = -1;
	p->stuff = p->control = p->command = p->movement = p->stamina = p->groundball = p->hold = 50;
}

static void parseRatings(JR* j, PdPlayer* p, int which)
{
	char k[24];
	if ( jcont_begin(j) != '{' ) { jskip(j); return; }
	while ( !j->err && jobj_key(j, k, sizeof k) ) {
#define R(name) if ( strcmp(k, #name) == 0 ) { p->name = jnum(j); continue; }
		if ( which == 0 ) {
			R(contact) R(power) R(eye) R(gap) R(lift) R(pull) R(speed) R(baserunning) R(vsL)
		} else if ( which == 1 ) {
			R(range) R(hands) R(arm) R(accuracy) R(reaction) R(framing)
			if ( strcmp(k, "positions") == 0 ) {
				char pk[8];
				if ( jcont_begin(j) == '{' ) {
					while ( !j->err && jobj_key(j, pk, sizeof pk) ) { int ps = posOf(pk); float v = jnum(j); if ( ps < POS_N ) p->fam[ps] = v; }
				} else jskip(j);
				continue;
			}
		} else {
			R(stuff) R(control) R(command) R(movement) R(stamina) R(groundball) R(hold)
			if ( strcmp(k, "pitches") == 0 ) {
				if ( jcont_begin(j) ) {
					while ( !j->err && jarr_next(j) ) {
						PdPitch pt = { PK_FB, 50, 90, 1 };
						char pk[16], kv[16];
						if ( jcont_begin(j) != '{' ) { jskip(j); continue; }
						while ( !j->err && jobj_key(j, pk, sizeof pk) ) {
							if ( strcmp(pk, "kind") == 0 ) { jstr(j, kv, sizeof kv); int x = pitchKindOf(kv); pt.kind = (uint8_t)(x < 0 ? PK_FB : x); }
							else if ( strcmp(pk, "quality") == 0 ) pt.quality = jnum(j);
							else if ( strcmp(pk, "velo") == 0 ) pt.velo = jnum(j);
							else if ( strcmp(pk, "usage") == 0 ) pt.usage = jnum(j);
							else jskip(j);
						}
						if ( p->npitch < PD_MAXPITCH ) p->pitch[p->npitch++] = pt;
					}
				}
				continue;
			}
		}
#undef R
		jskip(j);
	}
}

static void parsePlayer(JR* j, PdPlayer* p)
{
	char k[24], v[PD_IDLEN];
	playerDefaults(p);
	if ( jcont_begin(j) != '{' ) { jskip(j); return; }
	while ( !j->err && jobj_key(j, k, sizeof k) ) {
		if ( strcmp(k, "id") == 0 ) { if ( jpeek(j) == '"' ) jstr(j, p->id, PD_IDLEN); else { int n = (int)jnum(j); char* q = p->id; int d = 1000000; int st = 0; for ( ; d; d /= 10 ) { int x = (n / d) % 10; if ( x || st || d == 1 ) { *q++ = (char)('0' + x); st = 1; } } *q = 0; } }
		else if ( strcmp(k, "bats") == 0 ) { jstr(j, v, sizeof v); p->bats = v[0] ? v[0] : 'R'; }
		else if ( strcmp(k, "throws") == 0 ) { jstr(j, v, sizeof v); p->throws = v[0] ? v[0] : 'R'; }
		else if ( strcmp(k, "pos") == 0 ) { jstr(j, v, sizeof v); int ps = posOf(v); p->pos = (uint8_t)(ps < POS_N ? ps : POS_DH); }
		else if ( strcmp(k, "batting") == 0 ) parseRatings(j, p, 0);
		else if ( strcmp(k, "fielding") == 0 ) parseRatings(j, p, 1);
		else if ( strcmp(k, "pitching") == 0 ) { if ( jpeek(j) == '{' ) { p->hasPitching = 1; parseRatings(j, p, 2); } else jskip(j); }
		else if ( strcmp(k, "mood") == 0 ) p->mood = jnum(j);
		else if ( strcmp(k, "traits") == 0 ) {
			if ( jcont_begin(j) ) while ( !j->err && jarr_next(j) ) {
				char t[24]; if ( jpeek(j) != '"' ) { jskip(j); continue; }
				jstr(j, t, sizeof t);
				if ( !strcmp(t, "CLUTCH") ) p->traits |= TR_CLUTCH;
				else if ( !strcmp(t, "CHOKER") ) p->traits |= TR_CHOKER;
				else if ( !strcmp(t, "SHOWBOAT") ) p->traits |= TR_SHOWBOAT;
				else if ( !strcmp(t, "HOTHEAD") ) p->traits |= TR_HOTHEAD;
				else if ( !strcmp(t, "LAZY") ) p->traits |= TR_LAZY;
			}
		}
		else if ( strcmp(k, "recentPitches") == 0 ) {
			int n = 0;
			if ( jcont_begin(j) ) while ( !j->err && jarr_next(j) ) { float x = jnum(j); if ( n < 5 ) p->recent[n++] = (int16_t)x; }
		}
		else if ( strcmp(k, "injury") == 0 ) {
			if ( jpeek(j) == '{' ) {
				char ik[16]; jcont_begin(j);
				while ( !j->err && jobj_key(j, ik, sizeof ik) ) { if ( strcmp(ik, "daysLeft") == 0 ) p->injuryDays = (int16_t)jnum(j); else jskip(j); }
			} else jskip(j);
		}
		else jskip(j);
	}
	if ( !p->hasPitching ) p->npitch = 0;
}

// a list of player-id strings (or {id=...} tables), resolved after the roster is known
typedef struct { char id[PD_IDLEN]; uint8_t role, pos; } IdRef;
static int parseIdList(JR* j, IdRef* out, int cap, int withRole)
{
	int n = 0;
	if ( !jcont_begin(j) ) return 0;
	while ( !j->err && jarr_next(j) ) {
		IdRef r; memset(&r, 0, sizeof r); r.pos = POS_NONE;
		if ( jpeek(j) == '"' ) jstr(j, r.id, PD_IDLEN);
		else if ( jpeek(j) == '{' ) {
			char k[16], v[16]; jcont_begin(j);
			while ( !j->err && jobj_key(j, k, sizeof k) ) {
				if ( strcmp(k, "id") == 0 ) jstr(j, r.id, PD_IDLEN);
				else if ( strcmp(k, "pos") == 0 ) { jstr(j, v, sizeof v); r.pos = (uint8_t)posOf(v); }
				else if ( strcmp(k, "role") == 0 ) { jstr(j, v, sizeof v); r.role = !strcmp(v, "CL") ? ROLE_CL : !strcmp(v, "SU") ? ROLE_SU : ROLE_MR; }
				else jskip(j);
			}
		} else { jskip(j); continue; }
		(void)withRole;
		if ( n < cap ) out[n++] = r;
	}
	return n;
}

static int parseTeam(JR* j, PdTeam* t, char* err, int errlen)
{
	char k[24];
	IdRef lineup[12], bench[PD_MAXP], pen[PD_MAXP];
	int nl = 0, nb = 0, npn = 0, benchGiven = 0;
	char starter[PD_IDLEN] = { 0 };
	memset(t, 0, sizeof *t);
	t->starter = -1;
	if ( jcont_begin(j) != '{' ) { strncpy(err, "team: expected an object", (size_t)errlen); return -1; }
	while ( !j->err && jobj_key(j, k, sizeof k) ) {
		if ( strcmp(k, "id") == 0 ) jstr(j, t->id, PD_IDLEN);
		else if ( strcmp(k, "abbr") == 0 ) jstr(j, t->abbr, sizeof t->abbr);
		else if ( strcmp(k, "players") == 0 ) {
			if ( jcont_begin(j) ) while ( !j->err && jarr_next(j) ) {
				if ( t->np < PD_MAXP ) parsePlayer(j, &t->pl[t->np++]); else jskip(j);
			}
		}
		else if ( strcmp(k, "lineup") == 0 ) nl = parseIdList(j, lineup, 12, 0);
		else if ( strcmp(k, "bench") == 0 ) { nb = parseIdList(j, bench, PD_MAXP, 0); benchGiven = 1; }
		else if ( strcmp(k, "bullpen") == 0 ) npn = parseIdList(j, pen, PD_MAXP, 1);
		else if ( strcmp(k, "starter") == 0 ) { if ( jpeek(j) == '"' ) jstr(j, starter, PD_IDLEN); else jskip(j); }
		else if ( strcmp(k, "control") == 0 ) {
			char ck[16];
			if ( jcont_begin(j) == '{' ) while ( !j->err && jobj_key(j, ck, sizeof ck) ) {
				if ( !strcmp(ck, "manage") ) t->manage = (uint8_t)jbool(j);
				else if ( !strcmp(ck, "perPitch") ) t->perPitch = (uint8_t)jbool(j);
				else if ( !strcmp(ck, "bat") ) t->bat = (uint8_t)jbool(j);
				else if ( !strcmp(ck, "pitch") ) t->pitch = (uint8_t)jbool(j);
				else jskip(j);
			}
		}
		else jskip(j);
	}
	if ( j->err ) { strncpy(err, "team: bad JSON", (size_t)errlen); return -1; }
	if ( t->np == 0 ) { strncpy(err, "team: no players", (size_t)errlen); return -1; }
	if ( t->perPitch ) t->manage = 1;
	if ( nl == 9 ) {
		for ( int i = 0; i < 9; i++ ) {
			int p = findPl(t, lineup[i].id);
			if ( p < 0 ) { strncpy(err, "lineup: unknown player id", (size_t)errlen); return -1; }
			t->lineup[i] = p;
			t->lineupPos[i] = lineup[i].pos < POS_N ? lineup[i].pos : t->pl[p].pos;
		}
		t->nlineup = 9;
	} else if ( nl ) { strncpy(err, "lineup: needs 9 slots", (size_t)errlen); return -1; }
	if ( benchGiven ) {
		t->benchGiven = 1;
		for ( int i = 0; i < nb; i++ ) { int p = findPl(t, bench[i].id); if ( p >= 0 ) t->bench[t->nbench++] = p; }
	}
	for ( int i = 0; i < npn; i++ ) {
		int p = findPl(t, pen[i].id);
		if ( p < 0 ) continue;
		t->pen[t->npen] = p; t->penRole[t->npen] = pen[i].role ? pen[i].role : ROLE_MR; t->npen++;
	}
	if ( starter[0] ) {
		t->starter = findPl(t, starter);
		if ( t->starter < 0 ) { strncpy(err, "starter: unknown player id", (size_t)errlen); return -1; }
	}
	return 0;
}

int pd_team_from_json(PdTeam* t, const char* json, size_t len, char* err, int errlen)
{
	JR j = { json, json + len, 0 };
	return parseTeam(&j, t, err, errlen);
}

static void parseNums(JR* j, float* out, int n)
{
	int i = 0;
	if ( !jcont_begin(j) ) return;
	while ( !j->err && jarr_next(j) ) { float v = jnum(j); if ( i < n ) out[i++] = v; }
}

int pd_game_from_json(PdGame* g, const char* json, size_t len, int logDefault)
{
	memset(g, 0, sizeof *g);
	JR j = { json, json + len, 0 };
	char k[24], seed[128] = "pdsim";
	int haveHome = 0, haveAway = 0;
	static const float F0[5] = { 330, 375, 400, 375, 330 };
	for ( int i = 0; i < 5; i++ ) { g->park.fences[i] = F0[i]; g->park.walls[i] = 10; }
	g->park.altitudeFt = 0; g->park.foulTerritory = 50; g->park.turf = 0;
	g->wx.tempF = 72; g->wx.windDir = 0; g->wx.windMph = 0;
	g->ump.zoneWidth = 50; g->ump.consistency = 50;
	g->logOn = (uint8_t)logDefault;
	g->maxInnings = 30;
	if ( jcont_begin(&j) != '{' ) return fail(g, "spec: expected an object");
	while ( !j.err && jobj_key(&j, k, sizeof k) ) {
		if ( strcmp(k, "home") == 0 ) { if ( parseTeam(&j, &g->side[0].t, g->err, sizeof g->err) ) return -1; haveHome = 1; }
		else if ( strcmp(k, "away") == 0 ) { if ( parseTeam(&j, &g->side[1].t, g->err, sizeof g->err) ) return -1; haveAway = 1; }
		else if ( strcmp(k, "seed") == 0 ) { if ( jpeek(&j) == '"' ) jstr(&j, seed, sizeof seed); else jskip(&j); }
		else if ( strcmp(k, "log") == 0 ) g->logOn = (uint8_t)jbool(&j);
		else if ( strcmp(k, "maxInnings") == 0 ) g->maxInnings = (int)jnum(&j);
		else if ( strcmp(k, "park") == 0 ) {
			char pk[24];
			if ( jcont_begin(&j) == '{' ) while ( !j.err && jobj_key(&j, pk, sizeof pk) ) {
				if ( !strcmp(pk, "fences") ) parseNums(&j, g->park.fences, 5);
				else if ( !strcmp(pk, "walls") ) parseNums(&j, g->park.walls, 5);
				else if ( !strcmp(pk, "altitudeFt") ) g->park.altitudeFt = jnum(&j);
				else if ( !strcmp(pk, "foulTerritory") ) g->park.foulTerritory = jnum(&j);
				else if ( !strcmp(pk, "turf") ) g->park.turf = (uint8_t)jbool(&j);
				else jskip(&j);
			}
		}
		else if ( strcmp(k, "weather") == 0 ) {
			char wk[24];
			if ( jcont_begin(&j) == '{' ) while ( !j.err && jobj_key(&j, wk, sizeof wk) ) {
				if ( !strcmp(wk, "tempF") ) g->wx.tempF = jnum(&j);
				else if ( !strcmp(wk, "windDir") ) g->wx.windDir = jnum(&j);
				else if ( !strcmp(wk, "windMph") ) g->wx.windMph = jnum(&j);
				else jskip(&j);
			}
		}
		else if ( strcmp(k, "umpire") == 0 ) {
			char uk[24];
			if ( jcont_begin(&j) == '{' ) while ( !j.err && jobj_key(&j, uk, sizeof uk) ) {
				if ( !strcmp(uk, "zoneWidth") ) g->ump.zoneWidth = jnum(&j);
				else if ( !strcmp(uk, "consistency") ) g->ump.consistency = jnum(&j);
				else jskip(&j);
			}
		}
		else jskip(&j);
	}
	if ( j.err ) return fail(g, "spec: bad JSON");
	if ( !haveHome || !haveAway ) return fail(g, "spec: needs home and away");
	startGame(g, seed);
	return 0;
}

// --- output ------------------------------------------------------------------------------------
typedef struct { char* b; int n, cap; } SB;
static void sbc(SB* s, char c) { if ( s->n < s->cap - 1 ) s->b[s->n++] = c; }
static void sbs(SB* s, const char* t) { while ( *t ) sbc(s, *t++); }
static void sbi(SB* s, int v)
{
	char t[12]; int n = 0;
	unsigned u = v < 0 ? (unsigned)(-(long)v) : (unsigned)v;
	if ( v < 0 ) sbc(s, '-');
	do { t[n++] = (char)('0' + u % 10); u /= 10; } while ( u );
	while ( n ) sbc(s, t[--n]);
}
static void sbf(SB* s, float v, int dec)
{
	if ( v != v ) { sbs(s, "0"); return; }
	int mul = 1; for ( int i = 0; i < dec; i++ ) mul *= 10;
	long x = (long)floorf(fabsf(v) * (float)mul + 0.5f);
	if ( v < 0 && x ) sbc(s, '-');
	sbi(s, (int)(x / mul));
	if ( dec ) {
		long fr = x % mul;
		if ( fr ) {
			sbc(s, '.');
			char t[8]; for ( int i = dec - 1; i >= 0; i-- ) { t[i] = (char)('0' + fr % 10); fr /= 10; }
			int n = dec; while ( n > 1 && t[n - 1] == '0' ) n--;
			for ( int i = 0; i < n; i++ ) sbc(s, t[i]);
		}
	}
}
static void sbq(SB* s, const char* t)
{
	sbc(s, '"');
	for ( ; *t; t++ ) {
		if ( *t == '"' || *t == '\\' ) { sbc(s, '\\'); sbc(s, *t); }
		else if ( (unsigned char)*t < 32 ) sbc(s, ' ');
		else sbc(s, *t);
	}
	sbc(s, '"');
}
static int sbend(SB* s) { if ( s->cap > 0 ) s->b[s->n < s->cap ? s->n : s->cap - 1] = 0; return s->n; }

const char* pd_player_id(const PdGame* g, int ref)
{
	if ( ref < 0 ) return "";
	int side = (ref >> 8) & 1, pl = ref & 0xff;
	return g->side[side].t.pl[pl].id;
}

static const char* PK_NAME[PK_N] = { "FB", "SI", "CT", "SL", "CB", "CH", "SPL", "KN", "SPIT" };
static const char* BIP_NAME[] = { "HR", "1B", "2B", "3B", "OUT", "DP", "FC", "ROE", "FOUL", "FOUL_OUT", "SF" };
static const char* OT_NAME[] = { "", "GO", "FO", "LO", "PO", "DP", "FC" };
static const char* WHY_NAME[WHY_N] = { "save situation", "setup", "shelled", "tired", "matchup", "manager", "pinch hit", "pinch run" };
static const char* EV_NAME[] = { "half", "pa", "p", "bip", "mv", "sb", "wp", "sub", "end" };

// one event, as JSON (compact = 0) or BallCast's compact line (compact = 1)
typedef struct { SB* s; int compact; int first; } EW;
static void ewKey(EW* w, const char* k)
{
	if ( w->compact ) { sbc(w->s, '\t'); sbs(w->s, k); sbc(w->s, '='); }
	else { sbc(w->s, ','); sbq(w->s, k); sbc(w->s, ':'); }
}
static void ewInt(EW* w, const char* k, int v) { ewKey(w, k); sbi(w->s, v); }
static void ewNum(EW* w, const char* k, float v) { ewKey(w, k); sbf(w->s, v, 2); }
static void ewBool(EW* w, const char* k, int v) { ewKey(w, k); sbs(w->s, w->compact ? (v ? "!1" : "!0") : (v ? "true" : "false")); }
static void ewStr(EW* w, const char* k, const char* v)
{
	ewKey(w, k);
	if ( !w->compact ) { sbq(w->s, v); return; }
	if ( !*v || strchr("!#@'()*+,-./0123456789", *v) ) sbc(w->s, '\'');
	for ( ; *v; v++ ) sbc(w->s, (*v == '\t' || *v == '\n' || *v == '\r') ? ' ' : *v);
}

static void writeEvent(PdGame* g, const PdEvent* e, SB* s, int compact)
{
	EW w = { s, compact, 1 };
	if ( compact ) sbs(s, EV_NAME[e->k]);
	else { sbs(s, "{\"k\":"); sbq(s, EV_NAME[e->k]); }
	switch ( e->k ) {
	case EV_HALF: ewInt(&w, "inn", e->i0); ewBool(&w, "top", e->a); break;
	case EV_PA: ewStr(&w, "bat", pd_player_id(g, e->p0)); ewStr(&w, "pit", pd_player_id(g, e->p1)); break;
	case EV_P: {
		char r[2] = { (char)e->c, 0 };
		ewStr(&w, "t", PK_NAME[e->a < PK_N ? e->a : 0]); ewInt(&w, "v", e->i0); ewInt(&w, "z", e->b); ewStr(&w, "r", r);
		ewInt(&w, "b", e->d); ewInt(&w, "s", e->e);
		ewNum(&w, "px", (float)e->i1 / 100.f); ewNum(&w, "pz", (float)e->i2 / 100.f);
		if ( e->i3 & 1 ) ewBool(&w, "ibb", 1);
		if ( e->i3 & 2 ) ewBool(&w, "bunt", 1);
		break;
	}
	case EV_BIP:
		ewInt(&w, "ev", e->i0); ewInt(&w, "la", e->i1); ewInt(&w, "sp", e->i2); ewStr(&w, "res", BIP_NAME[e->a]);
		if ( e->b < POS_N ) ewStr(&w, "f", pd_pos_name(e->b));
		if ( e->c ) ewStr(&w, "out", OT_NAME[e->c]);
		if ( e->d ) ewBool(&w, "bunt", 1);
		if ( e->pathN ) {
			const int16_t* p = &g->path[e->pathOff * 3];
			ewKey(&w, "path");
			sbc(s, compact ? '#' : '[');
			for ( int i = 0; i < e->pathN * 3; i++ ) { if ( i ) sbc(s, ','); sbi(s, p[i]); }
			if ( !compact ) sbc(s, ']');
		}
		break;
	case EV_MV: ewStr(&w, "id", pd_player_id(g, e->p0)); ewInt(&w, "from", e->a); ewInt(&w, "to", e->b); break;
	case EV_SB: ewStr(&w, "id", pd_player_id(g, e->p0)); ewInt(&w, "base", e->a); ewBool(&w, "ok", e->b); break;
	case EV_WP: ewBool(&w, "pb", e->a); break;
	case EV_SUB:
		ewStr(&w, "side", e->a ? "away" : "home"); ewStr(&w, "out", pd_player_id(g, e->p0)); ewStr(&w, "in", pd_player_id(g, e->p1));
		ewStr(&w, "pos", pd_pos_name(e->b)); ewStr(&w, "why", WHY_NAME[e->c < WHY_N ? e->c : 0]);
		break;
	case EV_END: ewInt(&w, "home", e->i0); ewInt(&w, "away", e->i1); break;
	}
	if ( !compact ) sbc(s, '}');
}

int pd_events_json(PdGame* g, int from, int to, char* buf, int cap)
{
	SB s = { buf, 0, cap };
	if ( to > g->nev ) to = g->nev;
	sbc(&s, '[');
	for ( int i = from; i < to; i++ ) { if ( i > from ) sbc(&s, ','); writeEvent(g, &g->ev[i], &s, 0); }
	sbc(&s, ']');
	return sbend(&s);
}

int pd_logc(PdGame* g, int from, char* buf, int cap)
{
	SB s = { buf, 0, cap };
	for ( int i = from; i < g->nev; i++ ) { if ( i > from ) sbc(&s, '\n'); writeEvent(g, &g->ev[i], &s, 1); }
	return sbend(&s);
}

static void writeTeamBox(PdGame* g, int sk, SB* s)
{
	PdSide* t = &g->side[sk];
	sbs(s, "{\"teamId\":"); sbq(s, t->t.id);
	sbs(s, ",\"runs\":"); sbi(s, t->runs); sbs(s, ",\"hits\":"); sbi(s, t->hits);
	sbs(s, ",\"errors\":"); sbi(s, t->errors); sbs(s, ",\"lob\":"); sbi(s, t->lob);
	sbs(s, ",\"dp\":"); sbi(s, t->dp);
	sbs(s, ",\"line\":[");
	for ( int i = 0; i < t->nline; i++ ) { if ( i ) sbc(s, ','); sbi(s, t->line[i]); }
	sbs(s, "],\"bat\":[");
	for ( int i = 0; i < t->nbat; i++ ) {
		const PdBatLine* l = &t->bat[i];
		if ( i ) sbc(s, ',');
		sbs(s, "{\"id\":"); sbq(s, t->t.pl[l->pl].id); sbs(s, ",\"pos\":"); sbq(s, pd_pos_name(l->pos));
#define F(n) sbs(s, ",\"" #n "\":"); sbi(s, l->n);
		F(ab) F(r) F(h) F(d) F(t) F(hr) F(rbi) F(bb) F(k) F(sb) F(cs) F(hbp) F(sf) F(sh)
		sbc(s, '}');
	}
	sbs(s, "],\"pitch\":[");
	for ( int i = 0; i < t->npit; i++ ) {
		const PdPitLine* l = &t->pit[i];
		if ( i ) sbc(s, ',');
		sbs(s, "{\"id\":"); sbq(s, t->t.pl[l->pl].id);
		F(outs) F(h) F(r) F(er) F(bb) F(k) F(hr) F(hbp) F(pitches) F(bf)
#undef F
		sbc(s, '}');
	}
	sbs(s, "]}");
}

int pd_box_json(PdGame* g, char* buf, int cap)
{
	SB s = { buf, 0, cap };
	sbs(&s, "{\"final\":"); sbs(&s, g->done ? "true" : "false");
	sbs(&s, ",\"innings\":"); sbi(&s, g->inning);
	if ( g->done ) { sbs(&s, ",\"winner\":"); sbq(&s, g->winner ? "away" : "home"); }
	sbs(&s, ",\"home\":"); writeTeamBox(g, 0, &s);
	sbs(&s, ",\"away\":"); writeTeamBox(g, 1, &s);
	sbs(&s, ",\"dp\":"); sbi(&s, g->side[0].dp + g->side[1].dp);
	if ( g->done ) {
		sbs(&s, ",\"decisions\":{\"w\":"); sbq(&s, pd_player_id(g, g->dw)); sbs(&s, ",\"l\":"); sbq(&s, pd_player_id(g, g->dl));
		if ( g->ds >= 0 ) { sbs(&s, ",\"s\":"); sbq(&s, pd_player_id(g, g->ds)); }
		sbc(&s, '}');
	}
	sbs(&s, ",\"pitchCounts\":{");
	int first = 1;
	for ( int sk = 0; sk < 2; sk++ ) {
		PdSide* t = &g->side[sk];
		for ( int i = 0; i < t->t.np; i++ ) if ( t->pitches[i] > 0 ) {
			if ( !first ) sbc(&s, ',');
			first = 0;
			sbq(&s, t->t.pl[i].id); sbc(&s, ':'); sbi(&s, t->pitches[i]);
		}
	}
	sbs(&s, "},\"injuries\":[");
	for ( int i = 0; i < g->ninj; i++ ) {
		if ( i ) sbc(&s, ',');
		sbs(&s, "{\"id\":"); sbq(&s, g->side[g->inj[i].side].t.pl[g->inj[i].pl].id);
		sbs(&s, ",\"kind\":"); sbq(&s, INJ_KIND[g->inj[i].kind & 3]); sbs(&s, ",\"days\":"); sbi(&s, g->inj[i].days); sbc(&s, '}');
	}
	sbs(&s, "]}");
	return sbend(&s);
}

static void writeInfo(PdGame* g, SB* s)
{
	PdSide* off = OFFS(g); PdSide* def = DEFS(g);
	int b = curBatter(off);
	const PdPlayer* B = &off->t.pl[b];
	const PdPlayer* P = &def->t.pl[def->pitcher];
	sbs(s, "{\"inn\":"); sbi(s, g->inning); sbs(s, ",\"top\":"); sbs(s, g->top ? "true" : "false");
	sbs(s, ",\"outs\":"); sbi(s, g->outs); sbs(s, ",\"balls\":"); sbi(s, g->balls); sbs(s, ",\"strikes\":"); sbi(s, g->strikes);
	sbs(s, ",\"score\":{\"home\":"); sbi(s, g->side[0].runs); sbs(s, ",\"away\":"); sbi(s, g->side[1].runs); sbc(s, '}');
	sbs(s, ",\"bases\":[");
	for ( int i = 1; i <= 3; i++ ) { if ( i > 1 ) sbc(s, ','); if ( g->bases[i].on ) sbq(s, off->t.pl[g->bases[i].pl].id); else sbs(s, "false"); }
	sbs(s, "],\"batter\":{\"id\":"); sbq(s, B->id);
	char bh[2] = { B->bats, 0 }; sbs(s, ",\"bats\":"); sbq(s, bh);
	sbs(s, ",\"slot\":"); sbi(s, off->idx % 9 + 1); sbs(s, ",\"pos\":"); sbq(s, pd_pos_name(off->opos[off->idx % 9]));
	const PdBatLine* bl = batLine(off, b);
	sbs(s, ",\"today\":{\"ab\":"); sbi(s, bl ? bl->ab : 0); sbs(s, ",\"h\":"); sbi(s, bl ? bl->h : 0);
	sbs(s, ",\"hr\":"); sbi(s, bl ? bl->hr : 0); sbs(s, ",\"bb\":"); sbi(s, bl ? bl->bb : 0); sbs(s, ",\"k\":"); sbi(s, bl ? bl->k : 0); sbs(s, "}}");
	sbs(s, ",\"onDeck\":"); sbq(s, off->t.pl[off->order[(off->idx + 1) % 9]].id);
	sbs(s, ",\"pitcher\":{\"id\":"); sbq(s, P->id);
	char th[2] = { P->throws, 0 }; sbs(s, ",\"throws\":"); sbq(s, th);
	sbs(s, ",\"pitches\":"); sbi(s, def->pitches[def->pitcher]);
	sbs(s, ",\"cap\":"); sbi(s, jsround(pitchCap(P)));
	sbs(s, ",\"fatigue\":"); sbf(s, fatigueOf(def), 3);
	const PdPitLine* pl = pitLine(def, def->pitcher);
	sbs(s, ",\"today\":{\"outs\":"); sbi(s, pl ? pl->outs : 0); sbs(s, ",\"h\":"); sbi(s, pl ? pl->h : 0);
	sbs(s, ",\"r\":"); sbi(s, pl ? pl->r : 0); sbs(s, ",\"er\":"); sbi(s, pl ? pl->er : 0);
	sbs(s, ",\"bb\":"); sbi(s, pl ? pl->bb : 0); sbs(s, ",\"k\":"); sbi(s, pl ? pl->k : 0); sbs(s, "}}");
	char es[2] = { effSide(B, P->throws), 0 };
	sbs(s, ",\"matchup\":{\"platoon\":"); sbf(s, platoonAdj(B, P), 2); sbs(s, ",\"batterSide\":"); sbq(s, es); sbc(s, '}');
	sbs(s, ",\"bench\":[");
	int f = 1;
	for ( int i = 0; i < off->nbench; i++ ) if ( !off->used[off->bench[i]] ) { if ( !f ) sbc(s, ','); f = 0; sbq(s, off->t.pl[off->bench[i]].id); }
	sbs(s, "],\"pen\":[");
	int pen[PD_MAXP * 2]; int np = availablePen(def, pen);
	f = 1;
	for ( int i = 0; i < np; i++ ) {
		int p = pen[i];
		if ( !f ) sbc(s, ',');
		f = 0;
		sbs(s, "{\"id\":"); sbq(s, def->t.pl[p].id);
		sbs(s, ",\"role\":"); sbq(s, p == def->closer ? "CL" : inList(def->setup, def->nsetup, p) ? "SU" : inList(def->rotation, def->nrot, p) ? "SP" : "MR");
		sbs(s, ",\"ready\":true}");
	}
	// other unused pitchers (tired ones): a human may still use them
	for ( int i = 0; i < def->t.np; i++ ) {
		const PdPlayer* p = &def->t.pl[i];
		if ( !p->hasPitching || def->used[i] || inList(pen, np, i) || !healthy(p) ) continue;
		if ( !f ) sbc(s, ',');
		f = 0;
		sbs(s, "{\"id\":"); sbq(s, p->id); sbs(s, ",\"role\":"); sbq(s, inList(def->rotation, def->nrot, i) ? "SP" : "MR"); sbs(s, ",\"ready\":false}");
	}
	sbs(s, "],\"orders\":{\"bunt\":"); sbs(s, g->ord.bunt ? "true" : "false");
	sbs(s, ",\"hitrun\":"); sbs(s, g->ord.hitrun ? "true" : "false");
	sbs(s, ",\"squeeze\":"); sbs(s, g->ord.squeeze ? "true" : "false");
	sbs(s, ",\"steal\":"); sbi(s, g->ord.steal);
	sbs(s, ",\"infieldIn\":"); sbs(s, g->ord.infieldIn ? "true" : "false");
	sbs(s, ",\"shift\":"); sbs(s, g->ord.shift ? "true" : "false");
	sbs(s, ",\"pitchAround\":"); sbs(s, g->ord.pitchAround ? "true" : "false");
	sbs(s, ",\"ibb\":"); sbs(s, g->ord.ibb ? "true" : "false"); sbc(s, '}');
	sbs(s, ",\"arsenal\":[");
	for ( int i = 0; i < P->npitch; i++ ) {
		if ( i ) sbc(s, ',');
		sbs(s, "{\"kind\":"); sbq(s, PK_NAME[P->pitch[i].kind]); sbs(s, ",\"velo\":"); sbi(s, jsround(P->pitch[i].velo));
		sbs(s, ",\"quality\":"); sbi(s, jsround(P->pitch[i].quality)); sbc(s, '}');
	}
	sbs(s, "]}");
}

int pd_info_json(PdGame* g, char* buf, int cap)
{
	SB s = { buf, 0, cap };
	writeInfo(g, &s);
	return sbend(&s);
}

int pd_pause_json(PdGame* g, char* buf, int cap)
{
	static const char* REASON[] = { "", "pa", "pitch", "pitchsel", "bat", "done" };
	SB s = { buf, 0, cap };
	if ( g->pause == PAUSE_NONE ) { sbs(&s, "null"); return sbend(&s); }
	sbs(&s, "{\"reason\":"); sbq(&s, REASON[g->pause]);
	if ( g->pause != PAUSE_DONE ) {
		sbs(&s, ",\"side\":"); sbq(&s, g->pauseSide ? "away" : "home");
		sbs(&s, ",\"role\":"); sbq(&s, g->pauseRole ? "def" : "off");
		if ( g->pause == PAUSE_BAT ) {
			sbs(&s, ",\"pitch\":{\"t\":"); sbq(&s, PK_NAME[g->pk]); sbs(&s, ",\"v\":"); sbi(&s, (int)g->velo);
			sbs(&s, ",\"px\":"); sbf(&s, g->px, 2); sbs(&s, ",\"pz\":"); sbf(&s, g->pz, 2);
			sbs(&s, ",\"zone\":"); sbi(&s, g->zone); sbc(&s, '}');
		}
		sbs(&s, ",\"info\":"); writeInfo(g, &s);
	}
	sbc(&s, '}');
	return sbend(&s);
}

int pd_auto_lineup_json(const PdTeam* t, int vsThrows, char* buf, int cap)
{
	SB s = { buf, 0, cap };
	int order[9]; uint8_t opos[9]; int bench[PD_MAXP], nb = 0;
	int n = autoLineup(t, vsThrows, NULL, order, opos, bench, &nb);
	int rot[5], nrot, closer, setup[PD_MAXP], ns, middle[PD_MAXP], nm;
	autoStaff(t, NULL, rot, &nrot, &closer, setup, &ns, middle, &nm);
	int st = pickStarter(t, rot, nrot);
	sbs(&s, "{\"lineup\":[");
	for ( int i = 0; i < n; i++ ) { if ( i ) sbc(&s, ','); sbs(&s, "{\"id\":"); sbq(&s, t->pl[order[i]].id); sbs(&s, ",\"pos\":"); sbq(&s, pd_pos_name(opos[i])); sbc(&s, '}'); }
	sbs(&s, "],\"bench\":[");
	for ( int i = 0; i < nb; i++ ) { if ( i ) sbc(&s, ','); sbq(&s, t->pl[bench[i]].id); }
	sbs(&s, "],\"starter\":");
	if ( st >= 0 ) sbq(&s, t->pl[st].id); else sbs(&s, "null");
	sbs(&s, ",\"rotation\":[");
	for ( int i = 0; i < nrot; i++ ) { if ( i ) sbc(&s, ','); sbq(&s, t->pl[rot[i]].id); }
	sbs(&s, "],\"bullpen\":[");
	int f = 1;
	if ( closer >= 0 ) { sbs(&s, "{\"id\":"); sbq(&s, t->pl[closer].id); sbs(&s, ",\"role\":\"CL\"}"); f = 0; }
	for ( int i = 0; i < ns; i++ ) { if ( !f ) sbc(&s, ','); f = 0; sbs(&s, "{\"id\":"); sbq(&s, t->pl[setup[i]].id); sbs(&s, ",\"role\":\"SU\"}"); }
	for ( int i = 0; i < nm; i++ ) { if ( !f ) sbc(&s, ','); f = 0; sbs(&s, "{\"id\":"); sbq(&s, t->pl[middle[i]].id); sbs(&s, ",\"role\":\"MR\"}"); }
	sbs(&s, "]}");
	return sbend(&s);
}
