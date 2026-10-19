// SportsWire: game recaps, scandal stories, life and metro stories, the Wire, BBS chatter.

export * from "./types.ts";
export { writeGameStories, boxNotes, ultraUses, enhancedGame, type UltraUse } from "./recap.ts";
export { writeLifeStories } from "./life.ts";
export { writeScandalStory, writeScandalStories } from "./scandal.ts";
export { wireLines } from "./wire.ts";
export { bbsPosts } from "./bbs.ts";
export { dateLine } from "./util.ts";
export { dramaDesk, dramaKey, dramaTags, DRAMA_TAGS } from "./drama.ts";
export { storylineDesk, rumorLine, rumorLines } from "./storylines.ts";
