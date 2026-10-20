//
// bc3d.c — BallCast 3D renderer (C extension for the DEADBALL Playdate client).
//
// Live rasterizer for the ballpark (flat polygons in field feet filled with 8x8 1-bit
// patterns, near-plane clipping, painter's ordering by layer then depth, an animated
// "crowd noise" material), plus depth-sorted billboard puppets with per-size scaled
// bitmap caches, and the ball with shadow/trail.
//
// Field coordinates: feet, home plate origin, +y toward CF, +x toward 1B, +z up.
// Camera math matches images/parks/parks.json:
//   forward = normalize(target - eye); right = normalize(cross(forward, up)); camup = cross(right, forward)
//   sx = cx + scale * dot(d,right)/zc;  sy = cy - scale * dot(d,camup)/zc;  scale = 200/tan(fov/2)
//
// Lua API (all in the global table `bc3d`) — see ballcast/render3d.lua for the Lua side.
//

#include <math.h>
#include <string.h>
#include <stdlib.h>
#include "pd_api.h"
#include "bc3d.h"

static PlaydateAPI* pd = NULL;

#define MAX_VERTS   12000
#define MAX_POLYS   1600
#define MAX_MATS    64
#define MAX_SPRITES 640      // every pose x body x team a game draws (~580 by the 9th; was 256: constant re-registering)
#define MAX_BB      96
#define MAX_CLIP    64
#define BUCKETS     110      // height buckets of 2 px → up to 220 px tall
#define LAYER_OUTLINE 17     // geo.lua: black ground outlines (after all ground layers 0..16)
#define LAYER_CHALK   18     // the baked chalk lines (foul lines, boxes, base paths)
#define CHALK_FT      0.45f  // chalk band width in feet (a little bolder than the real 4 in)
static int diamondMode = 3;  // bit 0: ground outlines, bit 1: chalk strokes (bc3d.diamond, for A/B)

// ---------------------------------------------------------------------------
// state

typedef struct { float x, y, z; } V3;

typedef struct {
	V3 eye, right, up, fwd;
	float scale, cx, cy, near;
} Camera;

typedef struct {
	LCDBitmap* bmp;
	uint8_t* data;
	int w, h, rb;
	uint8_t wrap, crowd;
} Texture;

typedef struct {
	int v0;          // first vertex index
	int n;           // vertex count (2 = a line: mat = color 0/1, depthBias = width)
	uint8_t mat;
	int16_t layer;
	float depthBias;
	int16_t tex;     // -1 = flat material
	int16_t tex2;    // trivision: alternate texture (-1 = none); the board flips between tex/tex2
	float tpf;       // textured: texels per foot (for the minification fallback); disc (n == 1): radius ft
	V3 bc;           // bounding sphere (frustum culling): centre, radius (< 0: not computed yet)
	float br;
} Poly;

typedef struct {
	uint8_t pat[8];
	uint8_t mode;    // 0 = pattern, 1 = crowd noise, 2 = crowd heads (pat = 8x8 tile); +4 = black outline
	uint8_t amount;  // crowd: flip density 0..255
} Material;

// one built size of a sprite: allocated when it's built (a slot used to carry all 110 sizes'
// fields up front, ~3 KB a sprite; now ~1 KB, so the registry can hold every pose a game uses)
typedef struct {
	LCDBitmap* bmp;
	int16_t w, h;
	float ax, ay;
	float cs;                // cached bitmap px per 1x source px
} SizeCache;

typedef struct {
	LCDBitmap* src[2];       // 1x, 2x
	int w[2], h[2];
	float ax[2], ay[2];      // anchor (feet) in source pixels
	float figH;              // figure height in px at 1x (e.g. 40)
	float figFt;             // what that height means in feet (e.g. 6.2)
	SizeCache* cache[BUCKETS];   // the scaled sizes built so far (most sprites use a few)
	int lastB;               // size-bucket hysteresis: a slow zoom doesn't flicker between sizes
	float wx;                // body width factor (stocky > 1, lanky < 1), baked into the caches
	uint8_t hasLm;           // landmarks for the look stamps (bc3d.sprite arg 9)
	uint8_t faceCode, backCode;   // face: 0 away, 1 profile, 2 toward the camera; back: 1 = number shows
	float lm[22];            // 1x px: head, nose, back, kneeL, ankleL, kneeR, ankleR, elbowL, wristL, elbowR, wristR
	// the jersey's number panel (tools/assets/humanoid/jersey.py), 1x px: a point of the back at
	// panel (u, v) is jO + (u - .5) jU + (v - .5) jV; 7 x 5 glyph cells, jVis[col] bit row = clear
	uint8_t hasJersey, jerseyAway;
	uint8_t jVis[7];
	float jO[2], jU[2], jV[2];
	float jA, jB;            // the panel's clear span across (u): the digits fit in it or don't show
} Sprite;

typedef struct {
	uint8_t kind;    // 0 sprite, 1 ball, 2 dot
	uint8_t flip;
	uint8_t xf;      // sprite transform: 0 none, 1 offset only, 2 scale (+flip), 3 rotate
	int16_t sprite;
	float x, y, z;
	float hscale;
	float sx, sy, depth;
	float ksx, ksy, rot;    // squash/stretch (about the pivot), rotation (deg, clockwise on screen)
	float dx, dy;           // pixel offset in 1x sprite pixels (scaled with the puppet)
	float piv;              // pivot height above the feet anchor, 1x sprite pixels (0 feet, 20 centre)
	float bias;             // ball: sort as if this many feet nearer (ball in a glove draws in front)
	float sd;               // sort depth
	uint8_t shadow;         // ball: draw the ground shadow
	uint32_t look;          // sprite: per-player look stamps (see lookPass), 0 = none
} Billboard;

typedef struct { float depth; int16_t layer; int16_t idx; } DrawItem;

#define MAX_TEX 96
static Texture texs[MAX_TEX];
static float uvs[MAX_VERTS * 2];
static V3 verts[MAX_VERTS];
static int nverts = 0;
static Poly polys[MAX_POLYS];
static int npolys = 0;
static Material mats[MAX_MATS];
static Sprite* sprites[MAX_SPRITES];
#define NEW_CACHE_BUDGET 3          // new scaled sprite bitmaps per frame (see spriteFor)
static int newCaches = 0;
static int statNewCaches = 0;       // bitmaps built since the last bc3d.stats()
static int warming = 0;             // bc3d.warm: no budget
static Billboard bbs[MAX_BB];
static int nbb = 0;
static DrawItem items[MAX_POLYS];
static Camera cam;
static int frameNo = 0;
static float crowdLevel = 0.3f;
static int statPolys = 0, statSpans = 0;
static int wPix = 0, wCrowd = 0, wTex = 0, wLines = 0, wWide = 0;   // work counters (bc3d.work)
static int wLayer[32];      // filled px per polygon layer (bc3d.layerWork, for profiling)
static int curLayer = 0;
static int cullOn = 1, freezeFrame = 0, debugLines = 0;   // debug: bc3d.debugRender(cull, freeze, lines)
static float dbgLine[48][12];
static int nDbg = 0;
static float tSort = 0, tPoly = 0, tLine = 0, tTex = 0;   // render section times (ms, last render)
static float statRenderMs = 0, statFlushMs = 0;
static float crowdTexDist = 600.0f;   // textures beyond this depth use their flat material (bc3d.quality)
// crowd heads (material mode 2): an 8x8 head-and-shoulders tile filled in screen space, offset
// by the camera's yaw/pitch so pans carry the crowd with the stands; every 8-px column bobs on its
// own (idle shimmer, more when excited), a rolling wave band stands up, flashes pop on big moments
static float crowdWave = 0, crowdFlash = 0;
static int crowdPanX = 0, crowdPanY = 0;
static uint8_t crowdBob[64];          // per column (world-anchored) vertical offset this frame
static uint8_t crowdAisle[64];        // per column: 1 = an aisle (stair rails) between sections
static uint8_t crowdUp[64];           // per column: 1 = in the wave band (standing, arms up: brighter)
static uint32_t flashSeed = 0;

// ---------------------------------------------------------------------------
// camera

static inline float dot3(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline V3 sub3(V3 a, V3 b) { V3 r = { a.x - b.x, a.y - b.y, a.z - b.z }; return r; }
static inline V3 norm3(V3 a) { float l = sqrtf(dot3(a, a)); if ( l < 1e-6f ) l = 1; V3 r = { a.x / l, a.y / l, a.z / l }; return r; }
static inline V3 cross3(V3 a, V3 b) { V3 r = { a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x }; return r; }

static void setCamera(V3 eye, V3 target, float fovDeg, float cx, float cy)
{
	V3 up = { 0, 0, 1 };
	cam.eye = eye;
	cam.fwd = norm3(sub3(target, eye));
	cam.right = norm3(cross3(cam.fwd, up));
	cam.up = cross3(cam.right, cam.fwd);
	cam.scale = 200.0f / tanf(fovDeg * 0.5f * 3.14159265f / 180.0f);
	cam.cx = cx;
	cam.cy = cy;
	cam.near = 1.0f;
}

static inline int project(float x, float y, float z, float* sx, float* sy, float* depth)
{
	V3 d = { x - cam.eye.x, y - cam.eye.y, z - cam.eye.z };
	float zc = dot3(d, cam.fwd);
	if ( zc < cam.near ) return 0;
	float inv = cam.scale / zc;
	*sx = cam.cx + dot3(d, cam.right) * inv;
	*sy = cam.cy - dot3(d, cam.up) * inv;
	*depth = zc;
	return 1;
}

// ---------------------------------------------------------------------------
// polygon fill into the 1-bit frame buffer (bit = 1 → white)

static uint8_t* fb = NULL;
static int clipY0 = 0, clipY1 = LCD_ROWS;   // [y0, y1)

static inline uint32_t hash32(uint32_t h)
{
	h ^= h >> 16; h *= 0x7feb352dU; h ^= h >> 15; h *= 0x846ca68bU; h ^= h >> 16;
	return h;
}

static void span(int y, int x0, int x1, const Material* m)
{
	// fills [x0, x1)
	if ( x0 < 0 ) x0 = 0;
	if ( x1 > LCD_COLUMNS ) x1 = LCD_COLUMNS;
	if ( x1 <= x0 ) return;
	statSpans++;
	if ( (m->mode & 3) == 0 ) wPix += x1 - x0; else wCrowd += x1 - x0;
	wLayer[curLayer & 31] += x1 - x0;
	uint8_t* row = fb + y * LCD_ROWSIZE;
	uint8_t p = m->pat[y & 7];
	int b0 = x0 >> 3, b1 = (x1 - 1) >> 3;
	uint8_t lm = (uint8_t)(0xFF >> (x0 & 7));
	uint8_t rm = (uint8_t)(0xFF << (7 - ((x1 - 1) & 7)));
	if ( (m->mode & 3) == 2 )
	{
		// crowd heads: tile row per column, columns anchored to the camera pan
		int px0 = crowdPanX;
		int sh = px0 & 7;
		int colBase = px0 >> 3;
		int yy = y + crowdPanY;
		// flashes: at most one white pixel per row, on a few rows per frame
		int fx = -1;
		if ( crowdFlash > 0 )
		{
			uint32_t h = hash32(((uint32_t)y * 2654435761u) ^ flashSeed);
			if ( (int)(h & 1023) < (int)(crowdFlash * 24.0f) ) fx = x0 + (int)((h >> 10) % (uint32_t)(x1 - x0));
		}
		for ( int b = b0; b <= b1; b++ )
		{
			int col = (b + colBase) & 63;
			uint8_t v = crowdAisle[col] ? (uint8_t)(((yy & 3) == 0) ? 0x7E : 0x42) : m->pat[(yy + crowdBob[col]) & 7];
			if ( crowdUp[col] ) v |= (uint8_t)((v << 1) | (v >> 1));     // the wave: everyone up, arms high
			if ( sh ) v = (uint8_t)((v << sh) | (v >> (8 - sh)));
			if ( fx >= 0 && (fx >> 3) == b ) v |= (uint8_t)(0x80 >> (fx & 7));
			uint8_t mask = 0xFF;
			if ( b == b0 ) mask &= lm;
			if ( b == b1 ) mask &= rm;
			row[b] = (row[b] & ~mask) | (v & mask);
		}
		return;
	}
	if ( (m->mode & 3) == 1 )
	{
		// crowd: pattern with hashed speckle that changes a few times a second
		uint32_t seed = (uint32_t)(frameNo / 3) * 0x9E3779B9U;
		int amt = m->amount + (int)(crowdLevel * 120);
		// one real hash per row, then a cheap xorshift per byte (was a full hash per byte)
		uint32_t h = hash32(((uint32_t)y * 64 + (uint32_t)b0) ^ seed) | 1u;
		for ( int b = b0; b <= b1; b++ )
		{
			h ^= h << 13; h ^= h >> 17; h ^= h << 5;
			uint8_t noise = (uint8_t)(h & (h >> 8) & (h >> 16));
			if ( amt > 120 ) noise |= (uint8_t)(h >> 4) & (uint8_t)(h >> 20) & (uint8_t)(h >> 12);
			uint8_t v = p ^ noise;
			uint8_t mask = 0xFF;
			if ( b == b0 ) mask &= lm;
			if ( b == b1 ) mask &= rm;
			row[b] = (row[b] & ~mask) | (v & mask);
		}
		return;
	}
	if ( b0 == b1 )
	{
		uint8_t mask = lm & rm;
		row[b0] = (row[b0] & ~mask) | (p & mask);
		return;
	}
	row[b0] = (row[b0] & ~lm) | (p & lm);
	if ( b1 - b0 > 1 ) memset(row + b0 + 1, p, (size_t)(b1 - b0 - 1));
	row[b1] = (row[b1] & ~rm) | (p & rm);
}

// even-odd scanline fill of a projected polygon
static void fillPoly(const float* px, const float* py, int n, const Material* m, float ox, float oy)
{
	float ymin = 1e9f, ymax = -1e9f, xmin = 1e9f, xmax = -1e9f;
	for ( int i = 0; i < n; i++ )
	{
		if ( py[i] < ymin ) ymin = py[i];
		if ( py[i] > ymax ) ymax = py[i];
		if ( px[i] < xmin ) xmin = px[i];
		if ( px[i] > xmax ) xmax = px[i];
	}
	ymin += oy; ymax += oy; xmin += ox; xmax += ox;
	if ( ymax < clipY0 || ymin >= clipY1 || xmax < 0 || xmin >= LCD_COLUMNS ) return;
	int y0 = (int)ceilf(ymin - 0.5f), y1 = (int)ceilf(ymax - 0.5f);
	if ( y0 < clipY0 ) y0 = clipY0;
	if ( y1 > clipY1 ) y1 = clipY1;
	statPolys++;
	float xs[MAX_CLIP];
	for ( int y = y0; y < y1; y++ )
	{
		float sy = (float)y + 0.5f - oy;
		int k = 0;
		for ( int i = 0, j = n - 1; i < n; j = i++ )
		{
			float ya = py[j], yb = py[i];
			if ( (ya <= sy && yb > sy) || (yb <= sy && ya > sy) )
			{
				float t = (sy - ya) / (yb - ya);
				float x = px[j] + (px[i] - px[j]) * t + ox;
				// insertion sort
				int q = k++;
				while ( q > 0 && xs[q - 1] > x ) { xs[q] = xs[q - 1]; q--; }
				xs[q] = x;
				if ( k >= MAX_CLIP ) break;
			}
		}
		for ( int q = 0; q + 1 < k; q += 2 )
		{
			int xa = (int)ceilf(xs[q] - 0.5f);
			int xb = (int)ceilf(xs[q + 1] - 0.5f);
			span(y, xa, xb, m);
		}
	}
}

// ---- perspective-correct textured polygons (ad boards, scoreboards, crowd tiles) ----

typedef struct { float x, a, b, c; } Cross;

static inline int texel(const Texture* t, int u, int v)
{
	if ( t->wrap ) { u %= t->w; if ( u < 0 ) u += t->w; v %= t->h; if ( v < 0 ) v += t->h; }
	else { if ( u < 0 ) u = 0; else if ( u >= t->w ) u = t->w - 1; if ( v < 0 ) v = 0; else if ( v >= t->h ) v = t->h - 1; }
	return (t->data[v * t->rb + (u >> 3)] >> (7 - (u & 7))) & 1;
}

static void fillPolyTex(const float* px, const float* py, const float* qa, const float* qb, const float* qc, int n, const Texture* t, float ox, float oy, int vOff)
{
	float ymin = 1e9f, ymax = -1e9f, xmin = 1e9f, xmax = -1e9f;
	for ( int i = 0; i < n; i++ )
	{
		if ( py[i] < ymin ) ymin = py[i];
		if ( py[i] > ymax ) ymax = py[i];
		if ( px[i] < xmin ) xmin = px[i];
		if ( px[i] > xmax ) xmax = px[i];
	}
	ymin += oy; ymax += oy; xmin += ox; xmax += ox;
	if ( ymax < clipY0 || ymin >= clipY1 || xmax < 0 || xmin >= LCD_COLUMNS ) return;
	int y0 = (int)ceilf(ymin - 0.5f), y1 = (int)ceilf(ymax - 0.5f);
	if ( y0 < clipY0 ) y0 = clipY0;
	if ( y1 > clipY1 ) y1 = clipY1;
	statPolys++;
	Cross xs[MAX_CLIP];
	for ( int y = y0; y < y1; y++ )
	{
		float sy = (float)y + 0.5f - oy;
		int k = 0;
		for ( int i = 0, j = n - 1; i < n; j = i++ )
		{
			float ya = py[j], yb = py[i];
			if ( (ya <= sy && yb > sy) || (yb <= sy && ya > sy) )
			{
				float f = (sy - ya) / (yb - ya);
				Cross c;
				c.x = px[j] + (px[i] - px[j]) * f + ox;
				c.a = qa[j] + (qa[i] - qa[j]) * f;
				c.b = qb[j] + (qb[i] - qb[j]) * f;
				c.c = qc[j] + (qc[i] - qc[j]) * f;
				int q = k++;
				while ( q > 0 && xs[q - 1].x > c.x ) { xs[q] = xs[q - 1]; q--; }
				xs[q] = c;
				if ( k >= MAX_CLIP ) break;
			}
		}
		uint8_t* row = fb + y * LCD_ROWSIZE;
		for ( int q = 0; q + 1 < k; q += 2 )
		{
			const Cross* L = &xs[q];
			const Cross* R = &xs[q + 1];
			int xa = (int)ceilf(L->x - 0.5f), xb = (int)ceilf(R->x - 0.5f);
			if ( xa < 0 ) xa = 0;
			if ( xb > LCD_COLUMNS ) xb = LCD_COLUMNS;
			if ( xb <= xa ) continue;
			statSpans++;
			float w = R->x - L->x;
			if ( w < 1e-3f ) w = 1e-3f;
			// subdivide every 8 px: exact u,v at run ends, affine between
			wTex += xb - xa;
			for ( int x = xa; x < xb; )
			{
				int xe = x + 8 < xb ? x + 8 : xb;
				float f0 = ((float)x + 0.5f - L->x) / w, f1 = ((float)xe + 0.5f - L->x) / w;
				float a0 = L->a + (R->a - L->a) * f0, b0 = L->b + (R->b - L->b) * f0, c0 = L->c + (R->c - L->c) * f0;
				float a1 = L->a + (R->a - L->a) * f1, b1 = L->b + (R->b - L->b) * f1, c1 = L->c + (R->c - L->c) * f1;
				float u0 = a0 / c0, v0 = b0 / c0, u1 = a1 / c1, v1 = b1 / c1;
				int cnt = xe - x;
				float du = (u1 - u0) / (float)cnt, dv = (v1 - v0) / (float)cnt;
				// 16.16 fixed point, wrapped into the texture once per run; bits are
				// accumulated and written a byte at a time
				int32_t W = t->w << 16, H = t->h << 16;
				float fw = (float)t->w, fh = (float)t->h;
				// keep everything in range before going fixed point (near the camera the
				// perspective divide can produce huge values; float→int overflow is UB)
				if ( !(u0 == u0) || !(v0 == v0) || !(du == du) || !(dv == dv) ) { x = xe; continue; }
				float fu = u0, fv = v0 + (float)vOff;
				if ( t->wrap ) { fu = fmodf(fu, fw); if ( fu < 0 ) fu += fw; fv = fmodf(fv, fh); if ( fv < 0 ) fv += fh; }
				else { if ( fu < -1 ) fu = -1; else if ( fu > fw ) fu = fw; if ( fv < -1 ) fv = -1; else if ( fv > fh ) fv = fh; }
				if ( du > fw * 0.5f ) du = fw * 0.5f; else if ( du < -fw * 0.5f ) du = -fw * 0.5f;
				if ( dv > fh * 0.5f ) dv = fh * 0.5f; else if ( dv < -fh * 0.5f ) dv = -fh * 0.5f;
				int32_t U = (int32_t)(fu * 65536.0f), V = (int32_t)(fv * 65536.0f);
				int32_t dU = (int32_t)(du * 65536.0f), dV = (int32_t)(dv * 65536.0f);
				const uint8_t* data = t->data;
				const int rb = t->rb;
				uint8_t acc = 0, msk = 0;
				int bx = x >> 3;
				if ( t->wrap )
				{
					if ( U >= W ) U = W - 1;
					if ( V >= H ) V = H - 1;
					if ( U < 0 ) U = 0;
					if ( V < 0 ) V = 0;
					// magnified (a texel spans 2+ pixels): sample every other pixel
					int dbl = (dU < 32768 && dU > -32768 && dV < 32768 && dV > -32768);
					int bit = 0;
					const uint8_t* rowp = data + (V >> 16) * rb;
					int lastV = V >> 16;
					for ( int xx = x; xx < xe; xx++ )
					{
						if ( !dbl || !(xx & 1) || xx == x )
						{
							int tv = V >> 16;
							if ( tv != lastV ) { lastV = tv; rowp = data + tv * rb; }
							int tu = U >> 16;
							bit = (rowp[tu >> 3] << (tu & 7)) & 0x80;
						}
						uint8_t m = (uint8_t)(0x80 >> (xx & 7));
						if ( bit ) acc |= m;
						msk |= m;
						if ( (xx & 7) == 7 ) { row[bx] = (uint8_t)((row[bx] & ~msk) | acc); acc = msk = 0; bx++; }
						U += dU; V += dV;
						if ( U >= W ) U -= W; else if ( U < 0 ) U += W;
						if ( V >= H ) V -= H; else if ( V < 0 ) V += H;
					}
				}
				else
				{
					int tw = t->w - 1, th = t->h - 1;
					for ( int xx = x; xx < xe; xx++ )
					{
						int tu = U >> 16, tv = V >> 16;
						if ( tu < 0 ) tu = 0; else if ( tu > tw ) tu = tw;
						if ( tv < 0 ) tv = 0; else if ( tv > th ) tv = th;
						uint8_t m = (uint8_t)(0x80 >> (xx & 7));
						if ( (data[tv * rb + (tu >> 3)] << (tu & 7)) & 0x80 ) acc |= m;
						msk |= m;
						if ( (xx & 7) == 7 ) { row[bx] = (uint8_t)((row[bx] & ~msk) | acc); acc = msk = 0; bx++; }
						U += dU; V += dV;
					}
				}
				if ( msk ) row[bx] = (uint8_t)((row[bx] & ~msk) | acc);
				x = xe;
			}
		}
	}
}

static int clipProjectTex(const Poly* P, float* outX, float* outY, float* qa, float* qb, float* qc)
{
	float cx_[MAX_CLIP], cy_[MAX_CLIP], cz_[MAX_CLIP], cu[MAX_CLIP], cv[MAX_CLIP];
	int n = P->n > MAX_CLIP - 4 ? MAX_CLIP - 4 : P->n;
	for ( int i = 0; i < n; i++ )
	{
		V3 d = sub3(verts[P->v0 + i], cam.eye);
		cx_[i] = dot3(d, cam.right);
		cy_[i] = dot3(d, cam.up);
		cz_[i] = dot3(d, cam.fwd);
		cu[i] = uvs[(P->v0 + i) * 2];
		cv[i] = uvs[(P->v0 + i) * 2 + 1];
	}
	const float near = 1.0f;
	int m = 0;
	for ( int i = 0; i < n && m < MAX_CLIP - 1; i++ )
	{
		int j = (i + 1) % n;
		int ain = cz_[i] >= near, bin = cz_[j] >= near;
		if ( ain )
		{
			float iz = 1.0f / cz_[i];
			outX[m] = cam.cx + cam.scale * cx_[i] * iz;
			outY[m] = cam.cy - cam.scale * cy_[i] * iz;
			qa[m] = cu[i] * iz; qb[m] = cv[i] * iz; qc[m] = iz;
			m++;
		}
		if ( ain != bin )
		{
			float t = (near - cz_[i]) / (cz_[j] - cz_[i]);
			float x = cx_[i] + (cx_[j] - cx_[i]) * t;
			float y = cy_[i] + (cy_[j] - cy_[i]) * t;
			float u = cu[i] + (cu[j] - cu[i]) * t;
			float v = cv[i] + (cv[j] - cv[i]) * t;
			float iz = 1.0f / near;
			outX[m] = cam.cx + cam.scale * x * iz;
			outY[m] = cam.cy - cam.scale * y * iz;
			qa[m] = u * iz; qb[m] = v * iz; qc[m] = iz;
			m++;
		}
	}
	return m;
}

static int cmpItems(const void* a, const void* b)
{
	const DrawItem* p = a;
	const DrawItem* q = b;
	if ( p->layer != q->layer ) return p->layer - q->layer;
	if ( p->depth > q->depth ) return -1;
	if ( p->depth < q->depth ) return 1;
	return p->idx - q->idx;
}

// camera-space transform + near clip + projection for one polygon
static int clipProject(const Poly* P, float* outX, float* outY, float* outDepth)
{
	float cx_[MAX_CLIP], cy_[MAX_CLIP], cz_[MAX_CLIP];
	int n = P->n > MAX_CLIP - 4 ? MAX_CLIP - 4 : P->n;
	int anyIn = 0;
	for ( int i = 0; i < n; i++ )
	{
		V3 d = sub3(verts[P->v0 + i], cam.eye);
		cx_[i] = dot3(d, cam.right);
		cy_[i] = dot3(d, cam.up);
		cz_[i] = dot3(d, cam.fwd);
		if ( cz_[i] >= cam.near ) anyIn = 1;
	}
	if ( !anyIn ) return 0;
	const float near = 1.0f;
	int m = 0;
	float dsum = 0;
	for ( int i = 0; i < n && m < MAX_CLIP - 1; i++ )
	{
		int j = (i + 1) % n;
		int ain = cz_[i] >= near, bin = cz_[j] >= near;
		if ( ain )
		{
			outX[m] = cam.cx + cam.scale * cx_[i] / cz_[i];
			outY[m] = cam.cy - cam.scale * cy_[i] / cz_[i];
			dsum += cz_[i];
			m++;
		}
		if ( ain != bin )
		{
			float t = (near - cz_[i]) / (cz_[j] - cz_[i]);
			float x = cx_[i] + (cx_[j] - cx_[i]) * t;
			float y = cy_[i] + (cy_[j] - cy_[i]) * t;
			outX[m] = cam.cx + cam.scale * x / near;
			outY[m] = cam.cy - cam.scale * y / near;
			dsum += near;
			m++;
		}
	}
	if ( m < 3 ) return 0;
	*outDepth = dsum / (float)m;
	return m;
}

// a 3D line segment, near-clipped
static void drawLine3(const Poly* P, float ox, float oy)
{
	V3 a = verts[P->v0], b = verts[P->v0 + 1];
	V3 da = sub3(a, cam.eye), db = sub3(b, cam.eye);
	float za = dot3(da, cam.fwd), zb = dot3(db, cam.fwd);
	const float near = 1.0f;
	if ( za < near && zb < near ) return;
	if ( za < near ) { float t = (near - za) / (zb - za); a.x += (b.x - a.x) * t; a.y += (b.y - a.y) * t; a.z += (b.z - a.z) * t; }
	else if ( zb < near ) { float t = (near - zb) / (za - zb); b.x += (a.x - b.x) * t; b.y += (a.y - b.y) * t; b.z += (a.z - b.z) * t; }
	float x1, y1, d1, x2, y2, d2;
	if ( !project(a.x, a.y, a.z, &x1, &y1, &d1) || !project(b.x, b.y, b.z, &x2, &y2, &d2) ) return;
	int w = (int)(P->depthBias + 0.5f);
	if ( w < 1 ) w = 1;
	int ix1 = (int)(x1 + ox), iy1 = (int)(y1 + oy), ix2 = (int)(x2 + ox), iy2 = (int)(y2 + oy);
	if ( P->layer == LAYER_OUTLINE )
	{
		if ( !(diamondMode & 1) ) return;
		// ground outlines (dirt/grass edge, bases, plate, mound): skip the ones a few px long
		// (a base on the blimp shot would just become a black speck); 1 px ink at every distance
		float dx = x2 - x1, dy = y2 - y1;
		if ( dx * dx + dy * dy < 9.0f ) return;
		wLines++;
		pd->graphics->drawLine(ix1, iy1, ix2, iy2, 1, kColorBlack);
		return;
	}
	if ( debugLines && P->layer == LAYER_CHALK && nDbg < 48 )
	{
		float* q = dbgLine[nDbg++];
		q[0] = verts[P->v0].x; q[1] = verts[P->v0].y; q[2] = verts[P->v0 + 1].x; q[3] = verts[P->v0 + 1].y;
		q[4] = x1; q[5] = y1; q[6] = x2; q[7] = y2; q[8] = d1; q[9] = d2; q[10] = CHALK_FT * cam.scale / d1; q[11] = CHALK_FT * cam.scale / d2;
	}
	if ( (diamondMode & 2) && P->mat && P->layer == LAYER_CHALK && a.z < 0.5f && b.z < 0.5f )
	{
		// chalk as a band, sized from its real width at each end's own depth (thicker up close):
		//   white >= 3 px: black quad, white quad 1 px inside it (a white band with 1 px ink edges)
		//   1.5..3 px:     one clean ~2.5 px white quad inside a 4.5 px black one (no near-touching strokes)
		//   0.6..1.5 px:   the same with a 2 px core (a lone thin white line vanishes on the light
		//                  turf dither: mil's high-cam foul lines did; 1 px ink pairs read as rough)
		//   below:         the plain 1 px white line (blimp distance)
		// filled quads (cheap scanline fills), not wide line draws.
		float w1 = CHALK_FT * cam.scale / d1, w2 = CHALK_FT * cam.scale / d2;
		float wm = w1 > w2 ? w1 : w2;
		if ( wm >= 0.6f )
		{
			float dx = x2 - x1, dy = y2 - y1;
			float len = sqrtf(dx * dx + dy * dy);
			if ( len < 0.5f ) return;
			float nx = -dy / len, ny = dx / len;
			static Material solid[2];
			static int solidInit = 0;
			if ( !solidInit ) { memset(solid, 0, sizeof(solid)); for ( int q = 0; q < 8; q++ ) { solid[0].pat[q] = 0x00; solid[1].pat[q] = 0xFF; } solidInit = 1; }
			float qx[4], qy[4];
			if ( wm >= 3.0f )
			{
				float h1 = (w1 < 2.0f ? 2.0f : w1) * 0.5f, h2 = (w2 < 2.0f ? 2.0f : w2) * 0.5f;
				float e1 = h1 + 1.0f, e2 = h2 + 1.0f;
				qx[0] = x1 + nx * e1; qy[0] = y1 + ny * e1; qx[1] = x2 + nx * e2; qy[1] = y2 + ny * e2;
				qx[2] = x2 - nx * e2; qy[2] = y2 - ny * e2; qx[3] = x1 - nx * e1; qy[3] = y1 - ny * e1;
				fillPoly(qx, qy, 4, &solid[0], ox, oy);
				qx[0] = x1 + nx * h1; qy[0] = y1 + ny * h1; qx[1] = x2 + nx * h2; qy[1] = y2 + ny * h2;
				qx[2] = x2 - nx * h2; qy[2] = y2 - ny * h2; qx[3] = x1 - nx * h1; qy[3] = y1 - ny * h1;
				fillPoly(qx, qy, 4, &solid[1], ox, oy);
			}
			else
			{
				// 2 px white core with 1 px ink each side: a lone white quad vanishes on the light
				// foul-ground dither (the "missing" foul line past third on the deep cam)
				// (2.5 px core so it survives the rasteriser on diagonals; 2 px when farther)
				const float hw = wm < 1.5f ? 1.0f : 1.25f, he = hw + 1.0f;
				qx[0] = x1 + he * nx; qy[0] = y1 + he * ny; qx[1] = x2 + he * nx; qy[1] = y2 + he * ny;
				qx[2] = x2 - he * nx; qy[2] = y2 - he * ny; qx[3] = x1 - he * nx; qy[3] = y1 - he * ny;
				fillPoly(qx, qy, 4, &solid[0], ox, oy);
				qx[0] = x1 + hw * nx; qy[0] = y1 + hw * ny; qx[1] = x2 + hw * nx; qy[1] = y2 + hw * ny;
				qx[2] = x2 - hw * nx; qy[2] = y2 - hw * ny; qx[3] = x1 - hw * nx; qy[3] = y1 - hw * ny;
				fillPoly(qx, qy, 4, &solid[1], ox, oy);
			}
			return;
		}
	}
	wLines++; if ( (w) > 1 ) wWide++; pd->graphics->drawLine(ix1, iy1, ix2, iy2, w, P->mat ? kColorWhite : kColorBlack);
}

static void renderScene(float ox, float oy)
{
	float t0 = pd->system->getElapsedTime();
	fb = pd->graphics->getFrame();
	statPolys = statSpans = 0;
	wPix = wCrowd = wTex = wLines = wWide = 0;
	nDbg = 0;
	memset(wLayer, 0, sizeof(wLayer));
	{
		// crowd heads: pan anchoring + this frame's per-column bob (64 hashes a frame, not per pixel)
		float yaw = atan2f(cam.fwd.x, cam.fwd.y);
		float pitch = atan2f(cam.fwd.z, sqrtf(cam.fwd.x * cam.fwd.x + cam.fwd.y * cam.fwd.y));
		crowdPanX = (int)floorf(-yaw * cam.scale);
		crowdPanY = (int)floorf(pitch * cam.scale);
		int period = crowdLevel > 0.6f ? 3 : (crowdLevel > 0.35f ? 6 : 12);
		uint32_t tick = (uint32_t)(frameNo / period);
		int thresh = 30 + (int)(crowdLevel * 160.0f);        // of 256: share of columns bobbing
		float wavePos = (float)frameNo * 0.6f;                 // columns per frame
		for ( int c = 0; c < 64; c++ )
		{
			uint32_t h = hash32((uint32_t)c * 0x9E3779B9U ^ (tick * 0x85EBCA6BU + (uint32_t)c));
			uint8_t bob = (int)(h & 255) < thresh ? (uint8_t)(1 + ((h >> 8) & 1)) : 0;
			crowdUp[c] = 0;
			if ( crowdWave > 0 )
			{
				float d = fmodf((float)c - wavePos, 64.0f);
				if ( d < 0 ) d += 64.0f;
				if ( d < 5.0f ) { bob = (uint8_t)(d < 2.5f ? 3 : 2); crowdUp[c] = 1; }   // the wave rolls through
			}
			// each column sits at its own fixed height (no wallpaper rows); every 11th is an aisle
			uint32_t hs = hash32((uint32_t)c * 0x2C1B3C6DU + 7u);
			crowdBob[c] = (uint8_t)((hs & 7) + bob);
			crowdAisle[c] = (uint8_t)(c % 11 == 5);
		}
		flashSeed = hash32((uint32_t)frameNo * 0x27D4EB2FU);
	}
	// Frustum: the four screen-edge planes in camera space (x right, y up, z forward), normalized,
	// so a polygon whose bounding sphere is wholly outside one is skipped before any clipping or
	// projection (most of the ~300 polygons on a given shot).
	float sc = cam.scale;
	float nR = 1.0f / sqrtf(sc * sc + (LCD_COLUMNS - cam.cx) * (LCD_COLUMNS - cam.cx));
	float nL = 1.0f / sqrtf(sc * sc + cam.cx * cam.cx);
	float nT = 1.0f / sqrtf(sc * sc + cam.cy * cam.cy);
	float nB = 1.0f / sqrtf(sc * sc + (LCD_ROWS - cam.cy) * (LCD_ROWS - cam.cy));
	float slack = 4.0f / sc;     // a few px of margin (shake offsets)
	// The draw order is kept between frames and repaired with an insertion sort: it barely
	// changes from frame to frame (a camera cut costs one full sort).
	static DrawItem order[MAX_POLYS];
	static int orderN = -1;
	if ( orderN != npolys )
	{
		for ( int i = 0; i < npolys; i++ ) { order[i].idx = (int16_t)i; order[i].layer = polys[i].layer; order[i].depth = 0; }
		orderN = npolys;
	}
	static uint8_t vis[MAX_POLYS];
	for ( int k = 0; k < npolys; k++ )
	{
		const int i = order[k].idx;
		Poly* P = &polys[i];
		if ( P->br < 0 )
		{
			V3 c = { 0, 0, 0 };
			for ( int q = 0; q < P->n; q++ ) { c.x += verts[P->v0 + q].x; c.y += verts[P->v0 + q].y; c.z += verts[P->v0 + q].z; }
			c.x /= (float)P->n; c.y /= (float)P->n; c.z /= (float)P->n;
			float r = 0;
			for ( int q = 0; q < P->n; q++ ) { V3 d = sub3(verts[P->v0 + q], c); float l = sqrtf(dot3(d, d)); if ( l > r ) r = l; }
			if ( P->n == 1 ) r = P->tpf;
			P->bc = c; P->br = r + 0.5f;
		}
		V3 v = sub3(P->bc, cam.eye);
		float z = dot3(v, cam.fwd);
		float x = dot3(v, cam.right), y = dot3(v, cam.up);
		float r = P->br + slack * (z > 0 ? z : 0);
		int in = z + P->br >= cam.near;
		if ( cullOn && in && ( (sc * x - (LCD_COLUMNS - cam.cx) * z) * nR > r || (-sc * x - cam.cx * z) * nL > r ||
		             (sc * y - cam.cy * z) * nT > r || (-sc * y - (LCD_ROWS - cam.cy) * z) * nB > r ) ) in = 0;
		// the stands the camera sits in: a crowd polygon straddling the camera whose plane passes
		// a few feet from the eye (the deep cams ride the upper-deck lip behind home) is cut away,
		// as a broadcast booth would hang out over it; else that slab's underside blanks a wedge
		// of the shot (it ate the left-field foul line on deepC)
		if ( in && z - P->br < cam.near && P->n >= 3 && (mats[P->mat].mode & 3) )
		{
			V3 a = verts[P->v0], n = cross3(sub3(verts[P->v0 + 1], a), sub3(verts[P->v0 + 2], a));
			float nl = dot3(n, n);
			if ( nl > 1e-6f )
			{
				float pd0 = dot3(sub3(cam.eye, a), n);
				if ( pd0 * pd0 < 15.0f * 15.0f * nl ) in = 0;
			}
		}
		vis[k] = (uint8_t)in;
		// sort key: centroid depth (as before: mean vertex depth, plus the bias)
		float d = 0;
		if ( in )
		{
			for ( int q = 0; q < P->n; q++ ) d += dot3(sub3(verts[P->v0 + q], cam.eye), cam.fwd);
			d = d / (float)P->n + (P->n == 2 ? 0 : P->depthBias);
		}
		else d = z;
		order[k].depth = d;
	}
	// insertion sort (stable, nearly sorted input); vis moves with its item. After a camera cut
	// the old order is useless: one qsort instead of an O(n^2) repair (the blimp-cut spike).
	static V3 lastEye = { 1e9f, 1e9f, 1e9f };
	V3 de = sub3(cam.eye, lastEye);
	lastEye = cam.eye;
	if ( dot3(de, de) > 400.0f )
	{
		// vis is per position: remember it per polygon, sort, then read it back
		static uint8_t visBy[MAX_POLYS];
		for ( int k = 0; k < npolys; k++ ) visBy[order[k].idx] = vis[k];
		qsort(order, (size_t)npolys, sizeof(DrawItem), cmpItems);
		for ( int k = 0; k < npolys; k++ ) vis[k] = visBy[order[k].idx];
	}
	else
	for ( int k = 1; k < npolys; k++ )
	{
		DrawItem it = order[k];
		uint8_t vv = vis[k];
		int j = k - 1;
		while ( j >= 0 && cmpItems(&order[j], &it) > 0 ) { order[j + 1] = order[j]; vis[j + 1] = vis[j]; j--; }
		order[j + 1] = it; vis[j + 1] = vv;
	}
	int nd = 0;
	for ( int k = 0; k < npolys; k++ ) if ( vis[k] ) items[nd++] = order[k];
	float tA = pd->system->getElapsedTime();
	tSort = (tA - t0) * 1000.0f; tPoly = tLine = tTex = 0;
	float px[MAX_CLIP], py[MAX_CLIP];
	for ( int k = 0; k < nd; k++ )
	{
		const Poly* P = &polys[items[k].idx];
		curLayer = P->layer;
		float tq = pd->system->getElapsedTime();
		if ( P->n == 2 )
		{
			drawLine3(P, ox, oy);
			tLine += (pd->system->getElapsedTime() - tq) * 1000.0f;
			continue;
		}
		if ( P->n == 1 )
		{
			V3 c = verts[P->v0];
			float sx, sy, d;
			if ( !project(c.x, c.y, c.z, &sx, &sy, &d) ) continue;
			float r = P->tpf * cam.scale / d;
			if ( r < 0.6f ) continue;
			const Material* mat = &mats[P->mat];
			static LCDPattern lp;
			for ( int q = 0; q < 8; q++ ) { lp[q] = mat->pat[q]; lp[8 + q] = 0xFF; }
			pd->graphics->fillEllipse((int)(sx + ox - r), (int)(sy + oy - r), (int)(r * 2 + 1), (int)(r * 2 + 1), 0, 360, (LCDColor)lp);
			continue;
		}
		int tex = P->tex;
		int slat = 0;
		if ( tex >= 0 && P->tex2 >= 0 )
		{
			// trivision: hold A ~3.7 s, 3-frame slat flip, hold B, flip back (boards out of phase)
			int ph = (frameNo + items[k].idx * 37) % 228;
			if ( ph >= 111 && ph < 114 ) slat = 1 + (ph - 111);
			else if ( ph >= 225 ) slat = 1 + (ph - 225);
			if ( ph >= 114 && ph < 225 ) tex = P->tex2;
		}
		int useTex = tex >= 0 && tex < MAX_TEX && texs[tex].data;
		// minified textures just make moire (and cost the most): fall back to the material
		if ( useTex && P->tpf > 0 && P->tpf * items[k].depth / cam.scale > 1.5f ) useTex = 0;
		// textured only up close: within bc3d.quality's distance (0 on the wide/tracking shots),
		// or any board within 150 ft (only a few boards are ever that near the camera)
		if ( useTex && items[k].depth > crowdTexDist && items[k].depth > 150.0f ) useTex = 0;
		if ( useTex && slat )
		{
			// the slat flip: the board's material with rotating-slat stripes for 3 frames
			float depth;
			int m = clipProject(P, px, py, &depth);
			if ( m >= 3 )
			{
				Material tmp = mats[P->mat];
				tmp.mode = 0;
				for ( int q = 0; q < 8; q++ ) tmp.pat[q] = ((q + slat * 3) % 4 < 2) ? 0x00 : 0xFF;
				fillPoly(px, py, m, &tmp, ox, oy);
			}
			continue;
		}
		if ( useTex )
		{
			float qa[MAX_CLIP], qb[MAX_CLIP], qc[MAX_CLIP];
			int m = clipProjectTex(P, px, py, qa, qb, qc);
			const Texture* t = &texs[tex];
			// excited crowds bounce: shift crowd tiles a pixel every few frames
			int vOff = (t->crowd && crowdLevel > 0.45f && ((frameNo / 3) & 1)) ? 1 : 0;
			if ( m >= 3 ) fillPolyTex(px, py, qa, qb, qc, m, t, ox, oy, vOff);
			tTex += (pd->system->getElapsedTime() - tq) * 1000.0f;
			continue;
		}
		float depth;
		int m = clipProject(P, px, py, &depth);
		if ( m < 3 ) continue;
		const Material* mat = &mats[P->mat];
		if ( (mat->mode & 3) == 1 || (mat->mode & 3) == 2 ) fillPoly(px, py, m, mat, ox, oy);
		else
		{
			Material tmp = *mat;
			tmp.mode = 0;
			fillPoly(px, py, m, &tmp, ox, oy);
		}
		tPoly += (pd->system->getElapsedTime() - tq) * 1000.0f;
		if ( mat->mode & 4 )
		{
			for ( int q = 0; q < m; q++ )
			{
				int r = (q + 1) % m;
				pd->graphics->drawLine((int)(px[q] + ox), (int)(py[q] + oy), (int)(px[r] + ox), (int)(py[r] + oy), 1, kColorBlack);
			}
		}
	}
	pd->graphics->markUpdatedRows(clipY0, clipY1 - 1);
	if ( !freezeFrame ) frameNo++;
	statRenderMs = (pd->system->getElapsedTime() - t0) * 1000.0f;
}

// ---------------------------------------------------------------------------
// sprites

static void freeSpriteCache(Sprite* s)
{
	for ( int b = 0; b < BUCKETS; b++ )
	{
		if ( s->cache[b] ) { pd->graphics->freeBitmap(s->cache[b]->bmp); pd->system->realloc(s->cache[b], 0); s->cache[b] = NULL; }
	}
}

static void freeSprite(int id)
{
	Sprite* s = sprites[id];
	if ( !s ) return;
	freeSpriteCache(s);
	pd->system->realloc(s, 0);
	sprites[id] = NULL;
}

// pick a scaled bitmap for a figure height in px
// scale for a size bucket (relative to the chosen source)
static void bucketScale(const Sprite* s, int b, int* which, float* f)
{
	float sc = (float)(b * 2) / s->figH;      // relative to 1x
	*which = (sc >= 1.4f && s->src[1]) ? 1 : 0;
	*f = *which ? sc * 0.5f : sc;
	if ( *which == 0 && *f >= 0.8f && *f < 1.4f ) *f = 1.0f;     // parks.json rule: unscaled 1x
}

// every bucket in the unscaled 1x band shares one slot (was one identical copy per bucket)
static int canonicalBucket(const Sprite* s, int b)
{
	int which; float f;
	bucketScale(s, b, &which, &f);
	if ( which == 0 && f == 1.0f )
	{
		int c = (int)(s->figH * 0.5f + 0.5f);
		if ( c >= 1 && c < BUCKETS ) return c;
	}
	return b;
}

static void buildBucket(Sprite* s, int b)
{
	int which; float f;
	bucketScale(s, b, &which, &f);
	float fx = f * s->wx;      // body width (bc3d.sprite arg 8) is baked into the cached bitmap
	int nw = (int)(s->w[which] * fx + 0.5f), nh = (int)(s->h[which] * f + 0.5f);
	if ( nw < 1 ) nw = 1;
	if ( nh < 1 ) nh = 1;
	LCDBitmap* bmp = pd->graphics->newBitmap(nw, nh, kColorClear);
	pd->graphics->pushContext(bmp);
	if ( f == 1.0f && s->wx == 1.0f ) pd->graphics->drawBitmap(s->src[which], 0, 0, kBitmapUnflipped);
	else pd->graphics->drawScaledBitmap(s->src[which], 0, 0, fx, f);
	pd->graphics->popContext();
	SizeCache* c = pd->system->realloc(NULL, sizeof(SizeCache));
	c->bmp = bmp;
	c->w = (int16_t)nw; c->h = (int16_t)nh;
	c->ax = s->ax[which] * fx;
	c->ay = s->ay[which] * f;
	c->cs = which ? f * 2.0f : f;
	s->cache[b] = c;
}

// pre-warm support: bc3d.collect(true) makes flush record the (sprite, bucket) pairs it would
// have to build instead of drawing; bc3d.warmNext() then builds them one per call
#define MAX_WARM 512
static int collecting = 0;
static int16_t warmList[MAX_WARM][2];
static int nWarm = 0;

// pick a scaled bitmap for a figure height in px (NULL while collecting)
static LCDBitmap* spriteFor(Sprite* s, int id, float hpx, int* w, int* h, float* ax, float* ay, float* cs)
{
	float hb = hpx * 0.5f;
	int b = (int)(hb + 0.5f);
	if ( s->lastB > 0 && hb > s->lastB - 0.85f && hb < s->lastB + 0.85f ) b = s->lastB;
	if ( !collecting ) s->lastB = b;
	if ( b < 1 ) b = 1;
	if ( b >= BUCKETS ) b = BUCKETS - 1;
	b = canonicalBucket(s, b);
	if ( collecting )
	{
		if ( !s->cache[b] && nWarm < MAX_WARM )
		{
			for ( int i = 0; i < nWarm; i++ ) if ( warmList[i][0] == id && warmList[i][1] == b ) return NULL;
			warmList[nWarm][0] = (int16_t)id; warmList[nWarm][1] = (int16_t)b; nWarm++;
		}
		return NULL;
	}
	if ( !s->cache[b] && newCaches >= NEW_CACHE_BUDGET && !warming )
	{
		// a camera cut can ask for dozens of new sizes at once (a big spike on the device):
		// beyond the per-frame budget, borrow the nearest size already cached; the right one
		// gets made on a later frame
		for ( int d = 1; d <= 10; d++ )
		{
			if ( b - d >= 1 && s->cache[b - d] ) { b = b - d; break; }
			if ( b + d < BUCKETS && s->cache[b + d] ) { b = b + d; break; }
		}
	}
	if ( !s->cache[b] )
	{
		newCaches++;
		statNewCaches++;
		buildBucket(s, b);
	}
	SizeCache* c = s->cache[b];
	*w = c->w; *h = c->h; *ax = c->ax; *ay = c->ay; *cs = c->cs;
	return c->bmp;
}

// Nearest-neighbour affine blit of a (masked) bitmap straight into the frame buffer.
// (pax, pay): pivot in bitmap pixels; (PX, PY): where the pivot lands on screen.
// Inverse-maps each destination pixel centre through rotation, scale and flip (the
// Python reference is tools/assets/humanoid/anim_tracks.py `blit`). 16.16 fixed point,
// incremental along the row; rot == 0 takes a row-constant path (pure squash/stretch).
static void blitXf(LCDBitmap* bmp, float pax, float pay, float PX, float PY, float ksx, float ksy, float rotDeg, int flip)
{
	int w, h, rb;
	uint8_t* mask = NULL;
	uint8_t* data = NULL;
	pd->graphics->getBitmapData(bmp, &w, &h, &rb, &mask, &data);
	if ( !data || w <= 0 || h <= 0 ) return;
	if ( ksx < 0.1f ) ksx = 0.1f;
	if ( ksy < 0.1f ) ksy = 0.1f;
	float c = 1, s = 0;
	if ( rotDeg != 0 )
	{
		float r = rotDeg * 0.017453293f;
		c = cosf(r); s = sinf(r);
	}
	float fs = flip ? -1.0f : 1.0f;
	// screen bounding box: forward-map the four corners
	float minx = 1e9f, maxx = -1e9f, miny = 1e9f, maxy = -1e9f;
	for ( int k = 0; k < 4; k++ )
	{
		float u = ((k & 1) ? (float)w : 0.0f) - pax;
		float v = ((k & 2) ? (float)h : 0.0f) - pay;
		u *= fs * ksx; v *= ksy;
		float X = c * u - s * v, Y = s * u + c * v;
		if ( X < minx ) minx = X;
		if ( X > maxx ) maxx = X;
		if ( Y < miny ) miny = Y;
		if ( Y > maxy ) maxy = Y;
	}
	int x0 = (int)floorf(PX + minx), x1 = (int)ceilf(PX + maxx);
	int y0 = (int)floorf(PY + miny), y1 = (int)ceilf(PY + maxy);
	if ( x0 < 0 ) x0 = 0;
	if ( y0 < 0 ) y0 = 0;
	if ( x1 > LCD_COLUMNS ) x1 = LCD_COLUMNS;
	if ( y1 > LCD_ROWS ) y1 = LCD_ROWS;
	if ( x0 >= x1 || y0 >= y1 ) return;
	uint8_t* frame = pd->graphics->getFrame();
	// source coords: i = pax + fs*(c*u + s*v)/ksx ; j = pay + (-s*u + c*v)/ksy
	float iu = fs * c / ksx, iv = fs * s / ksx;
	float ju = -s / ksy, jv = c / ksy;
	const float F = 65536.0f;
	int32_t diX = (int32_t)(iu * F), djX = (int32_t)(ju * F);
	for ( int y = y0; y < y1; y++ )
	{
		float u = (float)x0 + 0.5f - PX, v = (float)y + 0.5f - PY;
		float fi = pax + iu * u + iv * v;
		float fj = pay + ju * u + jv * v;
		uint8_t* drow = frame + y * LCD_ROWSIZE;
		if ( s == 0 )
		{
			int j = (int)floorf(fj);
			if ( j < 0 || j >= h ) continue;
			const uint8_t* srow = data + j * rb;
			const uint8_t* mrow = mask ? mask + j * rb : NULL;
			int32_t I = (int32_t)(fi * F);
			for ( int x = x0; x < x1; x++, I += diX )
			{
				int i = I >> 16;
				if ( (unsigned)i >= (unsigned)w ) continue;
				uint8_t bit = (uint8_t)(0x80 >> (i & 7));
				if ( mrow && !(mrow[i >> 3] & bit) ) continue;
				uint8_t db = (uint8_t)(0x80 >> (x & 7));
				if ( srow[i >> 3] & bit ) drow[x >> 3] |= db; else drow[x >> 3] &= (uint8_t)~db;
			}
		}
		else
		{
			int32_t I = (int32_t)(fi * F), J = (int32_t)(fj * F);
			for ( int x = x0; x < x1; x++, I += diX, J += djX )
			{
				int i = I >> 16, j = J >> 16;
				if ( (unsigned)i >= (unsigned)w || (unsigned)j >= (unsigned)h ) continue;
				uint8_t bit = (uint8_t)(0x80 >> (i & 7));
				int o = j * rb + (i >> 3);
				if ( mask && !(mask[o] & bit) ) continue;
				uint8_t db = (uint8_t)(0x80 >> (x & 7));
				if ( data[o] & bit ) drow[x >> 3] |= db; else drow[x >> 3] &= (uint8_t)~db;
			}
		}
	}
	pd->graphics->markUpdatedRows(y0, y1 - 1);
}

// ---------------------------------------------------------------------------
// Per-player looks: small stamps on a puppet billboard, drawn right after it (so depth order
// holds), in the source bitmap's pixel space through the same affine as the blit — they stick
// to the figure through squash, rotation and flips. Only opaque pixels of the figure change;
// "interior" ones (all 4 neighbours opaque) so the ink contour and the white halo survive.
// Positions come from per-cell landmarks (tools/assets/humanoid sprites.py write_landmarks).
// look bits: 0-1 skin dither (0 none, 25/50/75%), 2-3 facial hair (1 moustache, 2 beard,
// 3 chin strap), 4-5 socks (1 stirrup stripe, 2 low: white to the shoe), 6 long dark sleeves,
// 7 batting helmet, 8-14 jersey number (0 = keep the baked one), 15 hands bare (no skin dither).
#define LOOK_MIN_PX 22.0f     // smaller figures: no stamps (nothing would read)
static int statLookPx = 0;    // stamp pixels visited (bc3d.lookStats)
static float lookMinPx = LOOK_MIN_PX;
static float jerseyMinPx = 1.0f;   // a glyph row's screen px below which no number is drawn
static int statJerseys = 0;        // numbers stamped (bc3d.lookStats)
static float statJerseyS = 0;      // seconds spent stamping them

typedef struct {
	const uint8_t* data; const uint8_t* mask; int w, h, rb;
	float pax, pay, PX, PY, ksx, ksy, c, s, fs;
	float iu, iv, ju, jv;
	float csx, csy;          // bitmap px per 1x cell px (x includes the body width)
	float srcPx;             // bitmap px per source-art px (the away checker's phase)
} LookXf;

static inline int lkOpaque(const LookXf* X, int i, int j)
{
	if ( (unsigned)i >= (unsigned)X->w || (unsigned)j >= (unsigned)X->h ) return 0;
	return X->mask ? ((X->mask[j * X->rb + (i >> 3)] >> (7 - (i & 7))) & 1) : 1;
}
static inline int lkWhite(const LookXf* X, int i, int j) { return (X->data[j * X->rb + (i >> 3)] >> (7 - (i & 7))) & 1; }
static inline int lkInterior(const LookXf* X, int i, int j)
{
	return lkOpaque(X, i - 1, j) && lkOpaque(X, i + 1, j) && lkOpaque(X, i, j - 1) && lkOpaque(X, i, j + 1);
}

// 3x5 digits, rows top to bottom, 3 bits each (bit 2 = left)
static const uint8_t DIG[10][5] = {
	{ 7, 5, 5, 5, 7 }, { 2, 6, 2, 2, 7 }, { 7, 1, 7, 4, 7 }, { 7, 1, 3, 1, 7 }, { 5, 5, 7, 1, 1 },
	{ 7, 4, 7, 1, 7 }, { 7, 4, 7, 5, 7 }, { 7, 1, 1, 2, 2 }, { 7, 5, 7, 5, 7 }, { 7, 5, 7, 1, 1 } };

enum { LK_SKIN, LK_BEARD, LK_MOUSTACHE, LK_CHIN, LK_SLEEVE, LK_SOCKLOW, LK_STRIPE, LK_NUMBER, LK_HELMET };
typedef struct {
	int type;
	float i0, j0, i1, j1;            // source rect (bitmap px)
	float ax, ay, bx, by, r, r2;     // circle centre / segment ends, radius
	float t0, t1;                    // segment span (0 = a, 1 = b)
	int arg;                         // skin level / number
	float nx, ny;                    // nose (face side)
	float g;                         // moustache thickness / helmet shine / number: 1 = erase only
	const Sprite* sp;                // number: the sprite (its jersey panel)
	float m00, m01, m10, m11;        // number: inverse of [jU jV] (1x px -> panel u, v)
	float gu, u0;                    // number: panel u per glyph unit, the digits' block start
	float sa, sb;                    // number: the clear span (reading u, mirror applied)
	float rcx, rcy;                  // number: 1 / bitmap px per 1x px
} LookRule;

static inline float segT(float px, float py, float ax, float ay, float bx, float by, float* d2)
{
	float vx = bx - ax, vy = by - ay;
	float l2 = vx * vx + vy * vy;
	float t = l2 > 1e-4f ? ((px - ax) * vx + (py - ay) * vy) / l2 : 0;
	float cx = ax + vx * t, cy = ay + vy * t;
	*d2 = (px - cx) * (px - cx) + (py - cy) * (py - cy);
	return t;
}

// jersey panel at bitmap pixel (i, j): -1 outside / hidden (occluded, wrapped), else bits:
// 1 a digit pixel, 2 in the baked number's columns, 4 on the away patch (the digits' block
// plus a margin). Digits: R->gu panel-u per glyph unit (1/7, or wider when the turn would
// squeeze a column under a screen px), block from R->u0; R->g = 1: no digits (erase only).
#define JPAD 0.12f    // the patch's margin above / below the digits (panel v)
static int jerseyAt(const LookRule* R, const LookXf* X, int i, int j)
{
	const Sprite* s = R->sp;
	float x = (i + 0.5f) * R->rcx - s->jO[0], y = (j + 0.5f) * R->rcy - s->jO[1];
	float u = R->m00 * x + R->m01 * y + 0.5f;
	float v = R->m10 * x + R->m11 * y + 0.5f;
	if ( u < 0 || u >= 1 || v < -JPAD || v >= 1 + JPAD ) return -1;
	int gc = (int)(u * 7), gr = (int)(v * 5);
	if ( gr < 0 ) gr = 0;
	if ( gr > 4 ) gr = 4;
	if ( !((s->jVis[gc] >> gr) & 1) ) return -1;
	int r = (gc >= 2 && gc <= 4 && v >= 0 && v < 1) ? 2 : 0;
	// a mirrored figure (lefty) still reads left to right
	float uu = X->fs < 0 ? 1.0f - u : u;
	float t = (uu - R->u0) / R->gu;
	int n = R->arg, nd = n >= 10 ? 2 : 1;
	if ( t >= -0.5f && t < nd * 4 - 0.5f && uu >= R->sa && uu < R->sb ) r |= 4;
	if ( t < 0 || v < 0 || v >= 1 || R->g != 0 ) return r;
	int dc = (int)t, row = (int)(v * 5), cx = dc % 4, digit = -1;
	if ( cx < 3 && dc < nd * 4 - 1 ) digit = nd == 2 ? (dc < 4 ? n / 10 : n % 10) : n;
	if ( digit >= 0 && ((DIG[digit][row] >> (2 - cx)) & 1) ) r |= 1;
	return r;
}

static int jerseyAwayStyle = 0;   // away: 0 a light patch with black digits, 1 black digits + white keyline

// → -1 keep, 0 black, 1 white
static int lookColor(const LookRule* R, const LookXf* X, int i, int j)
{
	float px = i + 0.5f, py = j + 0.5f;
	int white = lkWhite(X, i, j);
	switch ( R->type )
	{
	case LK_SKIN:
	{
		if ( !white ) return -1;
		float dx = px - R->ax, dy = py - R->ay;
		if ( dx * dx + dy * dy > R->r * R->r ) return -1;
		int lv = R->arg;
		int on = lv == 1 ? (((i + 2 * j) & 3) == 0) : lv == 2 ? (((i + j) & 1) == 0) : (((i + 2 * j) & 3) != 0);
		return on ? 0 : -1;
	}
	case LK_BEARD: case LK_MOUSTACHE: case LK_CHIN:
	{
		if ( !white ) return -1;
		float dx = px - R->ax, dy = py - R->ay;
		if ( dx * dx + dy * dy > R->r * R->r ) return -1;
		float r = R->r;
		float rel = (py - R->ay) / r;         // 0 = head centre, 1 = chin
		float fx = px - R->nx;                // across the face, from the nose line
		if ( R->type == LK_MOUSTACHE )
			return (rel > 0.3f && rel < 0.3f + (R->g) && fx * fx < 0.3f * r * r) ? 0 : -1;
		if ( R->type == LK_CHIN ) return (rel > 0.66f) ? 0 : -1;
		return (rel > 0.42f && fx * fx < 0.7f * r * r) ? 0 : -1;
	}
	case LK_SLEEVE:
	{
		if ( !white ) return -1;
		float d2; float t = segT(px, py, R->ax, R->ay, R->bx, R->by, &d2);
		return (t > 0.1f && t < 0.85f && d2 < R->r * R->r) ? 0 : -1;
	}
	case LK_SOCKLOW: case LK_STRIPE:
	{
		if ( white ) return -1;
		float d2; float t = segT(px, py, R->ax, R->ay, R->bx, R->by, &d2);
		return (t > R->t0 && t < R->t1 && d2 < R->r * R->r) ? 1 : -1;
	}
	case LK_NUMBER:
	{
		// printed on the back: the digits live in the pose's jersey panel (so they slant with
		// the shoulders, narrow as the torso turns, and hide behind an arm); the baked "7"
		// (columns 2-4) goes back to the jersey. Home: black digits on the white jersey. Away
		// (checker): black digits on a light patch sewn on in the same quad (style 0), or black
		// digits with a white keyline (style 1).
		int on = jerseyAt(R, X, i, j);
		if ( on < 0 ) return -1;
		int away = R->sp->jerseyAway;
		if ( on & 1 ) return 0;
		if ( away && R->g == 0 )
		{
			if ( jerseyAwayStyle == 0 && (on & 4) ) return 1;
			if ( jerseyAwayStyle == 1 && ((jerseyAt(R, X, i + 1, j) | jerseyAt(R, X, i - 1, j) | jerseyAt(R, X, i, j + 1) | jerseyAt(R, X, i, j - 1)) & 1) )
				return 1;
		}
		if ( (on & 2) && !white )
		{
			if ( !away ) return 1;
			int si = (int)((i + 0.5f) / X->srcPx), sj = (int)((j + 0.5f) / X->srcPx);
			return ((si + sj) & 1) ? 1 : 0;
		}
		return -1;
	}
	case LK_HELMET:
	{
		float dx = px - R->ax, dy = py - R->ay;
		float d2 = dx * dx + dy * dy, r = R->r;
		if ( d2 > r * r ) return -1;
		// the shine on the shell
		float hx = R->ax - (R->nx - R->ax) * 0.35f - r * 0.1f, hy = R->ay - r * 0.62f;
		float sx = px - hx, sy = py - hy;
		if ( !white && sx * sx + sy * sy < R->g * R->g ) return 1;
		// the ear flap: the side of the head away from the face, down to the jaw
		float side = (px - R->ax) * (R->nx - R->ax);
		if ( white && side < -0.05f * r * r && dy > -0.2f * r && dy < 0.55f * r ) return 0;
		return -1;
	}
	}
	return -1;
}

static void runRule(const LookRule* R, const LookXf* X, int needInterior)
{
	// screen box of the rule's source rect
	float minx = 1e9f, maxx = -1e9f, miny = 1e9f, maxy = -1e9f;
	for ( int k = 0; k < 4; k++ )
	{
		float u = ((k & 1) ? R->i1 : R->i0) - X->pax, v = ((k & 2) ? R->j1 : R->j0) - X->pay;
		u *= X->fs * X->ksx; v *= X->ksy;
		float Xs = X->c * u - X->s * v, Ys = X->s * u + X->c * v;
		if ( Xs < minx ) minx = Xs;
		if ( Xs > maxx ) maxx = Xs;
		if ( Ys < miny ) miny = Ys;
		if ( Ys > maxy ) maxy = Ys;
	}
	int x0 = (int)floorf(X->PX + minx) - 1, x1 = (int)ceilf(X->PX + maxx) + 1;
	int y0 = (int)floorf(X->PY + miny) - 1, y1 = (int)ceilf(X->PY + maxy) + 1;
	if ( x0 < 0 ) x0 = 0;
	if ( y0 < 0 ) y0 = 0;
	if ( x1 > LCD_COLUMNS ) x1 = LCD_COLUMNS;
	if ( y1 > LCD_ROWS ) y1 = LCD_ROWS;
	if ( x0 >= x1 || y0 >= y1 ) return;
	uint8_t* frame = pd->graphics->getFrame();
	for ( int y = y0; y < y1; y++ )
	{
		uint8_t* drow = frame + y * LCD_ROWSIZE;
		for ( int x = x0; x < x1; x++ )
		{
			float u = (float)x + 0.5f - X->PX, v = (float)y + 0.5f - X->PY;
			int i = (int)floorf(X->pax + X->iu * u + X->iv * v);
			int j = (int)floorf(X->pay + X->ju * u + X->jv * v);
			if ( i < R->i0 || i >= R->i1 || j < R->j0 || j >= R->j1 ) continue;
			if ( !lkOpaque(X, i, j) ) continue;
			if ( needInterior && !lkInterior(X, i, j) ) continue;
			statLookPx++;
			int col = lookColor(R, X, i, j);
			if ( col < 0 ) continue;
			uint8_t db = (uint8_t)(0x80 >> (x & 7));
			if ( col ) drow[x >> 3] |= db; else drow[x >> 3] &= (uint8_t)~db;
		}
	}
}

// stamps for billboard look `look` on sprite s, drawn with cached bitmap bmp (cs = its px per
// 1x px); affine as blitXf: pivot (pax, pay) in bitmap px lands at (PX, PY), scale, rot, flip
static void lookPass(const Sprite* s, LCDBitmap* bmp, float cs, uint32_t look, float pax, float pay,
	float PX, float PY, float ksx, float ksy, float rotDeg, int flip)
{
	LookXf X;
	uint8_t* mask = NULL; uint8_t* data = NULL;
	pd->graphics->getBitmapData(bmp, &X.w, &X.h, &X.rb, &mask, &data);
	if ( !data ) return;
	X.data = data; X.mask = mask;
	if ( ksx < 0.1f ) ksx = 0.1f;
	if ( ksy < 0.1f ) ksy = 0.1f;
	X.c = 1; X.s = 0;
	if ( rotDeg != 0 ) { float r = rotDeg * 0.017453293f; X.c = cosf(r); X.s = sinf(r); }
	X.fs = flip ? -1.0f : 1.0f;
	X.pax = pax; X.pay = pay; X.PX = PX; X.PY = PY; X.ksx = ksx; X.ksy = ksy;
	X.iu = X.fs * X.c / ksx; X.iv = X.fs * X.s / ksx; X.ju = -X.s / ksy; X.jv = X.c / ksy;
	float csx = cs * s->wx, csy = cs;
	X.csx = csx; X.csy = csy;
	X.srcPx = (cs >= 1.4f && s->src[1]) ? cs * 0.5f : cs;
	const float* L = s->lm;
	#define LX(k) (L[(k) * 2] * csx)
	#define LY(k) (L[(k) * 2 + 1] * csy)
	float hr = 2.45f * csy;                    // head radius (landmarks.json headR, 1x px)
	float hx = LX(0), hy = LY(0), nx = LX(1);
	LookRule R;
	int skin = look & 3, hair = (look >> 2) & 3, socks = (look >> 4) & 3;
	int num = (look >> 8) & 127;
	if ( skin )
	{
		memset(&R, 0, sizeof R);
		R.type = LK_SKIN; R.arg = skin;
		if ( s->faceCode > 0 )
		{
			R.ax = hx; R.ay = hy + 0.1f * hr; R.r = hr * 0.95f;
			R.i0 = hx - hr; R.i1 = hx + hr + 1; R.j0 = hy - hr; R.j1 = hy + hr + 1;
			runRule(&R, &X, 1);
		}
		if ( !(look & 0x8000) )
		{
			for ( int k = 0; k < 2; k++ )   // hands: just past each wrist
			{
				int e = 7 + k * 2, w = 8 + k * 2;
				float wx = LX(w), wy = LY(w);
				float ax = wx + (wx - LX(e)) * 0.3f, ay = wy + (wy - LY(e)) * 0.3f;
				R.ax = ax; R.ay = ay; R.r = 1.6f * csy;
				R.i0 = ax - R.r; R.i1 = ax + R.r + 1; R.j0 = ay - R.r; R.j1 = ay + R.r + 1;
				runRule(&R, &X, 1);
			}
		}
	}
	if ( (look & 64) )
	{
		memset(&R, 0, sizeof R);
		R.type = LK_SLEEVE; R.r = 1.25f * csy;
		for ( int k = 0; k < 2; k++ )
		{
			int e = 7 + k * 2, w = 8 + k * 2;
			R.ax = LX(e); R.ay = LY(e); R.bx = LX(w); R.by = LY(w);
			R.i0 = fminf(R.ax, R.bx) - R.r; R.i1 = fmaxf(R.ax, R.bx) + R.r + 1;
			R.j0 = fminf(R.ay, R.by) - R.r; R.j1 = fmaxf(R.ay, R.by) + R.r + 1;
			runRule(&R, &X, 1);
		}
	}
	if ( hair && s->faceCode > 0 )
	{
		memset(&R, 0, sizeof R);
		R.type = hair == 1 ? LK_MOUSTACHE : hair == 2 ? LK_BEARD : LK_CHIN;
		R.ax = hx; R.ay = hy; R.r = hr * 1.02f;
		R.nx = s->faceCode == 2 ? hx : hx + (nx - hx) * 0.55f;
		R.g = fmaxf(0.22f, 1.2f / hr);       // moustache thickness (in head radii): ~1 px
		R.i0 = hx - hr; R.i1 = hx + hr + 1; R.j0 = hy - hr; R.j1 = hy + hr + 1;
		runRule(&R, &X, 1);
	}
	if ( socks )
	{
		memset(&R, 0, sizeof R);
		R.type = socks == 1 ? LK_STRIPE : LK_SOCKLOW;
		R.t0 = socks == 1 ? 0.5f : 0.32f; R.t1 = socks == 1 ? 0.63f : 0.9f;
		R.r = 1.6f * csy;
		for ( int k = 0; k < 2; k++ )
		{
			int kn = 3 + k * 2, an = 4 + k * 2;
			R.ax = LX(kn); R.ay = LY(kn); R.bx = LX(an); R.by = LY(an);
			R.i0 = fminf(R.ax, R.bx) - R.r; R.i1 = fmaxf(R.ax, R.bx) + R.r + 1;
			R.j0 = fminf(R.ay, R.by) - R.r; R.j1 = fmaxf(R.ay, R.by) + R.r + 1;
			runRule(&R, &X, 1);
		}
	}
	// the number: once a glyph row is at least ~1 screen px (smaller, the baked number is the
	// 1-2 px smudge a far-off back shows). A glyph column is kept at >= 1 screen px too (digits
	// >= 3 px, a 1 px gap): a torso turned edge-on widens the glyph units within the clear span;
	// when they no longer fit, the number is dropped (the baked "7" only erased), not mangled.
	if ( num > 0 && s->hasJersey )
	{
		float det = s->jU[0] * s->jV[1] - s->jU[1] * s->jV[0];
		float rowPx = sqrtf(s->jV[0] * s->jV[0] * csx * csx * ksx * ksx + s->jV[1] * s->jV[1] * csy * csy * ksy * ksy) * 0.2f;
		float wPx = sqrtf(s->jU[0] * s->jU[0] * csx * csx * ksx * ksx + s->jU[1] * s->jU[1] * csy * csy * ksy * ksy);
		if ( fabsf(det) > 0.5f && rowPx >= jerseyMinPx )
		{
			memset(&R, 0, sizeof R);
			R.type = LK_NUMBER; R.arg = num; R.sp = s;
			R.m00 = s->jV[1] / det; R.m01 = -s->jV[0] / det; R.m10 = -s->jU[1] / det; R.m11 = s->jU[0] / det;
			R.rcx = 1.0f / csx; R.rcy = 1.0f / csy;
			// the digits in the clear span (jersey.py: no arm edge / torso side touching them),
			// narrowed to fit it but never under a screen px a glyph column
			int units = num >= 10 ? 7 : 3;
			R.sa = X.fs < 0 ? 1.0f - s->jB : s->jA;
			R.sb = X.fs < 0 ? 1.0f - s->jA : s->jB;
			float span = R.sb - R.sa;
			R.gu = fminf(1.0f / 7.0f, span / units);
			if ( wPx * R.gu < 1.0f ) R.gu = 1.0f / fmaxf(wPx, 1e-3f);
			R.u0 = (R.sa + R.sb) * 0.5f - units * R.gu * 0.5f;
			R.g = (units * R.gu > span + 0.002f) ? 1.0f : 0.0f;     // doesn't fit: erase only
			float mnx = 1e9f, mxx = -1e9f, mny = 1e9f, mxy = -1e9f;
			for ( int k = 0; k < 4; k++ )
			{
				float a = (k & 1) ? 0.5f : -0.5f, b = (k & 2) ? 0.5f + JPAD : -0.5f - JPAD;
				float px = (s->jO[0] + a * s->jU[0] + b * s->jV[0]) * csx;
				float py = (s->jO[1] + a * s->jU[1] + b * s->jV[1]) * csy;
				mnx = fminf(mnx, px); mxx = fmaxf(mxx, px); mny = fminf(mny, py); mxy = fmaxf(mxy, py);
			}
			R.i0 = floorf(mnx) - 1; R.i1 = ceilf(mxx) + 1; R.j0 = floorf(mny) - 1; R.j1 = ceilf(mxy) + 1;
			float t0 = pd->system->getElapsedTime();
			runRule(&R, &X, 1);
			statJerseyS += pd->system->getElapsedTime() - t0;
			statJerseys++;
		}
	}
	if ( look & 128 )
	{
		memset(&R, 0, sizeof R);
		R.type = LK_HELMET; R.ax = hx; R.ay = hy; R.r = hr * 1.05f; R.nx = nx;
		R.g = fmaxf(0.6f, 0.28f * hr);
		R.i0 = hx - hr - 1; R.i1 = hx + hr + 2; R.j0 = hy - hr - 1; R.j1 = hy + hr + 2;
		runRule(&R, &X, 1);
	}
	#undef LX
	#undef LY
	int y0 = (int)PY - 220; if ( y0 < 0 ) y0 = 0;
	pd->graphics->markUpdatedRows(y0, LCD_ROWS - 1);
}

static int cmpBB(const void* a, const void* b)
{
	const Billboard* p = a;
	const Billboard* q = b;
	if ( p->sd > q->sd ) return -1;
	if ( p->sd < q->sd ) return 1;
	return 0;
}

static void flushBillboards(float ox, float oy, int shadowSprite)
{
	newCaches = 0;
	// project + cull
	int n = 0;
	for ( int i = 0; i < nbb; i++ )
	{
		Billboard* b = &bbs[i];
		if ( !project(b->x, b->y, b->z, &b->sx, &b->sy, &b->depth) ) continue;
		b->sd = b->depth - (b->kind == 1 ? b->bias : 0);
		bbs[n++] = *b;
	}
	qsort(bbs, (size_t)n, sizeof(Billboard), cmpBB);
	// ball shadows first (they lie on the ground)
	for ( int i = 0; i < n; i++ )
	{
		Billboard* b = &bbs[i];
		if ( collecting || b->kind != 1 || b->z < 0.6f || !b->shadow ) continue;
		float gx, gy, gd;
		if ( !project(b->x, b->y, 0, &gx, &gy, &gd) ) continue;
		// the shadow shrinks and thins out as the ball climbs
		float hz = b->z > 120 ? 120 : b->z;
		float r = cam.scale * 0.9f / gd * (1.0f - hz / 200.0f);
		if ( r < 1.5f ) r = 1.5f;
		if ( r > 7 ) r = 7;
		static LCDPattern half = { 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
		LCDColor c = b->z > 35 ? (LCDColor)half : kColorBlack;
		pd->graphics->fillEllipse((int)floorf(gx + ox - r), (int)floorf(gy + oy - r * 0.4f), (int)(r * 2), (int)(r * 0.8f + 1), 0, 360, c);
	}
	for ( int i = 0; i < n; i++ )
	{
		Billboard* b = &bbs[i];
		float sx = b->sx + ox, sy = b->sy + oy;
		if ( collecting && b->kind != 0 ) continue;
		if ( b->kind == 0 )
		{
			Sprite* s = (b->sprite >= 0 && b->sprite < MAX_SPRITES) ? sprites[b->sprite] : NULL;
			if ( !s ) continue;
			float hpx = s->figFt * cam.scale / b->depth * b->hscale;
			if ( hpx < 3 ) hpx = 3;
			if ( hpx > BUCKETS * 2 + 10 ) continue;   // right on top of the lens: cull, don't clamp
			int w, h; float ax, ay, cs;
			LCDBitmap* bmp = spriteFor(s, b->sprite, hpx, &w, &h, &ax, &ay, &cs);
			if ( !bmp ) continue;   // collecting for the pre-warm
			if ( b->xf )
			{
				// per-billboard animatic transform, composed on top of the perspective scale
				sx += floorf(b->dx * cs + 0.5f);
				sy += floorf(b->dy * cs + 0.5f);
			}
			if ( b->xf >= 2 )
			{
				float pv = b->piv * cs;
				float r = (float)w * (b->ksx > b->ksy ? b->ksx : b->ksy) + (float)h;
				if ( sx + r < 0 || sx - r > LCD_COLUMNS || sy - pv + r < 0 || sy - pv - r > LCD_ROWS ) continue;
				float rax = floorf(ax + 0.5f), ray = floorf(ay + 0.5f);
				blitXf(bmp, rax, ray - pv, floorf(sx), floorf(sy) - pv, b->ksx, b->ksy, b->xf == 3 ? b->rot : 0, b->flip);
				if ( b->look && s->hasLm && hpx >= lookMinPx )
					lookPass(s, bmp, cs, b->look, rax, ray - pv, floorf(sx), floorf(sy) - pv, b->ksx, b->ksy, b->xf == 3 ? b->rot : 0, b->flip);
				continue;
			}
			// snap the feet pixel like the field raster does (floor), anchor rounded once:
			// no sub-pixel wobble as the camera drifts
			int iax = (int)(ax + 0.5f), iay = (int)(ay + 0.5f);
			int x = (int)floorf(sx) - (b->flip ? (w - iax) : iax);
			int y = (int)floorf(sy) - iay;
			if ( x > LCD_COLUMNS || x + w < 0 || y > LCD_ROWS || y + h < 0 ) continue;
			pd->graphics->drawBitmap(bmp, x, y, b->flip ? kBitmapFlippedX : kBitmapUnflipped);
			if ( b->look && s->hasLm && hpx >= lookMinPx )
				lookPass(s, bmp, cs, b->look, (float)iax, (float)iay, floorf(sx), floorf(sy), 1, 1, 0, b->flip);
		}
		else if ( b->kind == 1 )
		{
			// true perspective: size from distance only (the ground shadow shows height), so a
			// ball flying away shrinks and one coming at the camera grows. The radius is
			// exaggerated (0.6 ft vs a real 0.12 ft) to stay readable up close.
			float r = cam.scale * 0.6f / b->depth * b->hscale;
			if ( r > 12 ) r = 12;
			if ( r < 1.1f )
			{
				// far away: a 2x2 speck (a white disc that small would vanish)
				pd->graphics->fillRect((int)sx - 1, (int)sy - 1, 2, 2, kColorBlack);
			}
			else
			{
				int d = (int)(r * 2 + 0.5f);
				pd->graphics->fillEllipse((int)(sx - r - 1), (int)(sy - r - 1), d + 2, d + 2, 0, 360, kColorBlack);
				pd->graphics->fillEllipse((int)(sx - r), (int)(sy - r), d, d, 0, 360, kColorWhite);
			}
		}
		else
		{
			LCDColor c = (b->flip & 1) ? kColorWhite : kColorBlack;
			int sz = b->hscale >= 1.5f ? 2 : 1;
			pd->graphics->fillRect((int)sx, (int)sy, sz, sz, c);
		}
	}
	nbb = 0;
}

// ---------------------------------------------------------------------------
// Lua glue

static float argf(int i) { return pd->lua->getArgFloat(i); }
static int argIsNil(int i) { return i > pd->lua->getArgCount() || pd->lua->getArgType(i, NULL) == kTypeNil; }

// bc3d.reset() — drop geometry, sprites, caches
// park-render cache: the far / static cameras (blimp, a held wide shot) reuse the last park
// render instead of re-rasterizing the stands every frame. A raw copy of the frame-buffer rows:
// no allocation. bc3d.store() right after bc3d.render(); bc3d.restore() → true if it had one.
static uint8_t parkCache[LCD_ROWSIZE * LCD_ROWS];
static int parkCacheOk = 0;
static int l_store(lua_State* L)
{
	uint8_t* fb = pd->graphics->getFrame();
	if ( fb ) { memcpy(parkCache, fb, sizeof(parkCache)); parkCacheOk = 1; }
	return 0;
}
static int l_restore(lua_State* L)
{
	uint8_t* fb = pd->graphics->getFrame();
	if ( !parkCacheOk || !fb ) { pd->lua->pushBool(0); return 1; }
	memcpy(fb, parkCache, sizeof(parkCache));
	pd->graphics->markUpdatedRows(0, LCD_ROWS - 1);
	pd->lua->pushBool(1);
	return 1;
}
static int l_dropPark(lua_State* L) { parkCacheOk = 0; return 0; }

static int l_reset(lua_State* L)
{
	parkCacheOk = 0;
	nverts = npolys = nbb = 0;
	for ( int i = 0; i < MAX_SPRITES; i++ ) freeSprite(i);
	memset(texs, 0, sizeof(texs));
	return 0;
}

// bc3d.clearGeometry()
static int l_clearGeometry(lua_State* L) { nverts = npolys = 0; return 0; }

// bc3d.material(id, mode, amount, r0..r7)
static int l_material(lua_State* L)
{
	int id = pd->lua->getArgInt(1);
	if ( id < 0 || id >= MAX_MATS ) return 0;
	Material* m = &mats[id];
	m->mode = (uint8_t)pd->lua->getArgInt(2);
	m->amount = (uint8_t)pd->lua->getArgInt(3);
	for ( int i = 0; i < 8; i++ ) m->pat[i] = (uint8_t)pd->lua->getArgInt(4 + i);
	return 0;
}

// bc3d.poly(mat, layer, depthBias, x1,y1,z1, x2,y2,z2, ...) — up to ~20 vertices per call
// bc3d.poly(mat, layer, depthBias) followed by bc3d.v(x,y,z) calls also works.
static int l_poly(lua_State* L)
{
	if ( npolys >= MAX_POLYS ) { pd->lua->pushInt(-1); return 1; }
	Poly* P = &polys[npolys];
	P->mat = (uint8_t)pd->lua->getArgInt(1);
	P->layer = (int16_t)pd->lua->getArgInt(2);
	P->depthBias = argIsNil(3) ? 0 : argf(3);
	P->v0 = nverts;
	P->n = 0;
	P->tex = -1;
	P->tex2 = -1;
	P->br = -1;
	int argc = pd->lua->getArgCount();
	for ( int a = 4; a + 2 <= argc && nverts < MAX_VERTS; a += 3 )
	{
		verts[nverts].x = argf(a);
		verts[nverts].y = argf(a + 1);
		verts[nverts].z = argf(a + 2);
		nverts++;
		P->n++;
	}
	npolys++;
	pd->lua->pushInt(npolys - 1);
	return 1;
}

static int l_v(lua_State* L)
{
	if ( npolys == 0 || nverts >= MAX_VERTS ) return 0;
	Poly* P = &polys[npolys - 1];
	if ( P->v0 + P->n != nverts ) return 0;     // only the last poly can grow
	if ( P->n >= MAX_CLIP - 4 ) return 0;
	verts[nverts].x = argf(1);
	verts[nverts].y = argf(2);
	verts[nverts].z = argf(3);
	nverts++;
	P->n++;
	return 0;
}

// bc3d.texture(id, image, wrap, crowd) — keep the image alive on the Lua side
static int l_texture(lua_State* L)
{
	int id = pd->lua->getArgInt(1);
	if ( id < 0 || id >= MAX_TEX ) return 0;
	Texture* t = &texs[id];
	t->bmp = pd->lua->getBitmap(2);
	uint8_t* mask = NULL;
	pd->graphics->getBitmapData(t->bmp, &t->w, &t->h, &t->rb, &mask, &t->data);
	t->wrap = (uint8_t)pd->lua->getArgBool(3);
	t->crowd = (uint8_t)pd->lua->getArgBool(4);
	return 0;
}

// bc3d.polyT(mat, layer, depthBias, texId, x,y,z,u,v, ...) — textured polygon (u,v in texels)
static int l_polyT(lua_State* L)
{
	if ( npolys >= MAX_POLYS ) return 0;
	Poly* P = &polys[npolys];
	P->mat = (uint8_t)pd->lua->getArgInt(1);
	P->layer = (int16_t)pd->lua->getArgInt(2);
	P->depthBias = argf(3);
	P->tex = (int16_t)pd->lua->getArgInt(4);
	P->tex2 = -1;
	P->br = -1;
	P->v0 = nverts;
	P->n = 0;
	int argc = pd->lua->getArgCount();
	for ( int a = 5; a + 4 <= argc && nverts < MAX_VERTS && P->n < MAX_CLIP - 4; a += 5 )
	{
		verts[nverts] = (V3){ argf(a), argf(a + 1), argf(a + 2) };
		uvs[nverts * 2] = argf(a + 3);
		uvs[nverts * 2 + 1] = argf(a + 4);
		nverts++;
		P->n++;
	}
	P->tpf = 0;
	if ( P->n >= 2 )
	{
		V3 a = verts[P->v0], b = verts[P->v0 + 1];
		float dl = sqrtf((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z));
		float du = uvs[P->v0 * 2] - uvs[(P->v0 + 1) * 2], dv = uvs[P->v0 * 2 + 1] - uvs[(P->v0 + 1) * 2 + 1];
		if ( dl > 1e-3f ) P->tpf = sqrtf(du * du + dv * dv) / dl;
	}
	npolys++;
	return 0;
}

// bc3d.disc(mat, layer, x, y, z, radiusFt) — camera-facing filled disc (smoke, trees, lamps)
static int l_disc(lua_State* L)
{
	if ( npolys >= MAX_POLYS || nverts >= MAX_VERTS ) return 0;
	Poly* P = &polys[npolys++];
	P->mat = (uint8_t)pd->lua->getArgInt(1);
	P->layer = (int16_t)pd->lua->getArgInt(2);
	P->depthBias = 0;
	P->tex = -1;
	P->tex2 = -1;
	P->br = -1;
	P->v0 = nverts;
	P->n = 1;
	verts[nverts++] = (V3){ argf(3), argf(4), argf(5) };
	P->tpf = argf(6);
	return 0;
}

// bc3d.line(x1,y1,z1, x2,y2,z2, white, width, layer)
static int l_line(lua_State* L)
{
	if ( npolys >= MAX_POLYS || nverts + 2 > MAX_VERTS ) return 0;
	Poly* P = &polys[npolys++];
	P->v0 = nverts;
	P->n = 2;
	P->tex = -1;
	P->tex2 = -1;
	P->br = -1;
	verts[nverts++] = (V3){ argf(1), argf(2), argf(3) };
	verts[nverts++] = (V3){ argf(4), argf(5), argf(6) };
	P->mat = (uint8_t)pd->lua->getArgBool(7);
	P->depthBias = argIsNil(8) ? 1.0f : argf(8);
	P->layer = (int16_t)(argIsNil(9) ? 99 : pd->lua->getArgInt(9));
	return 0;
}

// bc3d.camera(ex,ey,ez, tx,ty,tz, fovDeg [, cx, cy])
static int l_camera(lua_State* L)
{
	V3 e = { argf(1), argf(2), argf(3) };
	V3 t = { argf(4), argf(5), argf(6) };
	float fov = argf(7);
	float cx = argIsNil(8) ? 200.0f : argf(8);
	float cy = argIsNil(9) ? 120.0f : argf(9);
	setCamera(e, t, fov, cx, cy);
	return 0;
}

// bc3d.project(x,y,z) → sx, sy, depth | nil
static int l_project(lua_State* L)
{
	float sx, sy, d;
	if ( !project(argf(1), argf(2), argf(3), &sx, &sy, &d) ) { pd->lua->pushNil(); return 1; }
	pd->lua->pushFloat(sx);
	pd->lua->pushFloat(sy);
	pd->lua->pushFloat(d);
	return 3;
}

// bc3d.scale() → pixels-per-foot numerator (scale)
static int l_scale(lua_State* L) { pd->lua->pushFloat(cam.scale); return 1; }

// bc3d.render([ox, oy [, y0, y1]]) — rasterize the park into the frame buffer
// bc3d.work() → flat px, crowd px, textured px, line draws, wide (>1 px) line draws of the last render
static int l_work(lua_State* L)
{
	pd->lua->pushInt(wPix); pd->lua->pushInt(wCrowd); pd->lua->pushInt(wTex); pd->lua->pushInt(wLines); pd->lua->pushInt(wWide);
	return 5;
}

// bc3d.layerWork(layer) → px filled on that polygon layer in the last render
// bc3d.renderParts() → ms in: depth pass + sort, polygon fills, lines, textures (last render)
static int l_renderParts(lua_State* L)
{
	pd->lua->pushFloat(tSort); pd->lua->pushFloat(tPoly); pd->lua->pushFloat(tLine); pd->lua->pushFloat(tTex);
	return 4;
}
// bc3d.debugRender(cull, freeze) — frustum culling on/off; freeze the animation frame counter
static int l_debugRender(lua_State* L) { cullOn = pd->lua->getArgBool(1); freezeFrame = pd->lua->getArgBool(2); debugLines = argIsNil(3) ? 0 : pd->lua->getArgInt(3); return 0; }
// bc3d.debugLine(i) → the i-th chalk line drawn last render (with debugRender(.., .., 1)):
// world xy a,b, screen xy a,b, depths, chalk px widths
static int l_debugLine(lua_State* L)
{
	int i = pd->lua->getArgInt(1);
	if ( i < 0 || i >= nDbg ) return 0;
	for ( int k = 0; k < 12; k++ ) pd->lua->pushFloat(dbgLine[i][k]);
	return 12;
}
static int l_layerWork(lua_State* L) { pd->lua->pushInt(wLayer[pd->lua->getArgInt(1) & 31]); return 1; }

static int l_render(lua_State* L)
{
	float ox = argIsNil(1) ? 0 : argf(1);
	float oy = argIsNil(2) ? 0 : argf(2);
	clipY0 = argIsNil(3) ? 0 : pd->lua->getArgInt(3);
	clipY1 = argIsNil(4) ? LCD_ROWS : pd->lua->getArgInt(4);
	if ( clipY0 < 0 ) clipY0 = 0;
	if ( clipY1 > LCD_ROWS ) clipY1 = LCD_ROWS;
	renderScene(ox, oy);
	return 0;
}

// bc3d.quality(crowdTexDist) — depth (ft) beyond which crowd textures fall back to noise
static int l_quality(lua_State* L) { crowdTexDist = argf(1); return 0; }

// bc3d.crowd(level 0..1) — how worked up the crowd texture looks
// bc3d.crowd(level 0..1 [, wave 0..1 [, flash 0..1]]) — how worked up the crowd looks; wave rolls
// a standing band across the stands, flash pops camera flashes
static int l_crowd(lua_State* L)
{
	crowdLevel = argf(1);
	crowdWave = argIsNil(2) ? 0 : argf(2);
	crowdFlash = argIsNil(3) ? 0 : argf(3);
	return 0;
}

// bc3d.alt(texId) — the last polygon added becomes a trivision board flipping to texId
static int l_alt(lua_State* L)
{
	if ( npolys > 0 ) polys[npolys - 1].tex2 = (int16_t)pd->lua->getArgInt(1);
	return 0;
}

// bc3d.diamond(mode) — bit 0 ground outlines, bit 1 chalk strokes (default 3)
static int l_diamond(lua_State* L) { diamondMode = pd->lua->getArgInt(1); return 0; }

// bc3d.renderMs() → C park render time of the last bc3d.render (ms)
static int l_renderMs(lua_State* L) { pd->lua->pushFloat(statRenderMs); return 1; }

// bc3d.sprite(id, img1x, img2x|nil, anchorX1, anchorY1, figurePx1, figureFt [, widthFactor [, landmarks]])
static int l_sprite(lua_State* L)
{
	int id = pd->lua->getArgInt(1);
	if ( id < 0 || id >= MAX_SPRITES ) return 0;
	freeSprite(id);
	Sprite* s = pd->system->realloc(NULL, sizeof(Sprite));
	memset(s, 0, sizeof(Sprite));
	s->src[0] = pd->lua->getBitmap(2);
	s->src[1] = argIsNil(3) ? NULL : pd->lua->getBitmap(3);
	for ( int k = 0; k < 2; k++ )
	{
		if ( s->src[k] ) pd->graphics->getBitmapData(s->src[k], &s->w[k], &s->h[k], NULL, NULL, NULL);
	}
	s->ax[0] = argf(4);
	s->ay[0] = argf(5);
	s->ax[1] = s->ax[0] * 2;
	s->ay[1] = s->ay[0] * 2;
	s->figH = argIsNil(6) ? (float)s->h[0] : argf(6);
	s->figFt = argIsNil(7) ? 6.2f : argf(7);
	s->wx = argIsNil(8) ? 1.0f : argf(8);
	if ( s->wx < 0.5f || s->wx > 2.0f ) s->wx = 1.0f;
	if ( !argIsNil(9) )
	{
		// landmarks: 24 chars (sprites.py write_landmarks): x y pairs at half-px, char = 40 + 2v
		const char* lm = pd->lua->getArgString(9);
		if ( lm && strlen(lm) >= 24 )
		{
			static const int at[11] = { 0, 2, 5, 8, 10, 12, 14, 16, 18, 20, 22 };
			for ( int k = 0; k < 11; k++ )
			{
				s->lm[k * 2] = ((float)lm[at[k]] - 40.0f) * 0.5f;
				s->lm[k * 2 + 1] = ((float)lm[at[k] + 1] - 40.0f) * 0.5f;
			}
			s->faceCode = (uint8_t)(lm[4] - '0');
			s->backCode = (uint8_t)(lm[7] - '0');
			s->hasLm = 1;
			// + the jersey panel (22 chars, jersey.py) and the ink ('A' away checker, 'H' home)
			if ( strlen(lm) >= 47 && lm[36] == '1' )
			{
				float q[6];
				for ( int k = 0; k < 6; k++ )
					q[k] = ((float)((lm[24 + k * 2] - 32) * 94 + (lm[25 + k * 2] - 32))) / 32.0f - 64.0f;
				s->jO[0] = q[0]; s->jO[1] = q[1]; s->jU[0] = q[2]; s->jU[1] = q[3]; s->jV[0] = q[4]; s->jV[1] = q[5];
				for ( int k = 0; k < 7; k++ ) s->jVis[k] = (uint8_t)(lm[37 + k] - 64);
				s->jA = (float)(lm[44] - 40) / 80.0f; s->jB = (float)(lm[45] - 40) / 80.0f;
				s->jerseyAway = lm[46] == 'A';
				s->hasJersey = 1;
			}
		}
	}
	sprites[id] = s;
	return 0;
}

// bc3d.bb(spriteId, x, y, z [, flip [, hscale [, sx, sy, rot, dx, dy, pivot [, look]]]]) — queue a billboard.
//   look: per-player stamps (see lookPass), drawn when the sprite has landmarks.
//   sx, sy: squash/stretch about the pivot (1 = none); rot: degrees clockwise on screen;
//   dx, dy: offset in 1x sprite pixels (scaled with the puppet); pivot: height of the
//   pivot above the feet anchor in 1x sprite pixels (0 = feet, 20 = body centre).
//   Identity / offset-only billboards keep the plain cached-bitmap draw; scale takes the
//   row-constant nearest-neighbour blit; only rot != 0 takes the rotated path.
static int l_bb(lua_State* L)
{
	if ( nbb >= MAX_BB ) return 0;
	Billboard* b = &bbs[nbb++];
	b->kind = 0;
	b->sprite = (int16_t)pd->lua->getArgInt(1);
	b->x = argf(2); b->y = argf(3); b->z = argf(4);
	b->flip = (uint8_t)pd->lua->getArgBool(5);
	b->hscale = argIsNil(6) ? 1.0f : argf(6);
	b->xf = 0;
	if ( pd->lua->getArgCount() >= 7 )
	{
		b->ksx = argIsNil(7) ? 1.0f : argf(7);
		b->ksy = argIsNil(8) ? 1.0f : argf(8);
		b->rot = argIsNil(9) ? 0.0f : argf(9);
		b->dx = argIsNil(10) ? 0.0f : argf(10);
		b->dy = argIsNil(11) ? 0.0f : argf(11);
		b->piv = argIsNil(12) ? 0.0f : argf(12);
		if ( b->rot != 0 ) b->xf = 3;
		else if ( b->ksx != 1.0f || b->ksy != 1.0f ) b->xf = 2;
		else if ( b->dx != 0 || b->dy != 0 ) b->xf = 1;
	}
	b->look = (pd->lua->getArgCount() >= 13 && !argIsNil(13)) ? (uint32_t)pd->lua->getArgInt(13) : 0;
	return 0;
}

// bc3d.ball(x, y, z [, scale [, sortBiasFt [, shadow]]]) — ball (+ ground shadow unless shadow == false)
static int l_ball(lua_State* L)
{
	if ( nbb >= MAX_BB ) return 0;
	Billboard* b = &bbs[nbb++];
	b->kind = 1;
	b->xf = 0;
	b->bias = argIsNil(5) ? 0.0f : argf(5);
	b->shadow = argIsNil(6) ? 1 : (uint8_t)pd->lua->getArgBool(6);
	b->sprite = -1;
	b->x = argf(1); b->y = argf(2); b->z = argf(3);
	b->flip = 0;
	b->hscale = argIsNil(4) ? 1.0f : argf(4);
	return 0;
}

// bc3d.dot(x, y, z, white, big) — trail dot
static int l_dot(lua_State* L)
{
	if ( nbb >= MAX_BB ) return 0;
	Billboard* b = &bbs[nbb++];
	b->kind = 2;
	b->xf = 0;
	b->sprite = -1;
	b->x = argf(1); b->y = argf(2); b->z = argf(3);
	b->flip = (uint8_t)pd->lua->getArgBool(4);
	b->hscale = pd->lua->getArgBool(5) ? 2.0f : 1.0f;
	return 0;
}

// bc3d.flush([ox, oy]) — sort and draw queued billboards
static int l_flush(lua_State* L)
{
	float ox = argIsNil(1) ? 0 : argf(1);
	float oy = argIsNil(2) ? 0 : argf(2);
	float t0 = pd->system->getElapsedTime();
	flushBillboards(ox, oy, -1);
	statFlushMs = (pd->system->getElapsedTime() - t0) * 1000.0f;
	return 0;
}

// bc3d.collect(on) — while on, flush only records the sprite sizes it would need (see warmNext)
static int l_collect(lua_State* L)
{
	collecting = pd->lua->getArgBool(1);
	if ( collecting ) nWarm = 0;
	return 0;
}

// bc3d.warmNext() → sizes still to build: builds ONE recorded sprite size per call
static int l_warmNext(lua_State* L)
{
	while ( nWarm > 0 )
	{
		nWarm--;
		int id = warmList[nWarm][0], b = warmList[nWarm][1];
		Sprite* s = (id >= 0 && id < MAX_SPRITES) ? sprites[id] : NULL;
		if ( s && !s->cache[b] ) { buildBucket(s, b); break; }
	}
	pd->lua->pushInt(nWarm);
	return 1;
}

// bc3d.warming(on) — while on, sprite caches are built without the per-frame budget (pre-warm)
static int l_warming(lua_State* L) { warming = pd->lua->getArgBool(1); return 0; }

// bc3d.dropCaches() — free scaled sprite bitmaps (keeps registrations)
static int l_dropCaches(lua_State* L)
{
	for ( int i = 0; i < MAX_SPRITES; i++ ) if ( sprites[i] ) freeSpriteCache(sprites[i]);
	return 0;
}

// bc3d.lookStats([minPx [, jerseyMinPx [, awayStyle]]]) → stamp pixels visited, jersey numbers stamped, ms
// spent stamping numbers since the last call (+ sets the min figure px / the min glyph-row px for a number)
static int l_lookStats(lua_State* L)
{
	if ( !argIsNil(1) ) lookMinPx = argf(1);
	if ( !argIsNil(2) ) jerseyMinPx = argf(2);
	if ( !argIsNil(3) ) jerseyAwayStyle = pd->lua->getArgInt(3);
	pd->lua->pushInt(statLookPx);
	pd->lua->pushInt(statJerseys);
	pd->lua->pushFloat(statJerseyS * 1000.0f);
	statLookPx = 0; statJerseys = 0; statJerseyS = 0;
	return 3;
}

// bc3d.stats() → polys, verts, polysFilled, spans
static int l_stats(lua_State* L)
{
	pd->lua->pushInt(npolys);
	pd->lua->pushInt(nverts);
	pd->lua->pushInt(statPolys);
	pd->lua->pushInt(statSpans);
	pd->lua->pushFloat(statRenderMs);
	pd->lua->pushFloat(statFlushMs);
	pd->lua->pushInt(statNewCaches);   // 7: sprite bitmaps built since the last call
	statNewCaches = 0;
	return 7;
}

// bc3d.debugPoly(i) → mat, layer, n, firstVertex xyz ; bc3d.debugMat(id) → mode, row0, row1
static int l_debugPoly(lua_State* L)
{
	int i = pd->lua->getArgInt(1);
	if ( i < 0 || i >= npolys ) return 0;
	Poly* P = &polys[i];
	pd->lua->pushInt(P->mat); pd->lua->pushInt(P->layer); pd->lua->pushInt(P->n);
	pd->lua->pushFloat(verts[P->v0].x); pd->lua->pushFloat(verts[P->v0].y); pd->lua->pushFloat(verts[P->v0].z);
	return 6;
}
static int l_debugMat(lua_State* L)
{
	int i = pd->lua->getArgInt(1);
	if ( i < 0 || i >= MAX_MATS ) return 0;
	pd->lua->pushInt(mats[i].mode); pd->lua->pushInt(mats[i].pat[0]); pd->lua->pushInt(mats[i].pat[1]);
	return 3;
}

static const lua_reg bc3dLib[] = {
	{ "debugPoly", l_debugPoly },
	{ "debugMat", l_debugMat },
	{ "reset", l_reset },
	{ "clearGeometry", l_clearGeometry },
	{ "material", l_material },
	{ "poly", l_poly },
	{ "v", l_v },
	{ "camera", l_camera },
	{ "line", l_line },
	{ "disc", l_disc },
	{ "texture", l_texture },
	{ "polyT", l_polyT },
	{ "project", l_project },
	{ "scale", l_scale },
	{ "render", l_render },
	{ "work", l_work },
	{ "layerWork", l_layerWork },
	{ "renderParts", l_renderParts },
	{ "debugRender", l_debugRender },
	{ "debugLine", l_debugLine },
	{ "store", l_store },
	{ "alt", l_alt },
	{ "diamond", l_diamond },
	{ "renderMs", l_renderMs },
	{ "restore", l_restore },
	{ "dropPark", l_dropPark },
	{ "crowd", l_crowd },
	{ "quality", l_quality },
	{ "sprite", l_sprite },
	{ "bb", l_bb },
	{ "ball", l_ball },
	{ "dot", l_dot },
	{ "flush", l_flush },
	{ "dropCaches", l_dropCaches },
	{ "warming", l_warming },
	{ "collect", l_collect },
	{ "warmNext", l_warmNext },
	{ "stats", l_stats },
	{ "lookStats", l_lookStats },
	{ NULL, NULL }
};

void bc3d_register(PlaydateAPI* playdate)
{
	pd = playdate;
	const char* err = NULL;
	if ( !pd->lua->registerClass("bc3d", bc3dLib, NULL, 1, &err) )
		pd->system->logToConsole("bc3d: registerClass failed: %s", err ? err : "?");
	for ( int i = 0; i < MAX_MATS; i++ )
	{
		memset(mats[i].pat, (i & 1) ? 0xAA : 0x55, 8);
		mats[i].mode = 0;
	}
	setCamera((V3){ 0, -95, 62 }, (V3){ 0, 150, 0 }, 64, 200, 120);
}
