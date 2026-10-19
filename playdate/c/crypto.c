// dbcrypto: SHA-256 and HMAC-SHA256 for signing plain-HTTP API requests (net/api.lua).
// Lua: dbcrypto.sha256_hex(s) -> 64 hex chars; dbcrypto.hmac_sha256_hex(key, msg) -> 64 hex chars.
// Strings may contain any bytes. Checked against FIPS 180-2 / RFC 4231 vectors (dbcrypto.selftest()).
#include <string.h>
#include <stdint.h>
#include "crypto.h"

static PlaydateAPI* pd = NULL;

typedef struct { uint32_t h[8]; uint64_t len; uint8_t buf[64]; size_t n; } sha256_ctx;

static const uint32_t K[64] = {
	0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
	0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
	0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
	0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
	0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
	0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
	0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
	0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(sha256_ctx* c, const uint8_t* p)
{
	uint32_t w[64], a, b, cc, d, e, f, g, h;
	for ( int i = 0; i < 16; i++ )
		w[i] = (uint32_t)p[i*4] << 24 | (uint32_t)p[i*4+1] << 16 | (uint32_t)p[i*4+2] << 8 | p[i*4+3];
	for ( int i = 16; i < 64; i++ ) {
		uint32_t s0 = ROR(w[i-15], 7) ^ ROR(w[i-15], 18) ^ (w[i-15] >> 3);
		uint32_t s1 = ROR(w[i-2], 17) ^ ROR(w[i-2], 19) ^ (w[i-2] >> 10);
		w[i] = w[i-16] + s0 + w[i-7] + s1;
	}
	a = c->h[0]; b = c->h[1]; cc = c->h[2]; d = c->h[3]; e = c->h[4]; f = c->h[5]; g = c->h[6]; h = c->h[7];
	for ( int i = 0; i < 64; i++ ) {
		uint32_t t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
		uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & cc) ^ (b & cc));
		h = g; g = f; f = e; e = d + t1; d = cc; cc = b; b = a; a = t1 + t2;
	}
	c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += d; c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += h;
}

static void sha256_init(sha256_ctx* c)
{
	static const uint32_t H0[8] = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 };
	memcpy(c->h, H0, sizeof H0);
	c->len = 0; c->n = 0;
}

static void sha256_update(sha256_ctx* c, const uint8_t* p, size_t len)
{
	c->len += len;
	while ( len > 0 ) {
		size_t take = 64 - c->n;
		if ( take > len ) take = len;
		memcpy(c->buf + c->n, p, take);
		c->n += take; p += take; len -= take;
		if ( c->n == 64 ) { sha256_block(c, c->buf); c->n = 0; }
	}
}

static void sha256_final(sha256_ctx* c, uint8_t out[32])
{
	uint64_t bits = c->len * 8;
	uint8_t pad = 0x80;
	sha256_update(c, &pad, 1);
	pad = 0;
	while ( c->n != 56 ) sha256_update(c, &pad, 1);
	uint8_t lenb[8];
	for ( int i = 0; i < 8; i++ ) lenb[i] = (uint8_t)(bits >> (56 - 8 * i));
	sha256_update(c, lenb, 8);
	for ( int i = 0; i < 8; i++ ) {
		out[i*4] = (uint8_t)(c->h[i] >> 24); out[i*4+1] = (uint8_t)(c->h[i] >> 16);
		out[i*4+2] = (uint8_t)(c->h[i] >> 8); out[i*4+3] = (uint8_t)c->h[i];
	}
}

static void sha256(const uint8_t* p, size_t len, uint8_t out[32])
{
	sha256_ctx c;
	sha256_init(&c);
	sha256_update(&c, p, len);
	sha256_final(&c, out);
}

static void hmac_sha256(const uint8_t* key, size_t klen, const uint8_t* msg, size_t mlen, uint8_t out[32])
{
	uint8_t k[64], pad[64], inner[32];
	memset(k, 0, sizeof k);
	if ( klen > 64 ) sha256(key, klen, k); else memcpy(k, key, klen);
	sha256_ctx c;
	for ( int i = 0; i < 64; i++ ) pad[i] = k[i] ^ 0x36;
	sha256_init(&c); sha256_update(&c, pad, 64); sha256_update(&c, msg, mlen); sha256_final(&c, inner);
	for ( int i = 0; i < 64; i++ ) pad[i] = k[i] ^ 0x5c;
	sha256_init(&c); sha256_update(&c, pad, 64); sha256_update(&c, inner, 32); sha256_final(&c, out);
}

static void tohex(const uint8_t d[32], char out[65])
{
	static const char* hx = "0123456789abcdef";
	for ( int i = 0; i < 32; i++ ) { out[i*2] = hx[d[i] >> 4]; out[i*2+1] = hx[d[i] & 15]; }
	out[64] = 0;
}

static int l_sha256_hex(lua_State* L)
{
	(void)L;
	size_t len = 0;
	const char* s = pd->lua->getArgBytes(1, &len);
	if ( !s ) { s = ""; len = 0; }
	uint8_t d[32]; char hex[65];
	sha256((const uint8_t*)s, len, d);
	tohex(d, hex);
	pd->lua->pushString(hex);
	return 1;
}

static int l_hmac_sha256_hex(lua_State* L)
{
	(void)L;
	size_t klen = 0, mlen = 0;
	const char* k = pd->lua->getArgBytes(1, &klen);
	const char* m = pd->lua->getArgBytes(2, &mlen);
	if ( !k ) { k = ""; klen = 0; }
	if ( !m ) { m = ""; mlen = 0; }
	uint8_t d[32]; char hex[65];
	hmac_sha256((const uint8_t*)k, klen, (const uint8_t*)m, mlen, d);
	tohex(d, hex);
	pd->lua->pushString(hex);
	return 1;
}

// Known-answer tests: FIPS 180-2 "abc" / "" and RFC 4231 cases 1, 2 and 6 (131-byte key).
static int l_selftest(lua_State* L)
{
	(void)L;
	uint8_t d[32], key[131], data[20]; char hex[65];
	int ok = 1;
	sha256((const uint8_t*)"abc", 3, d); tohex(d, hex);
	ok &= strcmp(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") == 0;
	sha256((const uint8_t*)"", 0, d); tohex(d, hex);
	ok &= strcmp(hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") == 0;
	memset(key, 0x0b, 20);
	hmac_sha256(key, 20, (const uint8_t*)"Hi There", 8, d); tohex(d, hex);
	ok &= strcmp(hex, "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7") == 0;
	hmac_sha256((const uint8_t*)"Jefe", 4, (const uint8_t*)"what do ya want for nothing?", 28, d); tohex(d, hex);
	ok &= strcmp(hex, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843") == 0;
	memset(key, 0xaa, 131);
	const char* m6 = "Test Using Larger Than Block-Size Key - Hash Key First";
	hmac_sha256(key, 131, (const uint8_t*)m6, strlen(m6), d); tohex(d, hex);
	ok &= strcmp(hex, "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54") == 0;
	(void)data;
	pd->lua->pushBool(ok);
	return 1;
}

static const lua_reg dbcryptoLib[] = {
	{ "sha256_hex", l_sha256_hex },
	{ "hmac_sha256_hex", l_hmac_sha256_hex },
	{ "selftest", l_selftest },
	{ NULL, NULL },
};

void dbcrypto_register(PlaydateAPI* playdate)
{
	pd = playdate;
	const char* err = NULL;
	if ( !pd->lua->registerClass("dbcrypto", dbcryptoLib, NULL, 1, &err) )
		pd->system->logToConsole("dbcrypto: registerClass failed: %s", err ? err : "?");
}
