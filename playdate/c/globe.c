//
// globe.c — the Pennant road map's planet (C extension for the DEADBALL Playdate client).
//
// A flat-shaded low-poly sphere seen orthographically: 15-degree lat/lon quads, each split into two
// flat facets (A = a,b,c lower-right; B = a,c,d upper-left). Every facet takes one 4x4 Bayer level
// (9 levels) from its centroid normal against a light dead-on from the view centre, so the faces
// under the pointer are brightest and the rim falls dark; a quad with a corner behind the limb is
// skipped (the dark disc behind shows through). Land is baked (tools/bake_globe.py →
// pennant/globedata.lua) as polygons in facet coordinates, so it lies flat on its facet at the facet's
// light, plus 1-px coast segments cut with marching triangles. Only the rotation and the lighting
// run per frame.
//
// Lua API (global table `globe`; pennant/globe.lua is the Lua side):
//   globe.load(bytes) → true | nil, err      the baked bytes (PGlobeData)
//   globe.render(lat0, lon0, cx, cy, R [, x0, y0, x1, y1])
//                                            draw it centred on lat0/lon0 (deg) at (cx, cy) with
//                                            radius R px, clipped to [x0, x1) x [y0, y1)
//   globe.leg(mode, ax, ay, az, bx, by, bz, frac, lift, w, pat)
//                                            a road-trip leg with the last render's view (see there)
//   globe.ms() → ms of the last render, ms of its coasts, polygons, rows, px filled
//

#include <math.h>
#include <string.h>
#include <stdlib.h>
#include "pd_api.h"
#include "globe.h"

static PlaydateAPI* pd = NULL;

#define NJ 12               // quad rows (lat -90..90 by 15)
#define NI 24               // quad columns (lon -180..180 by 15)
#define NQ (NJ * NI)
#define QS 240.0f           // facet coordinate resolution (bake_globe.py Q)
#define MAXV 8

typedef struct { float x, y, z; } V3;

typedef struct {
	uint16_t quad;
	uint8_t kind, n, facet;
	uint8_t u[MAXV], v[MAXV];
} Piece;

typedef struct { uint16_t quad; uint8_t u1, v1, u2, v2; } Seg;

static V3 corner[NJ + 1][NI];             // unit vectors of the grid points
static float invA[NQ], invB[NQ];          // 1 / |a+b+c|, 1 / |a+c+d|: centroid normal scale
static uint8_t facetCode[NQ][2];
static Piece* pieces = NULL;
static int npieces = 0;
static int pieceStart[NQ + 1];
static Seg* segs = NULL;
static int nsegs = 0;
static int loaded = 0;
static float lastMs = 0, lastCoastMs = 0;
static int statRows = 0, statPx = 0, statPolys = 0;     // fill work counters
static int lastRows = 0, lastPx = 0, lastPolys = 0;     // the last render's (globe.ms)

// 9 Bayer levels, 0 = white .. 8 = black (row bytes, bit = 1 → white)
static uint8_t level[9][4];
// 0 sea, 1 grassland, 2 desert (a step lighter), 3 ice (unused), 4 forest (a step darker)
static const float BASE[5] = { 0.06f, 0.30f, 0.42f, 0.52f, 0.18f };
static const float GAIN[5] = { 0.62f, 0.75f, 0.75f, 0.70f, 0.75f };

static void buildLevels(void)
{
	static const int bayer[4][4] = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } };
	for ( int l = 0; l <= 8; l++ )
		for ( int y = 0; y < 4; y++ )
		{
			uint8_t b = 0;
			for ( int x = 0; x < 8; x++ )
				if ( bayer[y][x & 3] >= 2 * l ) b |= (uint8_t)(0x80 >> x);
			level[l][y] = b;
		}
}

static inline int levelFor(float lit, int k)
{
	float bright = BASE[k] + GAIN[k] * lit;
	int l = (int)floorf((1.0f - bright) * 8.0f + 0.5f);
	return l < 0 ? 0 : (l > 8 ? 8 : l);
}

// ---------------------------------------------------------------------------
// frame buffer fills (bit = 1 → white)

static uint8_t* fb = NULL;
static int clipX0 = 0, clipY0 = 0, clipX1 = LCD_COLUMNS, clipY1 = LCD_ROWS;
static int andMode = 0;     // 1: the pattern only darkens (shadows)

static inline void span(int y, int x0, int x1, const uint8_t* pat)
{
	if ( x0 < clipX0 ) x0 = clipX0;
	if ( x1 > clipX1 ) x1 = clipX1;
	if ( x1 <= x0 ) return;
	statRows++;
	statPx += x1 - x0;
	uint8_t* row = fb + y * LCD_ROWSIZE;
	uint8_t p = pat[y & 3];
	int b0 = x0 >> 3, b1 = (x1 - 1) >> 3;
	uint8_t lm = (uint8_t)(0xFF >> (x0 & 7));
	uint8_t rm = (uint8_t)(0xFF << (7 - ((x1 - 1) & 7)));
	if ( andMode )
	{
		for ( int b = b0; b <= b1; b++ )
		{
			uint8_t m = 0xFF;
			if ( b == b0 ) m &= lm;
			if ( b == b1 ) m &= rm;
			row[b] &= (uint8_t)(p | ~m);
		}
		return;
	}
	if ( b0 == b1 )
	{
		uint8_t m = lm & rm;
		row[b0] = (row[b0] & ~m) | (p & m);
		return;
	}
	row[b0] = (row[b0] & ~lm) | (p & lm);
	if ( b1 - b0 > 1 ) memset(row + b0 + 1, p, (size_t)(b1 - b0 - 1));
	row[b1] = (row[b1] & ~rm) | (p & rm);
}

// scanline fill of a convex polygon (pixel centres, top-left rule: shared edges neither gap nor
// overlap). Each edge is walked once into per-row left/right bounds (one divide an edge, an add a
// row), then the rows are filled.
static float rowL[LCD_ROWS], rowR[LCD_ROWS];
static void fillPoly(const float* px, const float* py, int n, const uint8_t* pat)
{
	float ymin = py[0], ymax = py[0];
	for ( int i = 1; i < n; i++ )
	{
		if ( py[i] < ymin ) ymin = py[i];
		if ( py[i] > ymax ) ymax = py[i];
	}
	int y0 = (int)ceilf(ymin - 0.5f), y1 = (int)ceilf(ymax - 0.5f);
	if ( y0 < clipY0 ) y0 = clipY0;
	if ( y1 > clipY1 ) y1 = clipY1;
	if ( y1 <= y0 ) return;
	statPolys++;
	for ( int y = y0; y < y1; y++ ) { rowL[y] = 1e9f; rowR[y] = -1e9f; }
	for ( int i = 0, j = n - 1; i < n; j = i++ )
	{
		float xa = px[j], ya = py[j], xb = px[i], yb = py[i];
		if ( ya == yb ) continue;
		if ( ya > yb ) { float t = xa; xa = xb; xb = t; t = ya; ya = yb; yb = t; }
		int ra = (int)ceilf(ya - 0.5f), rb = (int)ceilf(yb - 0.5f);
		if ( ra < y0 ) ra = y0;
		if ( rb > y1 ) rb = y1;
		if ( rb <= ra ) continue;
		float k = (xb - xa) / (yb - ya);
		float x = xa + ((float)ra + 0.5f - ya) * k;
		for ( int y = ra; y < rb; y++, x += k )
		{
			if ( x < rowL[y] ) rowL[y] = x;
			if ( x > rowR[y] ) rowR[y] = x;
		}
	}
	for ( int y = y0; y < y1; y++ )
		if ( rowR[y] > rowL[y] ) span(y, (int)ceilf(rowL[y] - 0.5f), (int)ceilf(rowR[y] - 0.5f), pat);
}

static inline void plot(int x, int y, int white)
{
	if ( x < clipX0 || x >= clipX1 || y < clipY0 || y >= clipY1 ) return;
	uint8_t* b = fb + y * LCD_ROWSIZE + (x >> 3);
	uint8_t m = (uint8_t)(0x80 >> (x & 7));
	if ( white ) *b |= m; else *b &= (uint8_t)~m;
}

// a 1-px line (Bresenham)
static void line1(float fx0, float fy0, float fx1, float fy1)
{
	int x0 = (int)floorf(fx0), y0 = (int)floorf(fy0), x1 = (int)floorf(fx1), y1 = (int)floorf(fy1);
	int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
	int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
	int err = dx + dy;
	for ( ;; )
	{
		plot(x0, y0, 0);
		if ( x0 == x1 && y0 == y1 ) break;
		int e2 = 2 * err;
		if ( e2 >= dy ) { err += dy; x0 += sx; }
		if ( e2 <= dx ) { err += dx; y0 += sy; }
	}
}

// a filled disc (round joins and caps)
static void disc(float cx, float cy, float r, const uint8_t* pat)
{
	int y0 = (int)ceilf(cy - r - 0.5f), y1 = (int)ceilf(cy + r - 0.5f);
	if ( y0 < clipY0 ) y0 = clipY0;
	if ( y1 > clipY1 ) y1 = clipY1;
	for ( int y = y0; y < y1; y++ )
	{
		float dy = (float)y + 0.5f - cy;
		float h = r * r - dy * dy;
		if ( h <= 0 ) continue;
		h = sqrtf(h);
		span(y, (int)ceilf(cx - h - 0.5f), (int)ceilf(cx + h - 0.5f), pat);
	}
}

// ---------------------------------------------------------------------------
// loading

static int rd8(const uint8_t** p, const uint8_t* end, int* ok) { if ( *p + 1 > end ) { *ok = 0; return 0; } return *(*p)++; }
static int rd16(const uint8_t** p, const uint8_t* end, int* ok)
{
	if ( *p + 2 > end ) { *ok = 0; return 0; }
	int v = (*p)[0] | ((*p)[1] << 8);
	*p += 2;
	return v;
}

static V3 unit(float lon, float lat)
{
	float p = lat * (float)M_PI / 180.0f, q = lon * (float)M_PI / 180.0f;
	V3 v = { cosf(p) * cosf(q), cosf(p) * sinf(q), sinf(p) };
	return v;
}

static int l_load(lua_State* L)
{
	size_t len = 0;
	const char* s = pd->lua->getArgBytes(1, &len);
	if ( !s || len < 8 || memcmp(s, "GLB1", 4) != 0 ) { pd->lua->pushNil(); pd->lua->pushString("not a globe"); return 2; }
	const uint8_t* p = (const uint8_t*)s + 4;
	const uint8_t* end = (const uint8_t*)s + len;
	int ok = 1;
	if ( rd16(&p, end, &ok) != NQ ) { pd->lua->pushNil(); pd->lua->pushString("bad quad count"); return 2; }
	for ( int q = 0; q < NQ; q++ ) { facetCode[q][0] = (uint8_t)rd8(&p, end, &ok); facetCode[q][1] = (uint8_t)rd8(&p, end, &ok); }
	int np = rd16(&p, end, &ok);
	pieces = pd->system->realloc(pieces, sizeof(Piece) * (np > 0 ? np : 1));
	npieces = 0;
	for ( int i = 0; i < np && ok; i++ )
	{
		Piece* pc = &pieces[npieces];
		pc->quad = (uint16_t)rd16(&p, end, &ok);
		pc->kind = (uint8_t)rd8(&p, end, &ok);
		int n = rd8(&p, end, &ok);
		int su = 0, sv = 0;
		for ( int k = 0; k < n; k++ )
		{
			int u = rd8(&p, end, &ok), v = rd8(&p, end, &ok);
			if ( k < MAXV ) { pc->u[k] = (uint8_t)u; pc->v[k] = (uint8_t)v; }
			su += u; sv += v;
		}
		pc->n = (uint8_t)(n < MAXV ? n : MAXV);
		pc->facet = sv <= su ? 0 : 1;
		if ( pc->kind > 4 ) pc->kind = 1;
		if ( pc->quad < NQ && pc->n >= 3 ) npieces++;
	}
	nsegs = rd16(&p, end, &ok);
	segs = pd->system->realloc(segs, sizeof(Seg) * (nsegs > 0 ? nsegs : 1));
	for ( int i = 0; i < nsegs && ok; i++ )
	{
		segs[i].quad = (uint16_t)rd16(&p, end, &ok);
		segs[i].u1 = (uint8_t)rd8(&p, end, &ok); segs[i].v1 = (uint8_t)rd8(&p, end, &ok);
		segs[i].u2 = (uint8_t)rd8(&p, end, &ok); segs[i].v2 = (uint8_t)rd8(&p, end, &ok);
		if ( segs[i].quad >= NQ ) segs[i].quad = 0;
	}
	if ( !ok ) { loaded = 0; pd->lua->pushNil(); pd->lua->pushString("truncated"); return 2; }
	// pieces come sorted by quad: index them
	int k = 0;
	for ( int q = 0; q <= NQ; q++ )
	{
		while ( k < npieces && pieces[k].quad < q ) k++;
		pieceStart[q] = k;
	}
	for ( int j = 0; j <= NJ; j++ )
		for ( int i = 0; i < NI; i++ )
			corner[j][i] = unit(-180.0f + 15.0f * i, -90.0f + 15.0f * j);
	for ( int j = 0; j < NJ; j++ )
		for ( int i = 0; i < NI; i++ )
		{
			V3 a = corner[j][i], b = corner[j][(i + 1) % NI], c = corner[j + 1][(i + 1) % NI], d = corner[j + 1][i];
			float sx = a.x + b.x + c.x, sy = a.y + b.y + c.y, sz = a.z + b.z + c.z;
			invA[j * NI + i] = 1.0f / sqrtf(sx * sx + sy * sy + sz * sz);
			sx = a.x + c.x + d.x; sy = a.y + c.y + d.y; sz = a.z + c.z + d.z;
			invB[j * NI + i] = 1.0f / sqrtf(sx * sx + sy * sy + sz * sz);
		}
	buildLevels();
	loaded = 1;
	pd->lua->pushBool(1);
	return 1;
}

// ---------------------------------------------------------------------------
// rendering

static float argf(int i) { return pd->lua->getArgFloat(i); }

// the view of the last render (globe.leg projects with it)
static V3 vX = { 0, 1, 0 }, vY = { 0, 0, 1 }, vZ = { 1, 0, 0 };
static float vcx = 142, vcy = 132, vR = 112;
static int argIsNil(int i) { return i > pd->lua->getArgCount() || pd->lua->getArgType(i, NULL) == kTypeNil; }

static void setClip(int first)
{
	clipX0 = 0; clipY0 = 0; clipX1 = LCD_COLUMNS; clipY1 = LCD_ROWS;
	if ( !argIsNil(first) )
	{
		clipX0 = pd->lua->getArgInt(first); clipY0 = pd->lua->getArgInt(first + 1);
		clipX1 = pd->lua->getArgInt(first + 2); clipY1 = pd->lua->getArgInt(first + 3);
		if ( clipX0 < 0 ) clipX0 = 0;
		if ( clipY0 < 0 ) clipY0 = 0;
		if ( clipX1 > LCD_COLUMNS ) clipX1 = LCD_COLUMNS;
		if ( clipY1 > LCD_ROWS ) clipY1 = LCD_ROWS;
	}
}

static int l_render(lua_State* L)
{
	if ( !loaded ) return 0;
	float t0 = pd->system->getElapsedTime();
	statRows = statPx = statPolys = 0;
	float lat0 = argf(1) * (float)M_PI / 180.0f, lon0 = argf(2) * (float)M_PI / 180.0f;
	float cx = argf(3), cy = argf(4), R = argf(5);
	setClip(6);
	fb = pd->graphics->getFrame();
	if ( !fb ) return 0;
	float sl = sinf(lon0), cl = cosf(lon0), sp = sinf(lat0), cp = cosf(lat0);
	// view rows: X right, Y up, Z toward the viewer (and the light)
	V3 X = { -sl, cl, 0 }, Y = { -sp * cl, -sp * sl, cp }, Z = { cp * cl, cp * sl, sp };
	vX = X; vY = Y; vZ = Z; vcx = cx; vcy = cy; vR = R;
	static float sx[NJ + 1][NI], sy[NJ + 1][NI], sz[NJ + 1][NI];
	for ( int j = 0; j <= NJ; j++ )
		for ( int i = 0; i < NI; i++ )
		{
			V3 w = corner[j][i];
			sx[j][i] = cx + R * (w.x * X.x + w.y * X.y);
			sy[j][i] = cy - R * (w.x * Y.x + w.y * Y.y + w.z * Y.z);
			sz[j][i] = w.x * Z.x + w.y * Z.y + w.z * Z.z;
		}
	static uint8_t vis[NQ];
	static float qpx[NQ][4], qpy[NQ][4];
	for ( int j = 0; j < NJ; j++ )
		for ( int i = 0; i < NI; i++ )
		{
			int q = j * NI + i, i2 = (i + 1) % NI;
			vis[q] = 0;
			if ( sz[j][i] < 0 || sz[j][i2] < 0 || sz[j + 1][i2] < 0 || sz[j + 1][i] < 0 ) continue;
			float* px = qpx[q];
			float* py = qpy[q];
			px[0] = sx[j][i]; py[0] = sy[j][i];
			px[1] = sx[j][i2]; py[1] = sy[j][i2];
			px[2] = sx[j + 1][i2]; py[2] = sy[j + 1][i2];
			px[3] = sx[j + 1][i]; py[3] = sy[j + 1][i];
			if ( px[0] > clipX1 + 1 && px[1] > clipX1 + 1 && px[2] > clipX1 + 1 && px[3] > clipX1 + 1 ) continue;
			if ( py[0] > clipY1 + 1 && py[1] > clipY1 + 1 && py[2] > clipY1 + 1 && py[3] > clipY1 + 1 ) continue;
			vis[q] = 1;
			float lit[2];
			lit[0] = (sz[j][i] + sz[j][i2] + sz[j + 1][i2]) * invA[q];
			lit[1] = (sz[j][i] + sz[j + 1][i2] + sz[j + 1][i]) * invB[q];
			int lv[2];
			for ( int f = 0; f < 2; f++ )
			{
				if ( lit[f] < 0 ) lit[f] = 0;
				int code = facetCode[q][f];
				lv[f] = code == 254 ? -1 : levelFor(lit[f], code == 255 ? 0 : (code > 4 ? 1 : code));
			}
			if ( lv[0] >= 0 && lv[0] == lv[1] )
				fillPoly(px, py, 4, level[lv[0]]);     // both facets one level: one fill (half the rows)
			else
				for ( int f = 0; f < 2; f++ )
				{
					if ( lv[f] < 0 ) continue;
					float tx[3] = { px[0], px[f ? 2 : 1], px[f ? 3 : 2] };
					float ty[3] = { py[0], py[f ? 2 : 1], py[f ? 3 : 2] };
					fillPoly(tx, ty, 3, level[lv[f]]);
				}
			// the land on this quad, flat on its facet at the facet's light
			for ( int n = pieceStart[q]; n < pieceStart[q + 1]; n++ )
			{
				const Piece* pc = &pieces[n];
				float ux[MAXV], uy[MAXV];
				int f = pc->facet;
				for ( int v = 0; v < pc->n; v++ )
				{
					float u = pc->u[v] / QS, w = pc->v[v] / QS;
					if ( f == 0 ) { ux[v] = px[0] + u * (px[1] - px[0]) + w * (px[2] - px[1]); uy[v] = py[0] + u * (py[1] - py[0]) + w * (py[2] - py[1]); }
					else { ux[v] = px[0] + w * (px[3] - px[0]) + u * (px[2] - px[3]); uy[v] = py[0] + w * (py[3] - py[0]) + u * (py[2] - py[3]); }
				}
				fillPoly(ux, uy, pc->n, level[levelFor(lit[f], pc->kind)]);
			}
		}
	// the coasts: 1 px, dark
	float tc = pd->system->getElapsedTime();
	for ( int n = 0; n < nsegs; n++ )
	{
		const Seg* s = &segs[n];
		if ( !vis[s->quad] ) continue;
		const float* px = qpx[s->quad];
		const float* py = qpy[s->quad];
		float e[4];
		for ( int k = 0; k < 2; k++ )
		{
			float u = (k ? s->u2 : s->u1) / QS, w = (k ? s->v2 : s->v1) / QS;
			if ( w <= u ) { e[k * 2] = px[0] + u * (px[1] - px[0]) + w * (px[2] - px[1]); e[k * 2 + 1] = py[0] + u * (py[1] - py[0]) + w * (py[2] - py[1]); }
			else { e[k * 2] = px[0] + w * (px[3] - px[0]) + u * (px[2] - px[3]); e[k * 2 + 1] = py[0] + w * (py[3] - py[0]) + u * (py[2] - py[3]); }
		}
		line1(e[0], e[1], e[2], e[3]);
	}
	pd->graphics->markUpdatedRows(clipY0, clipY1 - 1);
	lastMs = (pd->system->getElapsedTime() - t0) * 1000.0f;
	lastCoastMs = (pd->system->getElapsedTime() - tc) * 1000.0f;
	lastRows = statRows; lastPx = statPx; lastPolys = statPolys;
	return 0;
}

static const uint8_t WHITE[4] = { 0xFF, 0xFF, 0xFF, 0xFF };
static const uint8_t BLACK[4] = { 0, 0, 0, 0 };

// one band along a run of points: quads between mitred offsets (neighbours share their edges, so
// nothing is filled twice), round caps at both ends
static void band(const float* xs, const float* ys, int n, float r, const uint8_t* pat)
{
	disc(xs[0], ys[0], r, pat);
	if ( n < 2 ) return;
	float lx = 0, ly = 0, rx = 0, ry = 0;
	for ( int i = 0; i < n; i++ )
	{
		// the normal at a point: across the chord of its neighbours
		int a = i > 0 ? i - 1 : 0, b = i < n - 1 ? i + 1 : n - 1;
		float dx = xs[b] - xs[a], dy = ys[b] - ys[a];
		float l = sqrtf(dx * dx + dy * dy);
		if ( l < 1e-3f ) l = 1e-3f;
		float nx = -dy / l * r, ny = dx / l * r;
		float qx = xs[i] + nx, qy = ys[i] + ny, sx = xs[i] - nx, sy = ys[i] - ny;
		if ( i > 0 )
		{
			float px[4] = { lx, qx, sx, rx };
			float py[4] = { ly, qy, sy, ry };
			fillPoly(px, py, 4, pat);
		}
		lx = qx; ly = qy; rx = sx; ry = sy;
	}
	disc(xs[n - 1], ys[n - 1], r, pat);
}

// a run of screen points of one leg, drawn as a ribbon (outline, then body) or a shadow
static void drawRun(const float* xs, const float* ys, int n, float w, float out, const uint8_t* body)
{
	if ( n < 1 ) return;
	if ( out > 0 ) band(xs, ys, n, w * 0.5f + out, BLACK);
	band(xs, ys, n, w * 0.5f, body);
}

// globe.leg(mode, ax, ay, az, bx, by, bz, frac, lift, w, pat): one leg along the great circle a → b
// (unit vectors) drawn to frac, with the last render's view. mode 0: the drop shadow on the ground
// track, offset (3, 4), Bayer level pat ANDed in; mode 1: the ribbon arcing off the ground (lift x R
// at the middle), a w-px light body with a 1.5-px dark edge. Hidden stretches break it into runs.
#define LEG_N 36
static int l_leg(lua_State* L)
{
	int mode = pd->lua->getArgInt(1);
	V3 A = { argf(2), argf(3), argf(4) }, B = { argf(5), argf(6), argf(7) };
	float frac = argf(8), lift = argf(9), w = argf(10);
	int pat = pd->lua->getArgInt(11);
	if ( !loaded ) buildLevels();
	clipX0 = 0; clipY0 = 0; clipX1 = LCD_COLUMNS; clipY1 = LCD_ROWS;
	fb = pd->graphics->getFrame();
	if ( !fb || frac <= 0 ) return 0;
	float d = A.x * B.x + A.y * B.y + A.z * B.z;
	float om = acosf(d < -1 ? -1 : (d > 1 ? 1 : d));
	float so = sinf(om);
	float xs[LEG_N + 1], ys[LEG_N + 1];
	int n = 0;
	const uint8_t* body = mode ? WHITE : level[pat < 0 ? 0 : (pat > 8 ? 8 : pat)];
	andMode = mode ? 0 : 1;
	for ( int i = 0; i <= LEG_N; i++ )
	{
		float t = frac * (float)i / LEG_N;
		float s0 = 1 - t, s1 = t;
		if ( om > 1e-5f ) { s0 = sinf((1 - t) * om) / so; s1 = sinf(t * om) / so; }
		V3 p = { A.x * s0 + B.x * s1, A.y * s0 + B.y * s1, A.z * s0 + B.z * s1 };
		float x = p.x * vX.x + p.y * vX.y;
		float y = p.x * vY.x + p.y * vY.y + p.z * vY.z;
		float z = p.x * vZ.x + p.y * vZ.y + p.z * vZ.z;
		float s = mode ? 1 + lift * sinf((float)M_PI * t) : 1;
		int vis = mode ? (z > 0 || s * s * (x * x + y * y) > 1.0404f) : z > 0;
		if ( vis )
		{
			float qx = vcx + vR * s * x + (mode ? 0 : 3), qy = vcy - vR * s * y + (mode ? 0 : 4);
			// (points closer than 6 px to the last kept one replace it, except the run's first)
			if ( n > 1 && (qx - xs[n - 2]) * (qx - xs[n - 2]) + (qy - ys[n - 2]) * (qy - ys[n - 2]) < 36.0f ) n--;
			xs[n] = qx;
			ys[n] = qy;
			n++;
		}
		else
		{
			drawRun(xs, ys, n, w, mode ? 1.5f : 0, body);
			n = 0;
		}
	}
	drawRun(xs, ys, n, w, mode ? 1.5f : 0, body);
	andMode = 0;
	pd->graphics->markUpdatedRows(0, LCD_ROWS - 1);
	return 0;
}

static int l_ms(lua_State* L)
{
	pd->lua->pushFloat(lastMs);
	pd->lua->pushFloat(lastCoastMs);
	pd->lua->pushInt(lastPolys);
	pd->lua->pushInt(lastRows);
	pd->lua->pushInt(lastPx);
	return 5;
}

void globe_register(PlaydateAPI* playdate)
{
	pd = playdate;
	const char* err = NULL;
	if ( !pd->lua->addFunction(l_load, "globe.load", &err) ) pd->system->logToConsole("globe: %s", err);
	pd->lua->addFunction(l_render, "globe.render", &err);
	pd->lua->addFunction(l_leg, "globe.leg", &err);
	pd->lua->addFunction(l_ms, "globe.ms", &err);
}
