// Deterministic, seedable RNG (sfc32 seeded with cyrb128). Every sim run takes a seed
// so the server and any replay produce identical games.

function cyrb128(str: string): [number, number, number, number] {
  let h1 = 1779033703, h2 = 3144134277, h3 = 1013904242, h4 = 2773480762;
  for (let i = 0; i < str.length; i++) {
    const k = str.charCodeAt(i);
    h1 = h2 ^ Math.imul(h1 ^ k, 597399067);
    h2 = h3 ^ Math.imul(h2 ^ k, 2869860233);
    h3 = h4 ^ Math.imul(h3 ^ k, 951274213);
    h4 = h1 ^ Math.imul(h4 ^ k, 2716044179);
  }
  h1 = Math.imul(h3 ^ (h1 >>> 18), 597399067);
  h2 = Math.imul(h4 ^ (h2 >>> 22), 2869860233);
  h3 = Math.imul(h1 ^ (h3 >>> 17), 951274213);
  h4 = Math.imul(h2 ^ (h4 >>> 19), 2716044179);
  return [(h1 ^ h2 ^ h3 ^ h4) >>> 0, (h2 ^ h1) >>> 0, (h3 ^ h1) >>> 0, (h4 ^ h1) >>> 0];
}

export class Rng {
  private a: number;
  private b: number;
  private c: number;
  private d: number;
  private spareNormal: number | null = null;

  constructor(seed: string | number) {
    [this.a, this.b, this.c, this.d] = cyrb128(String(seed));
    for (let i = 0; i < 12; i++) this.u32();
  }

  u32(): number {
    let { a, b, c, d } = this;
    const t = (((a + b) | 0) + d) | 0;
    d = (d + 1) | 0;
    a = b ^ (b >>> 9);
    b = (c + (c << 3)) | 0;
    c = (c << 21) | (c >>> 11);
    c = (c + t) | 0;
    this.a = a; this.b = b; this.c = c; this.d = d;
    return t >>> 0;
  }

  /** Uniform in [0, 1). */
  float(): number {
    return this.u32() / 4294967296;
  }

  /** Integer in [0, n). */
  int(n: number): number {
    return Math.floor(this.float() * n);
  }

  range(lo: number, hi: number): number {
    return lo + (hi - lo) * this.float();
  }

  chance(p: number): boolean {
    return this.float() < p;
  }

  normal(mean = 0, sd = 1): number {
    if (this.spareNormal !== null) {
      const z = this.spareNormal;
      this.spareNormal = null;
      return mean + sd * z;
    }
    let u = 0, v = 0, s = 0;
    do {
      u = this.float() * 2 - 1;
      v = this.float() * 2 - 1;
      s = u * u + v * v;
    } while (s >= 1 || s === 0);
    const m = Math.sqrt((-2 * Math.log(s)) / s);
    this.spareNormal = v * m;
    return mean + sd * u * m;
  }

  pick<T>(xs: readonly T[]): T {
    return xs[this.int(xs.length)];
  }

  weighted<T>(items: readonly T[], weight: (x: T) => number): T {
    let total = 0;
    for (const x of items) total += Math.max(0, weight(x));
    let r = this.float() * total;
    for (const x of items) {
      r -= Math.max(0, weight(x));
      if (r < 0) return x;
    }
    return items[items.length - 1];
  }

  shuffle<T>(xs: T[]): T[] {
    for (let i = xs.length - 1; i > 0; i--) {
      const j = this.int(i + 1);
      [xs[i], xs[j]] = [xs[j], xs[i]];
    }
    return xs;
  }

  /** Derive an independent stream, e.g. per game or per subsystem. */
  fork(label: string): Rng {
    return new Rng(`${this.u32()}:${label}`);
  }
}
