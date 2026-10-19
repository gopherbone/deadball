-- Dev only: worst-case strings for layout QA. In the Simulator, when the Data folder holds a
-- file named "stress.flag", every fixture the client loads (net/fixtures.lua, BCKit.fixture)
-- is rewritten so names, clubs, handles and money are as long as real data can make them:
--   player first/last names    -> the widest in the sim's pools (Ernesto Shaughnessy)
--   club cities / nicknames     -> Tumbleweed Junction / Grasshoppers
--   account and syndicate names -> 16 characters (the server's NAME_MAX)
--   money                       -> five digits ($98,765), sign kept
-- Prose keeps its shape, so headlines, comments and letters grow with the names in them.
-- Nothing happens on hardware or without the flag.

Stress = Stress or {}

Stress.on = (playdate.isSimulator and playdate.file.exists("stress.flag")) and true or false
if Stress.on then print("[stress] worst-case fixture strings ON") end

local FIRST <const> = "Ernesto"
local LAST <const> = "Shaughnessy"
local CITY <const> = "Tumbleweed Junction"
local NICK <const> = "Grasshoppers"
local HANDLE <const> = "WallyWhammoWW_99"   -- 16, the longest name the server takes
local SYND <const> = "Wiseguys Wiseguy"     -- 16
local MONEY <const> = 98765

-- packages/sim/src/names.ts (first and last name pools)
local FIRSTS <const> = [[Archie Moose Clem Walt Eddie Lou Frank Joe Harry Tom Bill Ray Earl Gus Hank Otis Vern Cal
Rube Dutch Sal Mickey Buck Dale Russ Leon Mel Stan Floyd Ike Jimmy Tony Marty Wes Al Bert Cy Duke Emil Fritz Gil Herb
Irv Jack Kip Lefty Milo Ned Ollie Pete Quincy Rollie Sid Ted Ulysses Virgil Wally Zeke Andre Benny Carlos Darnell Ernesto
Felix Hector Isaiah Kenji Luis Manny Nate Orlando Pedro Reggie Satchel Tito Vic Willie Yogi Hideo Minnie Chico Lonnie
Dwight Rico Agnes Bea Clara Dot Edna Fern Gladys Hazel Ida June Kitty Mabel Nell Opal Pearl Rose Sadie Trudy Viola
Winnie Alma Bernice Connie Doris Estelle Flo Greta Harriet Irene Josefina Lupe Marisol Nora Olive Peggy Rita Sylvia
Thelma Vera Wanda Yolanda Ada Birdie Carmen Della Etta Frankie Ginny Hattie Keiko Lena Mavis Nadine Ruby Stella Tillie
Velma Zelda Darlene Tammy Brenda Crystal Debbie Irma Peaches Noodles]]
local LASTS <const> = [[Dunphy Mullane Whitlock Carrigan Moran Kessler Feeney Haldane McCann Okafor Ruggles Pruitt Vance
Toomey Sayre Haskins Orr Ames Delahanty Brannigan Kowalski Szymanski Lindqvist Abernathy Barrow Coogan Devlin Esposito
Fitzgerald Gallagher Hennessy Ingram Jablonski Kavanagh Lomax Mahoney Novak O'Rourke Pappas Quigley Rafferty Shaughnessy
Tierney Underhill Vukovich Wojcik Yablonski Zaleski Alvarez Batista Cruz Delgado Escobar Fuentes Guerrero Herrera Ibarra
Jimenez Luna Morales Navarro Ortega Paredes Quintana Reyes Salazar Tanaka Ueda Watanabe Yamamoto Washington Jefferson
Gibson Leonard Paige Charleston Dandridge Irvin Pettibone Crabtree Gooch Puckett Swindell Bumgardner Pinkerton Ludlow
Huckaby Stottlemyre Grimsley Wiggins Tubbs Fogarty]]
local CITIES <const> = { "Harbor City", "St. Albans", "Port Ellis", "Millbrook", "Cold Spring", "New Corinth", "Marlow",
  "Electric City", "Area Nine", "Bone Valley", "Crater City", "Mirage Flats", "Salt Basin", "Tumbleweed Junction" }
local NICKS <const> = [[Lamplighters Friars Mariners Ironmen Rustlers Grays Pilgrims Comets Canallers Spinners Colts
Ghosts Phantoms Meteors Saints Visitors Prospectors]]
local HANDLES <const> = { "Lefty Loot", "Dotty Dial", "kessler_fan69", "lampgirl", "friarfaithful", "bobbys_cousin",
  "sistr_A", "SysOp_Earl", "HotDogHal_NOT", "Gus Gumshoe", "Bettor_Bob", "Y2K_Ready", "PagerKid", "CometWatcher" }
local SYNDS <const> = { "Night Owls", "The Raccoon Lodge" }

local MONEY_KEYS <const> = {
  money = true, cash = true, net = true, paid = true, staked = true, payout = true, pool = true, price = true,
  cost = true, amount = true, treasury = true, currentBid = true, minBid = true, startBid = true, soldFor = true,
  escrow = true, yourMax = true, ask = true, median = true, low = true, high = true, value = true, moneyChange = true,
}
local HANDLE_KEYS <const> = { author = true, seller = true, founder = true, accountName = true, bidder = true }

local first, last = {}, {}
for w in FIRSTS:gmatch("%S+") do first[w] = true; first[w:upper()] = true end
for w in LASTS:gmatch("%S+") do last[w] = true; last[w:upper()] = true end
local nicks = {}
for w in NICKS:gmatch("%S+") do nicks[w] = true; nicks[w:upper()] = true end

local function plainReplace(s, from, to)
  local i = 1
  while true do
    local a, b = s:find(from, i, true)
    if not a then return s end
    s = s:sub(1, a - 1) .. to .. s:sub(b + 1)
    i = a + #to
  end
end

local function str(s)
  for _, h in ipairs(HANDLES) do
    s = plainReplace(s, h, HANDLE)
    s = plainReplace(s, h:upper(), HANDLE:upper())
  end
  for _, n in ipairs(SYNDS) do
    s = plainReplace(s, n, SYND)
    s = plainReplace(s, n:upper(), SYND:upper())
  end
  for _, c in ipairs(CITIES) do
    if c ~= CITY then
      s = plainReplace(s, c, CITY)
      s = plainReplace(s, c:upper(), CITY:upper())
    end
  end
  return (s:gsub("[%a][%a']*", function(w)
    local up = w == w:upper() and #w > 1
    if last[w] then return up and LAST:upper() or LAST end
    if first[w] then return up and FIRST:upper() or FIRST end
    if nicks[w] then return up and NICK:upper() or NICK end
    return nil
  end))
end

local function walk(t, depth)
  if depth > 12 then return end
  for k, v in pairs(t) do
    local tv = type(v)
    if tv == "string" then
      if HANDLE_KEYS[k] and v ~= "you" then t[k] = HANDLE
      elseif k ~= "id" and k ~= "abbr" and k ~= "teamId" and k ~= "face" and not (type(k) == "string" and k:find("Id$")) then
        t[k] = str(v)
      end
    elseif tv == "number" then
      if MONEY_KEYS[k] and v ~= 0 and math.type(v) == "integer" then t[k] = v < 0 and -MONEY or MONEY end
    elseif tv == "table" then
      walk(v, depth + 1)
    end
  end
end

--- Rewrites a decoded fixture in place (no-op unless the flag is set). Returns it.
function Stress.apply(name, data)
  if not Stress.on or type(data) ~= "table" then return data end
  -- the compact replay log is one long encoded string: leave its codes, stretch its people
  if type(data.logc) == "string" then
    if data.people then walk(data.people, 0) end
    if data.park then walk(data.park, 0) end
    return data
  end
  walk(data, 0)
  return data
end
