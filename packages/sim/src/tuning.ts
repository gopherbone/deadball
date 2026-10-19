// Calibration knobs. tools/calibrate.ts runs whole seasons against MLB-like targets;
// adjust these, not the model code, to move league-wide rates.

export const T = {
  // --- pitch level
  zoneBase: 0.502,
  heartShare: 0.34,       // share of in-zone pitches left over the middle
  edgeOutShare: 0.42,     // share of out-of-zone pitches near the edge
  swingHeart: 0.76,
  swingEdgeIn: 0.62,
  swingEdgeOut: 0.44,
  swingWaste: 0.21,
  contactHeart: 0.9,
  contactEdgeIn: 0.8,
  contactEdgeOut: 0.67,
  contactWaste: 0.46,
  foulHeart: 0.38,
  foulEdge: 0.47,
  foulOut: 0.5,
  twoStrikeContact: 0.09,
  twoStrikeFoul: 0.17,
  edgeStrikeCall: 0.14,   // P(called strike | edge, out of zone)
  edgeBallCall: 0.12,     // P(called ball | edge, in zone)
  hbpPerPitch: 0.0032,
  wildPitch: 0.0045,

  // --- batted balls
  evMean: 93,
  laPenalty: 0.012,
  laPenaltyCap: 25,
  evSd: 13.5,
  evUpper: 0.62,         // right tail scale (hard contact)
  evLower: 1.25,         // left tail scale (mis-hits)
  laMean: 11,
  laSd: 25,
  sprayPull: 9,
  spraySd: 21,
  groundLA: 9,

  // --- fielding
  catchBias: 0.0,
  infieldReach: 3,
  groundCleanBase: 0.96,
  transfer: 0.75,
  pivot: 0.75,
  throwErr: 0.012,

  // --- running
  homeToFirst: 4.35,
  baseToBase: 3.45,
  sendMargin: 0.12,
  stealAttempt: 0.06,

  // --- pitchers
  fatigueRamp: 22,
};
