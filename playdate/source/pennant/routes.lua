--[[ Pennant travel routes: a coarse graph of real road / main-line corridors (lon/lat waypoints),
  so a bus or train leg follows land (around the Great Lakes, never across water) and a charter flight
  is the only straight-ish line on the map. Dijkstra on great-circle miles, cached per city pair.

  PRoutes.path(a, b)  -> { points = { lon, lat, lon, lat, ... }, miles = n, mode = "bus"|"train"|"plane" }
  (a, b: club abbrs). Flights get a gentle great-circle arc (PRoutes.arc), drawn Indiana Jones style.
]]

PRoutes = PRoutes or {}

-- waypoints: key = { lon, lat, name }
local N <const> = {
  -- New England / New York
  BOS = { -71.06, 42.36 }, WOR = { -71.80, 42.26 }, SPR = { -72.59, 42.10 }, HFD = { -72.68, 41.76 },
  NHV = { -72.93, 41.31 }, NYC = { -74.00, 40.71 }, NWK = { -74.17, 40.73 }, TRN = { -74.76, 40.22 },
  PHL = { -75.16, 39.95 }, ALB = { -73.76, 42.65 }, SYR = { -76.15, 43.05 }, ROC = { -77.61, 43.16 },
  BUF = { -78.88, 42.89 }, BTV = { -73.21, 44.48 }, RUT = { -72.97, 43.61 }, WRJ = { -72.32, 43.65 },
  CON = { -71.54, 43.21 },
  -- Pennsylvania / Ohio / Indiana
  HBG = { -76.88, 40.27 }, BED = { -78.50, 40.02 }, PIT = { -80.00, 40.44 }, ERI = { -80.09, 42.13 },
  YNG = { -80.65, 41.10 }, CLE = { -81.69, 41.50 }, TOL = { -83.56, 41.65 }, WHE = { -80.72, 40.06 },
  COL = { -83.00, 39.96 }, DAY = { -84.19, 39.76 }, IND = { -86.16, 39.77 }, TRH = { -87.41, 39.47 },
  EFF = { -88.54, 39.12 }, SBN = { -86.25, 41.68 }, GAR = { -87.35, 41.60 },
  -- Illinois / Missouri / Plains
  CHI = { -87.63, 41.88 }, BLM = { -88.99, 40.48 }, SPI = { -89.65, 39.80 }, STL = { -90.20, 38.63 },
  CMO = { -92.33, 38.95 }, KCY = { -94.58, 39.10 }, TOP = { -95.68, 39.05 }, SAL = { -97.61, 38.84 },
  HAY = { -99.33, 38.88 }, LIM = { -103.69, 39.26 }, DEN = { -104.99, 39.74 },
  -- I-80 west
  DAV = { -90.58, 41.52 }, DSM = { -93.60, 41.59 }, OMA = { -95.94, 41.26 }, LNK = { -96.70, 40.80 },
  KEA = { -99.08, 40.70 }, NPL = { -100.77, 41.12 }, SID = { -102.98, 41.14 }, CHY = { -104.82, 41.14 },
  LAR = { -105.59, 41.31 }, RKS = { -109.20, 41.59 }, OGD = { -111.97, 41.22 },
  -- I-84 / the Northwest
  TWF = { -114.46, 42.56 }, BOI = { -116.20, 43.62 }, PEN = { -118.79, 45.67 }, POR = { -122.68, 45.52 },
  TAC = { -122.44, 47.25 }, SEA = { -122.33, 47.60 },
  -- the northern line (I-94 / I-90)
  MKE = { -87.91, 43.04 }, MAD = { -89.40, 43.07 }, MSP = { -93.27, 44.98 }, FAR = { -96.79, 46.88 },
  BIS = { -100.78, 46.81 }, BIL = { -108.50, 45.78 }, BTM = { -112.53, 46.00 }, MSO = { -114.00, 46.87 },
  SPK = { -117.43, 47.66 },
}

-- corridors (each a chain of waypoints)
local CORRIDORS <const> = {
  { "BOS", "WOR", "SPR", "ALB", "SYR", "ROC", "BUF", "ERI", "CLE", "TOL", "SBN", "GAR", "CHI" },   -- the Mass Pike + Thruway + I-90
  { "SPR", "HFD", "NHV", "NYC", "NWK", "TRN", "PHL" },                                            -- I-91 / I-95 / the NJ line
  { "BOS", "CON", "WRJ", "BTV" },                                                                 -- I-93 / I-89
  { "BTV", "RUT", "ALB" },                                                                        -- the Champlain valley
  { "PHL", "HBG", "BED", "PIT" },                                                                 -- the Pennsylvania Turnpike
  { "CLE", "YNG", "PIT" },
  { "PIT", "WHE", "COL", "DAY", "IND", "TRH", "EFF", "STL" },                                      -- I-70 east
  { "CHI", "BLM", "SPI", "STL" },                                                                 -- I-55 / the Alton line
  { "IND", "GAR" },
  { "STL", "CMO", "KCY", "TOP", "SAL", "HAY", "LIM", "DEN" },                                      -- I-70 west
  { "CHI", "DAV", "DSM", "OMA", "LNK", "KEA", "NPL", "SID", "CHY" },                                -- I-80 / the Overland Route
  { "CHY", "DEN" },
  { "CHY", "LAR", "RKS", "OGD" },
  { "OGD", "TWF", "BOI", "PEN", "POR" },                                                           -- I-84 / the Oregon Trail
  { "POR", "TAC", "SEA" },
  { "CHI", "MKE", "MAD", "MSP", "FAR", "BIS", "BIL", "BTM", "MSO", "SPK", "SEA" },                   -- I-94 / I-90 / the Northern Pacific
  { "KCY", "OMA" },
}

-- each club sits at a waypoint (or a short spur off one)
PRoutes.CLUB_NODE = { HCL = "BOS", STA = "BTV", PEM = "TAC", MIL = "PIT", CSR = "DEN", NCG = "TRN", MRL = "STL", ELC = "CHI" }

local rad, sin, cos, asin, sqrt = math.rad, math.sin, math.cos, math.asin, math.sqrt
--- Great-circle miles between two lon/lat points.
function PRoutes.miles(lon1, lat1, lon2, lat2)
  local dlat, dlon = rad(lat2 - lat1), rad(lon2 - lon1)
  local a = sin(dlat / 2) ^ 2 + cos(rad(lat1)) * cos(rad(lat2)) * sin(dlon / 2) ^ 2
  return 3959 * 2 * asin(sqrt(a))
end

local adj
local function build()
  adj = {}
  for k in pairs(N) do adj[k] = {} end
  local function link(a, b)
    local d = PRoutes.miles(N[a][1], N[a][2], N[b][1], N[b][2]) * 1.15   -- roads wind a little
    adj[a][#adj[a] + 1] = { b, d }
    adj[b][#adj[b] + 1] = { a, d }
  end
  for _, c in ipairs(CORRIDORS) do for i = 2, #c do link(c[i - 1], c[i]) end end
end

local function dijkstra(src, dst)
  if not adj then build() end
  local dist, prev, done = { [src] = 0 }, {}, {}
  while true do
    local u, best = nil, math.huge
    for k, d in pairs(dist) do if not done[k] and d < best then u, best = k, d end end
    if not u or u == dst then break end
    done[u] = true
    for _, e in ipairs(adj[u]) do
      local v, w = e[1], e[2]
      local nd = best + w
      if not dist[v] or nd < dist[v] then dist[v], prev[v] = nd, u end
    end
  end
  if not dist[dst] then return nil end
  local path, k = {}, dst
  while k do table.insert(path, 1, k) k = prev[k] end
  return path, dist[dst]
end

local cache = {}
PRoutes.BUS_MAX, PRoutes.TRAIN_MAX = 400, 1200

function PRoutes.path(a, b)
  local key = a .. ">" .. b
  if cache[key] then return cache[key] end
  local ca, cb = PennantClubs.byAbbr[a], PennantClubs.byAbbr[b]
  local na, nb = PRoutes.CLUB_NODE[a], PRoutes.CLUB_NODE[b]
  local nodes, miles = dijkstra(na, nb)
  local pts = { ca.ll[1], ca.ll[2] }
  for _, k in ipairs(nodes or {}) do pts[#pts + 1] = N[k][1] pts[#pts + 1] = N[k][2] end
  pts[#pts + 1] = cb.ll[1]
  pts[#pts + 1] = cb.ll[2]
  miles = math.floor((miles or PRoutes.miles(ca.ll[1], ca.ll[2], cb.ll[1], cb.ll[2])) + 0.5)
  local mode = miles < PRoutes.BUS_MAX and "bus" or (miles < PRoutes.TRAIN_MAX and "train" or "plane")
  local r = { points = pts, miles = miles, mode = mode, nodes = nodes }
  if mode == "plane" then
    r.ground = pts
    r.points = PRoutes.arc(ca.ll[1], ca.ll[2], cb.ll[1], cb.ll[2])
    r.miles = math.floor(PRoutes.miles(ca.ll[1], ca.ll[2], cb.ll[1], cb.ll[2]) + 0.5)
  end
  cache[key] = r
  cache[b .. ">" .. a] = nil
  return r
end

--- A flight's gentle arc (bulging north like a great circle on this projection), 16 segments.
function PRoutes.arc(lon1, lat1, lon2, lat2)
  local pts = {}
  local d = PRoutes.miles(lon1, lat1, lon2, lat2)
  local bulge = math.min(4, d / 600)          -- degrees of latitude at the middle
  for i = 0, 16 do
    local u = i / 16
    pts[#pts + 1] = lon1 + (lon2 - lon1) * u
    pts[#pts + 1] = lat1 + (lat2 - lat1) * u + bulge * 4 * u * (1 - u)
  end
  return pts
end

--- Time zones crossed going a -> b (negative = back an hour each).
function PRoutes.zones(a, b)
  local function zone(lon) if lon > -87.5 then return 0 elseif lon > -101 then return 1 elseif lon > -114.5 then return 2 end return 3 end
  local ca, cb = PennantClubs.byAbbr[a], PennantClubs.byAbbr[b]
  return zone(cb.ll[1]) - zone(ca.ll[1])
end

PRoutes.NODES = N

-- names for the "via" line (the bigger stops)
PRoutes.NAME = { BUF = "Buffalo", CLE = "Cleveland", CHI = "Chicago", OMA = "Omaha", ALB = "Albany", PIT = "Pittsburgh",
  STL = "St. Louis", KCY = "Kansas City", DEN = "Denver", CHY = "Cheyenne", OGD = "Ogden", BOI = "Boise", POR = "Portland",
  MSP = "Minneapolis", NYC = "New York", PHL = "Philadelphia", IND = "Indianapolis", COL = "Columbus", SPK = "Spokane",
  BIL = "Billings", TOL = "Toledo", SYR = "Syracuse", HBG = "Harrisburg", DSM = "Des Moines", NPL = "North Platte",
  SPR = "Springfield", HFD = "Hartford", MKE = "Milwaukee", FAR = "Fargo", BTM = "Butte", SEA = "Seattle" }

--- Up to n named stops along a ground route, evenly spread ("Buffalo, Chicago, Omaha").
function PRoutes.via(r, n)
  local named = {}
  for i = 2, #(r.nodes or {}) - 1 do
    local k = r.nodes[i]
    if PRoutes.NAME[k] then named[#named + 1] = PRoutes.NAME[k] end
  end
  n = n or 3
  if #named <= n then return named end
  local out = {}
  for k = 1, n do out[#out + 1] = named[math.floor((k - 0.5) * #named / n) + 1] end
  return out
end

PRoutes.MODE_NAME = { bus = "Bus", train = "Rail", plane = "Charter flight" }
