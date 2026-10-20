-- The eight club identities Pennant reuses from the online league (names, logos, parks), plus
-- where each fictional city sits: ll = longitude/latitude of a plausible real spot (the travel data,
-- pennant/routes.lua and landmarks.lua, works in these); gl = longitude/latitude on the Road Map's
-- own planet (pennant/globe.lua; tools/bake_globe.py raises land under each: re-bake on a change).
-- Players are always generated fresh on the device.

PennantClubs = {
  { abbr = "HCL", city = "Harbor City", name = "Lamplighters", park = "Bellwood Park",
    fences = { 318, 368, 404, 372, 322 }, walls = { 12, 10, 10, 10, 14 }, alt = 20, foul = 45, turf = false,
    farm = { "Lockport", "Canallers" }, ll = { -71.1, 42.4 }, gl = { 62, -11 } },
  { abbr = "STA", city = "St. Albans", name = "Friars", park = "Sanctuary Field",
    fences = { 335, 380, 410, 380, 335 }, walls = { 8, 8, 8, 8, 8 }, alt = 300, foul = 70, turf = false,
    farm = { "Rutland", "Monks" }, ll = { -73.1, 44.8 }, gl = { 40, 40 } },
  { abbr = "PEM", city = "Port Ellis", name = "Mariners", park = "Wharf Street Grounds",
    fences = { 310, 355, 395, 360, 305 }, walls = { 25, 12, 10, 12, 8 }, alt = 5, foul = 35, turf = false,
    farm = { "Tidewater", "Gulls" }, ll = { -122.4, 47.4 }, gl = { -60, 17 } },
  { abbr = "MIL", city = "Millbrook", name = "Ironmen", park = "Furnace Field",
    fences = { 330, 375, 400, 375, 330 }, walls = { 10, 10, 10, 10, 10 }, alt = 900, foul = 50, turf = true,
    farm = { "Slag Hollow", "Stokers" }, ll = { -80.0, 40.4 }, gl = { 44, 3 } },
  { abbr = "CSR", city = "Cold Spring", name = "Rustlers", park = "Stockyard Park",
    fences = { 340, 385, 415, 385, 340 }, walls = { 8, 8, 12, 8, 8 }, alt = 5200, foul = 60, turf = false,
    farm = { "Dry Gulch", "Drovers" }, ll = { -104.9, 39.6 }, gl = { -34, -13 } },
  { abbr = "NCG", city = "New Corinth", name = "Grays", park = "Corinth Commons",
    fences = { 325, 370, 400, 370, 325 }, walls = { 10, 10, 10, 10, 10 }, alt = 150, foul = 55, turf = false,
    farm = { "Old Saybrook", "Squires" }, ll = { -74.6, 40.3 }, gl = { 48, -24 } },
  { abbr = "MRL", city = "Marlow", name = "Pilgrims", park = "Plymouth Yard",
    fences = { 345, 385, 420, 385, 345 }, walls = { 10, 10, 16, 10, 10 }, alt = 400, foul = 65, turf = false,
    farm = { "Canaan", "Settlers" }, ll = { -90.3, 38.6 }, gl = { -4, -29 } },
  { abbr = "ELC", city = "Electric City", name = "Comets", park = "Dynamo Stadium",
    fences = { 320, 360, 395, 360, 320 }, walls = { 10, 10, 10, 10, 10 }, alt = 600, foul = 40, turf = true,
    farm = { "Kilowatt", "Sparks" }, ll = { -87.8, 42.0 }, gl = { 6, 19 } },
}

PennantClubs.byAbbr = {}
for i, c in ipairs(PennantClubs) do
  c.idx = i
  PennantClubs.byAbbr[c.abbr] = c
end
