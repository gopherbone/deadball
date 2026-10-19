// Runs N AI games of pdsim on a QEMU Cortex-M7 (mps2-an500) to count instructions per game.
// Build/run: ./m7.sh. Teams are the first two of the calibration league (compiled in).
#include "../../pdsim_core.h"
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "teams.h"   // const char HOME_JSON[], AWAY_JSON[]

extern int main(void);
extern void _start(void);
extern unsigned __stack;
__attribute__((naked)) void Reset_Handler(void)
{
	__asm volatile(
		"ldr r0, =0xE000ED88\n"     // CPACR: enable CP10/CP11 (FPU)
		"ldr r1, [r0]\n"
		"orr r1, r1, #(0xF << 20)\n"
		"str r1, [r0]\n"
		"dsb\n isb\n"
		"ldr r0, =0x00400000\n mov sp, r0\n"
		"b _start\n");
}
static void Default_Handler(void) { for ( ;; ) {} }
// SysTick runs off QEMU's virtual clock (with -icount: a fixed time per instruction)
static void SysTick_Handler(void) {}
#define SYST_CSR (*(volatile unsigned*)0xE000E010)
#define SYST_RVR (*(volatile unsigned*)0xE000E014)
#define SYST_CVR (*(volatile unsigned*)0xE000E018)
static void tickStart(void) { SYST_RVR = 0xFFFFFF; SYST_CVR = 0; SYST_CSR = 5; }
// no interrupt: one 24-bit period is far longer than one game; deltas are taken mod 2^24
static unsigned ticks(void) { return 0xFFFFFFu - SYST_CVR; }
static unsigned since(unsigned t0) { return (ticks() - t0) & 0xFFFFFFu; }
__attribute__((section(".vectors"), used)) void (*const vectors[16])(void) = {
	(void (*)(void))0x00400000, Reset_Handler, Default_Handler, Default_Handler, Default_Handler, Default_Handler, Default_Handler,
	0, 0, 0, 0, Default_Handler, Default_Handler, 0, Default_Handler, SysTick_Handler,
};

static PdGame G;
static PdTeam H, A;
static char buf[65536];

int main(void)
{
	char err[96];
	if ( pd_team_from_json(&H, HOME_JSON, strlen(HOME_JSON), err, sizeof err) ) { printf("home: %s\n", err); return 1; }
	if ( pd_team_from_json(&A, AWAY_JSON, strlen(AWAY_JSON), err, sizeof err) ) { printf("away: %s\n", err); return 1; }
	PdPark park = { { 318, 368, 404, 372, 322 }, { 12, 10, 10, 10, 14 }, 20, 45, 0 };
	PdWeather wx = { 72, 0, 5 }; PdUmp ump = { 50, 50 };
	// calibration: exactly 2 instructions per iteration (subs + bne)
	tickStart();
	unsigned c0 = ticks();
	unsigned n0 = 2000000u;
	__asm volatile("1: subs %0, %0, #1\n bne 1b\n" : "+r"(n0) :: "cc");
	unsigned dc = since(c0);
	double ipt = 4e6 / (double)dc;
	printf("calibration: 4e6 instructions = %u systicks (%.3f instr/tick)\n", dc, ipt);
	int N = 100, runs = 0, ev = 0;
	double tRun = 0, tMax = 0;
	for ( int i = 0; i < N; i++ ) {
		char seed[24]; snprintf(seed, sizeof seed, "m7-%d", i);
		pd_game_init(&G, &H, &A, &park, &wx, &ump, seed, 1);
		unsigned a = ticks();
		pd_run_all(&G);
		double d = (double)since(a);
		tRun += d; if ( d > tMax ) tMax = d;
		runs += G.side[0].runs + G.side[1].runs; ev += G.nev;
	}
	// spec JSON parse + game + box JSON (the pdsim.simulate C path)
	static char spec[80000];
	int n = snprintf(spec, sizeof spec, "{\"seed\":\"x\",\"home\":%s,\"away\":%s}", HOME_JSON, AWAY_JSON);
	double tJ = 0;
	for ( int i = 0; i < N; i++ ) {
		spec[9] = (char)('a' + i % 26);
		unsigned a = ticks();
		pd_game_from_json(&G, spec, (size_t)n, 0); pd_run_all(&G); pd_box_json(&G, buf, sizeof buf);
		tJ += (double)since(a);
	}
	double tP = 0;
	for ( int i = 0; i < N; i++ ) {
		unsigned a = ticks();
		pd_game_from_json(&G, spec, (size_t)n, 0);
		tP += (double)since(a);
	}
	printf("games %d runs/game %d events/game %d\n", N, runs / N, ev / N);
	printf("run_all (with log): %.2f M instructions/game (max %.2f)\n", tRun * ipt / N / 1e6, tMax * ipt / 1e6);
	printf("spec parse + run + box JSON (no log): %.2f M instructions/game\n", tJ * ipt / N / 1e6);
	printf("spec parse alone: %.2f M instructions\n", tP * ipt / N / 1e6);
	return 0;
}
