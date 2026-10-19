#!/usr/bin/env python3
"""Writes the shell's offline dev fixtures (playdate/source/fixtures_dev/*.json).

They follow docs/API.md exactly and are only used when no server host is configured
and the server agent's playdate/source/fixtures/ doesn't have the file.
Run: python3 playdate/tools/make_dev_fixtures.py
"""
import json, os, random

OUT = os.path.join(os.path.dirname(__file__), "..", "source", "fixtures_dev")
os.makedirs(OUT, exist_ok=True)
R = random.Random(62)

NOW = 1760000000000
# keep times consistent with the server agent's fixtures (they win the clock lookup)
_srv = os.path.join(os.path.dirname(__file__), "..", "source", "fixtures", "clock.json")
if os.path.exists(_srv):
    NOW = int(json.load(open(_srv))["now"])
DAY_MS = 30 * 60 * 1000
SEASON, DAY = 4, 62

def w(name, obj):
    with open(os.path.join(OUT, name + ".json"), "w") as f:
        json.dump(obj, f, separators=(",", ":"), ensure_ascii=False)

TEAMS = [
    ("HCL", "Harbor City", "Lamplighters", "The Haldane Organization", [("Lockport", "Canallers"), ("Fall River", "Spinners"), ("Bellwood", "Colts")], "Bellwood Park"),
    ("STA", "St. Albans", "Friars", "The Archdiocese of St. Albans", [("Gilead", "Bees"), ("Cairo", "Tobacconists"), ("Oneida", "Owls")], "Sanctuary Field"),
    ("PEM", "Port Ellis", "Mariners", "Port Ellis Shipping Trust", [("Natchez", "Rivermen"), ("Yazoo", "Clamdiggers"), ("Bristol", "Whalers")], "Wharf Street Grounds"),
    ("MIL", "Millbrook", "Ironmen", "Millbrook Steel", [("Ironton", "Smelters"), ("Wheeling", "Coal Barons"), ("Tullahoma", "Haymakers")], "Furnace Field"),
    ("CSR", "Cold Spring", "Rustlers", "Cold Spring Cattle Company", [("Laramie", "Prospectors"), ("Durango", "Tanners"), ("Sedalia", "Possums")], "Stockyard Park"),
    ("NCG", "New Corinth", "Grays", "The Corinth Club", [("Utica", "Typewriters"), ("Elmira", "Millers"), ("Rome", "Locomotives")], "Corinth Commons"),
    ("MRL", "Marlow", "Pilgrims", "Brother Amos's Fellowship", [("Quincy", "Crawdads"), ("Macon", "Hornets"), ("Keokuk", "Pickles")], "Plymouth Yard"),
    ("ELC", "Electric City", "Comets", "Volta Power & Light", [("Joliet", "Lumberjacks"), ("Dunmore", "Soapmakers"), ("Hatboro", "Grasshoppers")], "Dynamo Stadium"),
]
LEVELS = ["ML", "AA", "B", "D"]

def tref(abbr, level="ML"):
    t = next(t for t in TEAMS if t[0] == abbr)
    if level == "ML":
        return {"id": abbr, "abbr": abbr, "city": t[1], "name": t[2], "level": "ML"}
    i = LEVELS.index(level) - 1
    c, n = t[4][i]
    return {"id": abbr + level, "abbr": abbr + level, "city": c, "name": n, "level": level}

def money(n):
    return n

# ---- people
FIRST = ["Archie", "Moose", "Clem", "Walt", "Eddie", "Lou", "Frank", "Gus", "Hank", "Otis", "Vern", "Rube", "Dutch", "Sal",
         "Buck", "Leon", "Floyd", "Ike", "Wes", "Bert", "Cy", "Duke", "Emil", "Fritz", "Kip", "Milo", "Ned", "Ollie", "Rollie",
         "Zeke", "Benny", "Hector", "Kenji", "Manny", "Orlando", "Satchel", "Tito", "Minnie", "Chico", "Rico"]
LAST = ["Dunphy", "Mullane", "Whitlock", "Carrigan", "Moran", "Kessler", "Feeney", "McCann", "Okafor", "Ruggles", "Pruitt",
        "Toomey", "Sayre", "Haskins", "Delahanty", "Brannigan", "Kowalski", "Lindqvist", "Abernathy", "Coogan", "Devlin",
        "Gallagher", "Hennessy", "Jablonski", "Lomax", "Mahoney", "Novak", "O'Rourke", "Pappas", "Quigley", "Rafferty",
        "Tierney", "Vukovich", "Zaleski", "Alvarez", "Delgado", "Fuentes", "Herrera", "Tanaka", "Paige", "Crabtree", "Gooch",
        "Puckett", "Swindell", "Pinkerton", "Huckaby", "Grimsley", "Tubbs", "Fogarty", "Pickles"]
NICKS = ["Moose", "Lefty", "Specs", "Pops", "Kid", "Slats", "Sudsy", "Hambone", "Doc", "Spider", "Gabby", "Peaches", "Boots",
         "Tank", "Noodles", "Sarge", "Rabbit", "Stinky", "Red", "Ducky", "Bones", "Mule", "Preacher", "Jitters"]
TRAITS = ["HOTHEAD", "LOYAL", "SUPERSTITIOUS", "GAMBLER", "DRUNK", "CLUTCH", "CHOKER", "GREEDY", "PIOUS", "SHOWBOAT",
          "GRINDER", "LAZY", "PARANOID", "IRON_MAN", "FRAGILE", "CHARMING", "CROOKED", "SNITCH"]
POS = ["P", "P", "P", "P", "P", "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF"]

people = {}
pid = [0]
used = set()

_fj = os.path.join(os.path.dirname(__file__), "..", "source", "images", "faces", "faces.json")
FACES_M, FACES_F = list(range(600)), list(range(600))
if os.path.exists(_fj):
    _fl = json.load(open(_fj))["faces"]
    FACES_M = [x["n"] for x in _fl if x.get("sex") == "M"] or FACES_M
    FACES_F = [x["n"] for x in _fl if x.get("sex") == "F"] or FACES_F
FEMALE = {"Sister Agnes", "Minnie Zaleski", "Edna Pruitt", "Madame Zora", "Peaches Delgado"}

def pick_face(name, hint):
    pool = FACES_F if name in FEMALE else FACES_M
    if hint is not None:
        return pool[hint % len(pool)]
    return R.choice(pool)

def person(name=None, face=None, team=None, pos=None):
    pid[0] += 1
    i = pid[0]
    if not name:
        while True:
            name = R.choice(FIRST) + " " + R.choice(LAST)
            if name not in used:
                break
    used.add(name)
    p = {"id": "p%d" % i, "name": name, "face": "face:%d" % pick_face(name, face)}
    if team:
        p["teamAbbr"] = team
    if pos:
        p["pos"] = pos
    people[p["id"]] = p
    return p

def ref(p):
    return dict(p)

# Named characters from the mockups
moose = person("Moose Mullane", 12, "HCL", "1B")
dunphy = person("Ace Dunphy", 33, "HCL", "P")
whitlock = person("Cal Whitlock", 41, "STA", "P")
haldane = person("T. Haldane", 7, None, None)
feeney = person("Sal Feeney", 88, None, None)
okafor = person('Kid Okafor', 120, "HCLAA", "SS")
kessler = person("Gus Kessler", 64, "HCL", None)
carrigan = person("Rollie Carrigan", 55, "STA", "CF")
agnes = person("Sister Agnes", 140, None, None)
lefty = person('"Lefty" Ruggles', 151, None, None)
hal = person("Hot Dog Hal", 160, None, None)
ozzie = person("Big Ozzie", 171, None, None)
bobby = person("Bobby", 5, None, None)
zaleski = person("Minnie Zaleski", 53, None, None)
amos = person("Brother Amos", 21, None, None)

rosters = {}
for t in TEAMS:
    for lv in LEVELS:
        ab = tref(t[0], lv)["abbr"]
        lst = []
        for k in range(14 if lv == "ML" else 10):
            pos = POS[k % len(POS)]
            lst.append(person(team=ab, pos=pos))
        rosters[ab] = lst
rosters["HCL"][0] = dunphy
rosters["HCL"][6] = moose
rosters["STA"][0] = whitlock
rosters["STA"][11] = carrigan
rosters["HCLAA"][9] = okafor

def line_for(p):
    if p.get("pos") == "P":
        return "%d-%d, %.2f" % (R.randint(2, 12), R.randint(2, 10), R.uniform(1.8, 6.2))
    return ".%03d, %d HR" % (R.randint(190, 340), R.randint(0, 22))

# ---- clock & me
clock = {"now": NOW, "season": SEASON, "day": DAY, "phase": "regular", "nextDayAt": NOW + 17 * 60 * 1000, "msPerDay": DAY_MS, "year": 1}
w("clock", clock)
account = {"id": "a1", "name": "kessler_fan69", "money": 1240, "heat": 3, "crewSize": 4, "unreadMail": 3, "cards": 23, "joinedDay": 40, "rank": "Grifter", "syndicateId": "syn1"}
w("me", {"account": account})
w("register", {"token": "dev-token-123", "account": dict(account, money=1000, heat=0, crewSize=0, unreadMail=1, cards=0, joinedDay=DAY, rank="Rube")})

# ---- standings
records = {}
def standings(level):
    rows = []
    for t in TEAMS:
        ab = tref(t[0], level)
        wv = R.randint(22, 38)
        lv = DAY // 2 - wv + R.randint(-3, 3)
        lv = max(lv, 18)
        rows.append({"teamId": ab["id"], "team": ab, "w": wv, "l": lv, "streak": R.choice(["W", "L"]) + str(R.randint(1, 5)),
                     "last10": "%d-%d" % (x := R.randint(2, 8), 10 - x), "rs": R.randint(190, 300), "ra": R.randint(190, 300)})
    rows.sort(key=lambda r: -(r["w"] / (r["w"] + r["l"])))
    top = rows[0]
    for r in rows:
        r["gb"] = ((top["w"] - r["w"]) + (r["l"] - top["l"])) / 2
        records[r["teamId"]] = "%d-%d" % (r["w"], r["l"])
    return {"level": level, "rows": rows}
for lv in LEVELS:
    w("standings-" + lv, standings(lv))

def team_rec(abbr, level="ML"):
    t = tref(abbr, level)
    t["record"] = records.get(t["id"], "30-30")
    return t

# ---- today's slate
WEATHER = ["72F wind out 5", "61F drizzle", "88F still", "55F wind in 12", "79F humid", "67F gusty"]
PAIRS = [("STA", "HCL", "final"), ("MIL", "PEM", "live"), ("CSR", "ELC", "live"), ("NCG", "MRL", "scheduled"), ("PEM", "STA", "scheduled")]
games = []
gi = 0
for away, home, status in PAIRS:
    gi += 1
    hp, ap = rosters[home][0], rosters[away][0]
    poolH, poolA = R.randint(9, 120) * 100 + R.randint(0, 99), R.randint(9, 120) * 100 + R.randint(0, 99)
    tot = (poolH + poolA) * 0.9
    g = {"id": "g%d" % (6200 + gi), "day": DAY, "firstPitchAt": NOW + (gi - 3) * 9 * 60 * 1000, "status": status,
         "home": team_rec(home), "away": team_rec(away),
         "probables": {"home": dict(ref(hp), line=line_for(hp)), "away": dict(ref(ap), line=line_for(ap))},
         "pool": {"home": poolH, "away": poolA, "pays": {"home": round(tot / poolH, 2), "away": round(tot / poolA, 2)}},
         "umpire": ref(zaleski) if gi == 1 else ref(person()), "weather": WEATHER[gi % len(WEATHER)],
         "park": next(t[5] for t in TEAMS if t[0] == home)}
    if status != "scheduled":
        g["score"] = {"home": R.randint(0, 9), "away": R.randint(0, 9), "inning": "F" if status == "final" else R.choice(["T4", "B6", "T7"])}
    if gi == 1:
        g["myBet"] = {"side": "away", "amount": 50}
        g["score"] = {"home": 1, "away": 7, "inning": "F"}
    if gi == 4:
        g["myBet"] = {"side": "home", "amount": 120}
    games.append(g)
w("today", {"day": DAY, "games": games})
w("schedule", {"games": games + [dict(games[3], id="g6301", day=DAY + 1, status="scheduled", firstPitchAt=NOW + DAY_MS, myBet=None)]})

def box_side(abbr):
    bat = []
    for p in rosters[abbr][5:14]:
        ab = R.randint(3, 5); h = R.randint(0, min(3, ab))
        bat.append({"p": ref(p), "ab": ab, "r": R.randint(0, h), "h": h, "rbi": R.randint(0, h), "bb": R.randint(0, 1), "k": R.randint(0, 2), "avg": ".%03d" % R.randint(200, 330)})
    pitch = [{"p": ref(rosters[abbr][0]), "ip": "6.1", "h": 7, "r": 3, "er": 3, "bb": 2, "k": 5, "pc": 98},
             {"p": ref(rosters[abbr][1]), "ip": "2.2", "h": 1, "r": 0, "er": 0, "bb": 0, "k": 3, "pc": 34}]
    return {"bat": bat, "pitch": pitch, "r": sum(b["r"] for b in bat), "h": sum(b["h"] for b in bat), "e": R.randint(0, 2)}

for g in games:
    d = dict(g)
    if g["status"] != "scheduled":
        d["box"] = {"home": box_side(g["home"]["abbr"]), "away": box_side(g["away"]["abbr"])}
        n = 9 if g["status"] == "final" else 6
        d["line"] = {"home": [R.choice([0, 0, 0, 1, 2]) for _ in range(n)] + [None] * (9 - n),
                     "away": [R.choice([0, 0, 1, 1, 3]) for _ in range(n)] + [None] * (9 - n)}
        d["line"]["home"] = d["line"]["home"]
    d["incidents"] = [{"inning": 6, "text": "Raccoons loosed in Friars bullpen; 9-minute delay."}] if g["id"] == "g6201" else []
    if g["status"] == "final":
        d["decisions"] = {"w": ref(g["probables"]["away"]), "l": ref(g["probables"]["home"])}
        d["storyId"] = "s1"
    w("game-" + g["id"], d)
w("game", dict(games[0], incidents=[]))

# ---- bets
bets_open = [{"id": "b1", "gameId": games[3]["id"], "side": "home", "amount": 120, "placedAt": NOW - 600000, "status": "open",
              "game": games[3], "label": "MRL over NCG", "pays": games[3]["pool"]["pays"]["home"]}]
bets_settled = [{"id": "b0", "gameId": games[0]["id"], "side": "away", "amount": 50, "placedAt": NOW - DAY_MS, "status": "won",
                 "payout": 118, "game": games[0], "label": "STA at HCL"},
                {"id": "b-1", "gameId": "g6105", "side": "home", "amount": 200, "placedAt": NOW - 3 * DAY_MS, "status": "lost",
                 "payout": 0, "game": dict(games[2], id="g6105", day=DAY - 1, status="final"), "label": "ELC over CSR"}]
w("bets-open", {"bets": bets_open})
w("bets-settled", {"bets": bets_settled})

# ---- news
STORIES = [
    ("s1", "scandal", "RACCOONS LOOSED IN FRIARS BULLPEN", "Bellwood Park staff spent the 6th inning chasing what one reliever called \"at least nine, maybe a family.\"",
     ["Bellwood Park staff spent the sixth inning chasing what one Friars reliever called \"at least nine, maybe a family.\" A nun was seen leaving the bleachers at speed.",
      "The Friars bullpen, already thin after Tuesday's eel incident, was unable to warm up for eleven minutes. Cal Whitlock was left in to face the heart of the Lamplighters order and was shelled.",
      "\"I've been in this game thirty years,\" said umpire Minnie Zaleski. \"I have never seen a raccoon steal a rosin bag. Twice.\"",
      "League officials say they are investigating. Friars management declined comment but was seen buying traps in bulk.",
      "Final: Lamplighters 7, Friars 1. Moose Mullane went 3-for-4 with a home run that a raccoon may or may not have touched."],
     [140, 41], [whitlock, moose, agnes, zaleski], ["STA", "HCL"], "g6201"),
    ("s2", "trade", "Dunphy sent down to Lockport, calls it a \"betrayal\"", "Ace Dunphy, 3-9 with a 6.12 ERA, will ride the bus.",
     ["Ace Dunphy was optioned to the Lockport Canallers after his worst start of the year.", "\"Mr. Haldane promised me a ring,\" Dunphy said, packing. \"He gave me a bus ticket.\"", "Kid Okafor (.388 in AA) takes his roster spot."],
     [33], [dunphy, haldane, okafor], ["HCL"], None),
    ("s3", "brief", "Hot dog vendor held on eel charges", "Hal says he was \"just delivering.\"",
     ["A concessions worker known only as Hot Dog Hal was detained outside the visitors' clubhouse with 40 lbs of eels.", "Police say the eels were alive and \"very upset.\""],
     [160], [hal], ["STA"], None),
    ("s4", "feature", "Commissioner vows crackdown \"on whoever it is\"", "Office of the Commissioner promises to look into it, eventually.",
     ["In a statement read aloud to three reporters and a dog, the Commissioner vowed to crack down on \"whoever it is that is doing all this.\"", "Asked who that might be, he shrugged."],
     [77], [], [], None),
    ("s5", "life", "Mullane to wed his longtime barber", "The Lamplighters slugger popped the question at second base.",
     ["Moose Mullane proposed to his barber, Edna Pruitt, between innings on Thursday. She said \"finally.\""], [12, 99], [moose], ["HCL"], None),
    ("s6", "recap", "Ironmen hammer Mariners in fog-shortened game", "Six innings, eleven runs, zero visibility.",
     ["The fog rolled in off the harbor in the fourth and never left."], [301], [], ["MIL", "PEM"], None),
    ("s7", "scandal", "Umpire Brotherhood denies 'laser pointer' rumors", "\"Our men see what they see,\" says the Brotherhood.",
     ["Several hitters complained of a green dot in their eyes during Tuesday's game."], [53], [zaleski], [], None),
    ("s8", "brief", "Grays sign 41-year-old knuckleballer", "He says he is 33.", ["He has been 33 for some time."], [222], [], ["NCG"], None),
    ("s9", "feature", "Inside the Pilgrims' no-Sunday-ball crusade", "Brother Amos wants your weekends.",
     ["Brother Amos's Fellowship held a rally outside Plymouth Yard to protest Sunday baseball, then stayed for the game."], [21], [amos], ["MRL"], None),
    ("s10", "trade", "Comets acquire reliever for a used generator", "Volta Power & Light calls it \"a fair deal.\"", ["The generator works, mostly."], [410], [], ["ELC", "CSR"], None),
    ("s11", "life", "Rustlers catcher becomes a father of twins", "Both have \"a cannon,\" he says.", ["Mother and twins doing well."], [333], [], ["CSR"], None),
    ("s12", "brief", "Bobby denies everything", "\"I don't fix games. I just know who does.\"", ["Bets By Bobby remains open for business."], [5], [bobby], [], None),
]
def summary(s, i):
    return {"id": s[0], "day": DAY - i // 4, "kind": s[1], "headline": s[2], "dek": s[3], "faceIds": ["face:%d" % f for f in s[5]],
            "teams": s[7]}
sums = [summary(s, i) for i, s in enumerate(STORIES)]
w("news", {"stories": sums[:8], "next": "c8"})
w("news-c8", {"stories": sums[8:]})

COMMENTS_TXT = [
    ("kessler_fan69", "Fan", "Moose Mullane is CORKED and everyone knows it"),
    ("lampgirl", "Rube", "MOOSE 4 MAYOR!!!"),
    ("anonymous", "Rat", "We know about the rabbit's foot."),
    ("friarfaithful", "Grifter", "Raccoons? In THIS economy?"),
    ("bobbys_cousin", "Made Man", "Try betting on the raccoons."),
    ("sistr_A", "Grifter", "The laser worked."),
]
def comment(i, c):
    return {"id": "c%d" % i, "author": c[0], "authorRank": c[1], "text": c[2], "at": NOW - (i + 1) * 431000,
            "reactions": {"agree": R.randint(0, 14), "lol": R.randint(0, 20), "rat": R.randint(0, 3)}}
for i, s in enumerate(STORIES):
    story = {"id": s[0], "day": DAY - i // 4, "kind": s[1], "headline": s[2], "dek": s[3], "body": s[4],
             "faceIds": ["face:%d" % f for f in s[5]], "people": [ref(p) for p in s[6]], "teams": [tref(t) for t in s[7]]}
    if s[8]:
        story["gameId"] = s[8]
    cs = [comment(j + 10 * i, COMMENTS_TXT[(j + i) % len(COMMENTS_TXT)]) for j in range(5 if i == 0 else 2)]
    w("story-" + s[0], {"story": story, "comments": cs})
w("story", {"story": {"id": "s0", "day": DAY, "kind": "brief", "headline": "Story not found in cache", "dek": "", "body": ["This page intentionally left blank."], "faceIds": [], "people": [], "teams": []}, "comments": []})

# ---- words
TEMPLATES = [
    ("t1", "{player} is {adjective}!", ["player", "adjective"]),
    ("t2", "Try {action}.", ["action"]),
    ("t3", "{team} fans, {exclamation}!", ["team", "exclamation"]),
    ("t4", "I blame {person}.", ["person"]),
    ("t5", "{player} is {adjective}, but {player} is {adjective}.", ["player", "adjective", "player", "adjective"]),
    ("t6", "Never forget {incident}.", ["incident"]),
    ("t7", "{exclamation} Look out for {thing}!", ["exclamation", "thing"]),
    ("t8", "Bet on {team}. Trust me.", ["team"]),
    ("t9", "{person} knows about {thing}.", ["person", "thing"]),
    ("t10", "This is {adjective}. {exclamation}", ["adjective", "exclamation"]),
]
slots = {
    "player": sorted({p["name"] for ab in ("HCL", "STA", "PEM", "MIL") for p in rosters[ab]}),
    "person": ["Mr. Haldane", "Brother Amos", "Bobby", "the Commissioner", "Minnie Zaleski", "Sister Agnes", "Hot Dog Hal", "my mother", "the bat boy", "the D.A."],
    "team": [t[1] + " " + t[2] for t in TEAMS] + [t[2] for t in TEAMS],
    "adjective": ["corked", "washed up", "clutch", "a bum", "beautiful", "cursed", "on the take", "a genius", "overrated", "a legend", "afraid of birds", "sweating", "holy", "suspicious", "unstoppable", "drunk", "underpaid", "a rat", "hungry", "tremendous"],
    "action": ["bunting", "praying", "the hidden ball trick", "spitting", "eels", "a laser pointer", "leaving early", "bribing the ump", "raccoons", "crying", "more hot dogs", "walking him", "stealing home"],
    "exclamation": ["hooray", "for shame", "unbelievable", "rats", "holy cow", "boo", "told you so", "help", "huzzah", "oh no", "yer out"],
    "incident": ["the raccoon game", "the eel incident", "the fog game", "the brawl of Day 12", "the laser game", "the nun", "the generator trade"],
    "thing": ["the rabbit's foot", "the cooler", "the mascot", "the eels", "the rosin bag", "the ledger", "the tunnel", "the vault", "the nun", "the dugout phone"],
}
w("words", {"templates": [{"id": t[0], "text": t[1], "slots": t[2]} for t in TEMPLATES], "slots": slots, "version": 7})

# ---- people pages
def person_page(p, extra=None):
    team = None
    if p.get("teamAbbr"):
        ab = p["teamAbbr"]
        base, lv = (ab[:3], ab[3:] or "ML")
        team = tref(base, lv)
    page = {
        "person": dict(ref(p), nickname=R.choice(NICKS), age=R.randint(21, 37), bats=R.choice("LRS"), throws=R.choice("LR"),
                       traits=R.sample(TRAITS, 3), mood=R.choice(["sore", "content", "jittery", "furious", "in love"]), status=R.choice(["active", "active", "day-to-day"])),
        "team": team,
        "family": {"parents": [ref(person()), ref(person())], "spouse": ref(person()) if R.random() < 0.6 else None,
                   "children": [ref(person()) for _ in range(R.randint(0, 3))], "house": "House " + p["name"].split()[-1],
                   "houseNote": R.choice(["three generations of utility infielders", "known for bad knees and good arms", "feuding with the Feeneys since Season 1", "minor nobility (claimed)"])},
        "ties": [{"who": ref(whitlock), "value": -4, "reason": "beaned him, Day 12"},
                 {"who": ref(haldane), "value": 3, "reason": "paid his mom's rent"},
                 {"who": ref(feeney), "value": -2, "reason": "owes $400"}],
        "drama": ["Engaged to his barber", "Owes Bobby $400", "Swears by a rabbit's foot"],
        "stats": [{"season": s, "team": "HCL" if s > 2 else "HCLAA", "line": ".%03d/.%03d/.%03d, %d HR, %d RBI" % (R.randint(250, 320), R.randint(310, 400), R.randint(400, 560), R.randint(5, 30), R.randint(30, 99))} for s in range(SEASON, 0, -1)],
        "scouting": [{"label": l, "value": R.randint(1, 5)} for l in ["Contact", "Power", "Eye", "Speed", "Glove", "Arm"]],
        "notes": "Swings at anything near the zone and some things near the dugout. Fans love him. Pitchers fear him. Barbers marry him.",
        "faces": [p["face"], p["face"].replace("face:", "face:") + "b", p["face"] + "c"],
        "visitors": R.randint(400, 9999),
        "guestbook": [comment(100 + j, COMMENTS_TXT[j]) for j in range(4)],
    }
    if p is moose:
        page["person"]["nickname"] = "Moose"
        page["person"]["traits"] = ["HOTHEAD", "LOYAL", "SUPERSTITIOUS"]
        page["person"]["age"] = 29
        page["visitors"] = 4211
        page["family"]["spouse"] = None
        page["family"]["children"] = [ref(person("Junior Mullane", 13, "HCLD", "1B"))]
    if extra:
        page.update(extra)
    return page

for p in list(people.values())[:]:
    pass
w("person", person_page(moose))
for p in [moose, dunphy, whitlock, okafor, carrigan, haldane, agnes, hal, kessler, feeney]:
    w("person-" + p["id"], person_page(p))

# ---- team pages
REL = {
    "HCL": [("St. Albans Friars", -5, "the Holy War"), ("Archdiocese (Friars)", -3, "land dispute"), ("Umpires' Brotherhood", -2, "Kessler"),
            ("Millbrook Ironmen", 3, "trade partner"), ("SportsWire", 4, "Haldane buys ads"), ("Your crew", 0, "unaware of you")],
}
def team_page(abbr):
    t = next(t for t in TEAMS if t[0] == abbr)
    leader = haldane if abbr == "HCL" else (amos if abbr == "MRL" else person())
    rels = REL.get(abbr) or [(R.choice(TEAMS)[2], R.randint(-5, 5), R.choice(["old grudge", "trade partner", "stole a manager", "water rights", "a bar fight"])) for _ in range(5)]
    return {
        "team": tref(abbr), "owner": {"faction": t[3], "leader": ref(leader), "wants": {"HCL": ["a pennant", "a new stadium", "Kessler fired"]}.get(abbr, ["respect", "a pennant", "revenge"])},
        "manager": ref(kessler) if abbr == "HCL" else ref(person()), "park": t[5],
        "chain": [team_rec(abbr, lv) for lv in LEVELS],
        "roster": [dict(ref(p), line=line_for(p)) for p in rosters[abbr]],
        "relations": [{"name": r[0], "value": r[1], "reason": r[2]} for r in rels],
        "moves": [{"day": DAY - 1, "text": "Moving down: A. Dunphy (furious)"}, {"day": DAY - 1, "text": "Moving up: \"Kid\" Okafor (.388 in AA)"},
                  {"day": DAY - 4, "text": "Released: R. Toomey (eels)"}, {"day": DAY - 9, "text": "Signed: G. Fogarty, amateur, 17"}],
    }
for t in TEAMS:
    w("team-" + t[0], team_page(t[0]))
w("team", team_page("HCL"))

# ---- threads
w("thread", {"comments": [comment(200 + j, COMMENTS_TXT[j]) for j in range(6)]})

# ---- crew
crew = [
    {"id": "cr1", "person": ref(agnes), "role": "organist", "skills": [{"k": "Charm", "v": 5}, {"k": "Nerve", "v": 4}, {"k": "Sneak", "v": 2}], "loyalty": 4, "status": "wanted", "note": "\"The laser worked.\""},
    {"id": "cr2", "person": ref(lefty), "role": "ex-pitcher", "skills": [{"k": "Arm", "v": 5}, {"k": "Sneak", "v": 3}, {"k": "Booze", "v": 5}], "loyalty": 3, "status": "ok", "note": "Wants his old job back."},
    {"id": "cr3", "person": ref(hal), "role": "concessions", "skills": [{"k": "Access", "v": 4}, {"k": "Eels", "v": 5}], "loyalty": 3, "status": "in lockup", "note": "Talking to the D.A.?"},
    {"id": "cr4", "person": ref(ozzie), "role": "security", "skills": [{"k": "Muscle", "v": 5}, {"k": "Loyal", "v": 2}], "loyalty": 2, "status": "on the take", "note": "Also works for Bobby."},
]
w("crew", {"crew": crew, "max": 6})
cands = [
    {"id": "cd1", "person": ref(person("Edna Pruitt", 99)), "role": "barber", "skills": [{"k": "Charm", "v": 3}, {"k": "Access", "v": 4}], "loyalty": 3, "status": "available", "note": "Cuts Moose's hair. Knows things.", "cost": 150},
    {"id": "cd2", "person": ref(person("Dutch Lomax", 199)), "role": "groundskeeper", "skills": [{"k": "Access", "v": 5}, {"k": "Muscle", "v": 2}], "loyalty": 4, "status": "available", "note": "Has keys to everything.", "cost": 220},
    {"id": "cd3", "person": ref(person("Madame Zora", 250)), "role": "fortune teller", "skills": [{"k": "Charm", "v": 4}, {"k": "Nerve", "v": 3}], "loyalty": 2, "status": "available", "note": "Saw this coming.", "cost": 90},
]
w("candidates", {"candidates": cands, "refreshesAt": NOW + 40 * 60 * 1000})

GEAR = [{"id": "sack", "name": "Burlap sack x3", "cost": 5}, {"id": "habit", "name": "Fake nun habit", "cost": 25}, {"id": "eels", "name": "Bucket of eels", "cost": 40},
        {"id": "laser", "name": "Laser pointer", "cost": 60}, {"id": "vaseline", "name": "Tin of Vaseline", "cost": 10}]
kinds = [
    {"kind": "grease", "name": "Grease the mound", "blurb": "A little something on the rubber. Their starter slips; so might yours.", "cost": 40, "risk": "low", "slots": 1, "needs": "Access 3", "gear": [GEAR[4]], "successPct": 74},
    {"kind": "rabbit", "name": "Rabbit balls", "blurb": "Swap the game balls for livelier ones. Homers for everyone.", "cost": 90, "risk": "mod", "slots": 2, "needs": "Access 3, Sneak 2", "gear": [GEAR[0]], "successPct": 58},
    {"kind": "raccoons", "name": "Release raccoons", "blurb": "If it works: Friars bullpen stamina -40%, maybe injuries, front page. If it fails: Agnes arrested. She knows your name.", "cost": 60, "risk": "mod", "slots": 2, "needs": "Sneak 2, Nerve 2", "gear": [GEAR[0], GEAR[1], GEAR[2]], "successPct": 62},
    {"kind": "cooler", "name": "Spike the cooler", "blurb": "Something in the Gatorade. Their lineup gets sleepy (and honest).", "cost": 120, "risk": "high", "slots": 2, "needs": "Access 4", "gear": [GEAR[2]], "successPct": 41},
    {"kind": "mascot", "name": "Kidnap the mascot", "blurb": "Morale plummets. Children weep. SportsWire will LOVE this.", "cost": 200, "risk": "lol", "slots": 3, "needs": "Muscle 4, Nerve 3", "gear": [GEAR[0], GEAR[3]], "successPct": 23},
]
w("ops-catalog", {"kinds": kinds, "targets": [tref("STA"), tref("HCL")]})
w("ops", {"ops": [
    {"id": "op1", "kind": "raccoons", "name": "Release raccoons", "game": games[0], "target": tref("STA"), "crew": [ref(agnes), ref(hal)], "status": "done", "result": "Bullpen in shambles. Front page. Agnes seen leaving."},
    {"id": "op0", "kind": "grease", "name": "Grease the mound", "game": dict(games[2], id="g6105"), "target": tref("CSR"), "crew": [ref(lefty)], "status": "blown", "result": "Groundskeeper noticed. Lefty fled over the wall."},
    {"id": "op2", "kind": "rabbit", "name": "Rabbit balls", "game": games[3], "target": tref("NCG"), "crew": [ref(lefty), ref(ozzie)], "status": "planned"},
]})

# ---- mail & events
w("mail", {"mail": [
    {"id": "m1", "from": "Sister Agnes", "fromFace": "face:140", "subject": "re: the thing", "body": ["It is done. The raccoons were very cooperative.", "I will need a new habit. And a tetanus shot.", "Yours in Christ,", "A."], "at": NOW - 300000, "read": False, "kind": "op"},
    {"id": "m2", "from": "Bets By Bobby", "fromFace": "face:5", "subject": "Your winnings: $118", "body": ["Friars @ Lamplighters settled.", "You had $50 on the Friars. Pays 2.37.", "Paid: $118. Don't spend it all in one place.", "-Bobby"], "at": NOW - 900000, "read": False, "kind": "bank"},
    {"id": "m3", "from": "A Friend", "subject": "you didn't hear it from me", "body": ["The Grays' cooler is unguarded on Thursdays.", "Burn this letter."], "at": NOW - 3600000, "read": False, "kind": "tip"},
    {"id": "m4", "from": "The Commissioner's Office", "fromFace": "face:77", "subject": "Notice of Inquiry", "body": ["It has come to the attention of this office that someone is doing all this.", "If that someone is you, please stop.", "Regards."], "at": NOW - 2 * DAY_MS, "read": True, "kind": "league"},
    {"id": "m5", "from": "lampgirl", "subject": "MOOSE!!!", "body": ["did u see the moose game", "MOOSE 4 MAYOR"], "at": NOW - 3 * DAY_MS, "read": True, "kind": "fan"},
    {"id": "m6", "from": "Unknown", "subject": "We know about the raccoons.", "body": ["We know about the raccoons.", "Leave $500 under the third-base bag.", "Or else."], "at": NOW - 4 * DAY_MS, "read": True, "kind": "threat"},
]})
w("events", {"events": [
    {"id": "e1", "title": "Hal is talking to the D.A.", "body": "Caught with 40 lbs of eels outside the visiting clubhouse, Hal says he was \"just delivering.\" The D.A. offers him a deal if he names who he was delivering for.",
     "face": "face:160", "choices": [{"key": "lawyer", "label": "Hire a lawyer", "cost": 300}, {"key": "judge", "label": "Lean on the judge", "note": "Ozzie, HEAT +2"}, {"key": "deal", "label": "Let him take the deal", "note": "you get named"}], "expiresAt": NOW + 20 * 60 * 1000},
    {"id": "e3", "title": "An Offer You Could Refuse", "body": "bobbys_cousin wants you in The Corkers syndicate. Shared crews, shared treasury, shared bail.", "face": "face:5", "choices": [{"key": "accept", "label": "Join up"}, {"key": "decline", "label": "Thanks, no"}], "expiresAt": NOW + 30 * 60 * 1000},
    {"id": "e2", "title": "Bobby wants a word", "body": "Bobby noticed your crew in his bullpen. He's not mad. He wants 20% of whatever you're running on the Friars.",
     "face": "face:5", "choices": [{"key": "pay", "label": "Cut him in", "note": "-20% winnings"}, {"key": "refuse", "label": "Tell him to take a hike", "note": "HEAT +1, Bobby -2"}], "expiresAt": NOW + 50 * 60 * 1000},
]})

# ---- syndicate (docs/API.md "Syndicates")
w("syndicate", {"syndicate": {"id": "syn1", "name": "The Raccoon Lodge", "founder": "kessler_fan69", "treasury": 2350, "board": "bbs:syn:syn1", "max": 4,
    "members": [
        {"name": "kessler_fan69", "rank": "Grifter", "money": 1240, "heat": 3, "crewSize": 4, "founder": True},
        {"name": "lampgirl", "rank": "Rube", "money": 310, "heat": 1, "crewSize": 2, "founder": False},
        {"name": "sistr_A", "rank": "Made Man", "money": 5120, "heat": 7, "crewSize": 6, "founder": False}]},
    "invites": [{"id": "inv1", "syndicate": "The Corkers", "from": "bobbys_cousin", "at": NOW - 600000}]})
# Allies' crew members (not yet in the API: the client reads `allies` from /crew if present)
w("crew-allies", {"allies": [
    {"id": "cr21", "owner": "lampgirl", "person": ref(person("Peaches Delgado", 301)), "role": "usherette", "skills": [{"k": "charm", "v": 4}, {"k": "sneak", "v": 3}], "loyalty": 4, "status": "free", "note": "Knows every seat in the house."},
    {"id": "cr22", "owner": "sistr_A", "person": ref(person("Father Kowalski", 312)), "role": "chaplain", "skills": [{"k": "access", "v": 5}, {"k": "nerve", "v": 4}], "loyalty": 5, "status": "free", "note": "Blesses the dugout. Also the cooler."},
    {"id": "cr23", "owner": "sistr_A", "person": ref(person("Noodles Fuentes", 330)), "role": "bat boy", "skills": [{"k": "sneak", "v": 5}], "loyalty": 3, "status": "busy", "note": "Twelve years old. Allegedly."}]})
w("thread-bbs_syn_syn1", {"comments": [
    {"id": "sc1", "author": "sistr_A", "authorRank": "Made Man", "text": "Try raccoons.", "at": NOW - 200000, "reactions": {"agree": 2, "lol": 1, "rat": 0}},
    {"id": "sc2", "author": "lampgirl", "authorRank": "Rube", "text": "Bet on Lamplighters. Trust me.", "at": NOW - 900000, "reactions": {"agree": 0, "lol": 3, "rat": 0}}]})
w("syndicate-leaderboard", {"season": SEASON, "rows": [
    {"rank": 1, "id": "syn4", "name": "Holy Rollers", "members": ["friarfaithful", "pewsitter", "amen_corner", "deacon_dan"], "net": 4120, "ops": 19, "pulledOff": 14, "arrests": 2},
    {"rank": 2, "id": "syn2", "name": "The Corkers", "members": ["bobbys_cousin", "corkboard", "lumberjack"], "net": 2210, "ops": 11, "pulledOff": 6, "arrests": 3},
    {"rank": 3, "id": "syn1", "name": "The Raccoon Lodge", "members": ["kessler_fan69", "lampgirl", "sistr_A"], "net": 1840, "ops": 9, "pulledOff": 6, "arrests": 1},
    {"rank": 4, "id": "syn6", "name": "Eel Enthusiasts", "members": ["hal_fan", "slippery"], "net": 960, "ops": 7, "pulledOff": 2, "arrests": 4},
    {"rank": 5, "id": "syn9", "name": "Grays Anatomy", "members": ["oldmoney", "monocle", "spats", "chauffeur"], "net": -410, "ops": 3, "pulledOff": 0, "arrests": 0}]})

print("wrote", len(os.listdir(OUT)), "files")
