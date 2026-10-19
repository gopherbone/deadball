"""What the archive looks for on Wikimedia Commons (used as a mirror/search index for public-domain
collections: LoC Bain / Detroit Publishing / FSA-OWI / National Photo Co. / Harris & Ewing, plus old
engravings, natural-history plates, period ads and cartoons).

Each group: (key, [search strings], tags, take, caption)
- search strings use Commons CirrusSearch syntax; " filetype:bitmap" is appended. A trailing " LCCN"
  biases toward Library of Congress uploads (their file names carry the LCCN).
- take: how many images the group contributes to the catalog (after review drops).
- caption: neutral short caption for every item of the group (overrides.json can set per-item ones).
- tags: catalog tags (see packages/sim/src/archive.ts for the vocabulary the game asks for).
"""

G = []


def g(key, searches, tags, take, caption):
    G.append({"key": key, "searches": searches, "tags": tags.split(), "take": take, "caption": caption})


# ------------------------------------------------------------------ incidents
g("raccoon", ["raccoon engraving", "Procyon lotor illustration", "raccoon lithograph", "racoon plate natural history",
              "raccoon LCCN", "raccoon Audubon"], "raccoon animal incident nature", 10, "A raccoon, as drawn by a naturalist")
g("raccoon-photo", ["raccoon pet 1910", "raccoon LCCN photograph", "coon hunter raccoon"], "raccoon animal incident", 4,
  "A raccoon, photographed")
g("opossum", ["opossum engraving", "possum illustration"], "animal nature raccoon", 2, "An opossum, from a natural-history plate")
g("rabbit", ["rabbit engraving natural history", "hare lithograph plate"], "rabbit animal nature", 3, "A rabbit, from an old plate")
g("eel", ["eel engraving", "Anguilla eel illustration", "eel fish plate", "moray eel lithograph", "eel fishermen"],
  "eel fish animal nature food", 8, "Eels, from a natural-history plate")
g("fish-market", ["fish market LCCN", "fish peddler LCCN"], "fish food market vendor", 3, "A fish market")
g("fan-on-field", ["crowd on field baseball LCCN", "crowd rushes field LCCN", "spectators on the field polo grounds LCCN"],
  "fan crowd field incident baseball", 5, "Spectators spill onto the field")
g("rain", ["rain umbrellas street LCCN", "umbrellas in the rain crowd", "rain storm street 1910"],
  "rain weather umbrella incident", 6, "Umbrellas in the rain")
g("rain-tarp", ["baseball field rain LCCN", "flooded baseball field", "groundskeeper baseball"], "rain weather field baseball tarp", 3,
  "A wet field")
g("brawl", ["fight crowd LCCN", "brawl engraving", "fist fight illustration", "riot police crowd LCCN", "boxing match LCCN"],
  "brawl fight incident", 8, "A fight breaks out")
g("argue", ["umpire argument baseball LCCN", "arguing with umpire", "umpire baseball LCCN"],
  "umpire argument ejection baseball incident", 6, "Words with the umpire")
g("sick", ["sick bed illustration", "patient hospital bed LCCN", "doctor patient bedside", "stomach ache advertisement"],
  "sick hospital food_poisoning doctor", 6, "Taken ill")
g("hotdog", ["hot dog stand LCCN", "frankfurter vendor", "hot dog vendor", "sausage advertisement", "lunch wagon LCCN",
             "Coney Island hot dog"], "hotdog food vendor food_poisoning", 8, "Frankfurters for sale")
g("vendor", ["peanut vendor LCCN", "street vendor push cart LCCN", "lemonade stand LCCN", "ice cream vendor LCCN"],
  "vendor food crowd", 5, "A vendor works the crowd")
g("eye", ["optician advertisement", "eye chart", "spectacles advertisement", "eye examination LCCN", "eyeglasses illustration",
          "oculist"], "eye optician laser ad", 7, "Eyes examined")
g("lightning", ["lightning photograph 1900", "lightning engraving", "electric arc lamp"], "laser light electric weather", 3,
  "A flash of light")
g("ball", ["baseball ball illustration", "baseball catalog Spalding", "baseball pitcher grip LCCN", "spitball"],
  "ball pitcher tampering baseball", 4, "The ball")

# ------------------------------------------------------------------ crime ops
g("envelope", ["envelope cash bills", "money bills currency 1900", "bundle of money", "paying money illustration", "bribery cartoon"],
  "cash money envelope bribe", 7, "Cash changes hands")
g("bribe-cartoon", ["political cartoon bribery Puck", "graft cartoon Judge magazine", "boss cartoon money bags"],
  "bribe cartoon money politics", 5, "A cartoon about graft")
g("sprinkler", ["lawn sprinkler", "sprinkler LCCN", "street sprinkler wagon", "fire hose water LCCN", "watering lawn LCCN"],
  "sprinkler water hose", 6, "Water everywhere")
g("mascot", ["mascot baseball LCCN", "costume parade LCCN", "bear costume", "man in animal costume", "goat mascot"],
  "mascot costume", 6, "A mascot")
g("binoculars", ["binoculars LCCN", "field glasses", "opera glasses", "telescope man looking LCCN", "spyglass"],
  "binoculars spy signs", 6, "Someone is watching")
g("megaphone", ["megaphone LCCN", "megaphone man", "cheerleader megaphone", "rooters baseball LCCN", "heckler"],
  "megaphone heckle crowd noise", 6, "A voice from the stands")
g("letter", ["love letter illustration", "woman reading letter LCCN", "valentine card antique", "perfume advertisement",
             "letter writing illustration"], "letter love valentine mail", 7, "A letter arrives")
g("camera", ["camera photographer LCCN", "press photographer", "box camera advertisement", "Kodak advertisement", "news photographers LCCN"],
  "camera photographer blackmail press", 7, "The photographers")
g("glove", ["baseball glove", "baseball mitt catalog", "catcher's mitt"], "glove baseball equipment", 3, "A ballplayer's glove")
g("grease", ["Vaseline advertisement", "petroleum jelly advertisement", "lard advertisement", "axle grease advertisement"],
  "grease ad", 3, "A tin of grease")
g("cooler", ["water cooler", "water bucket dipper", "ice wagon LCCN", "bottled water advertisement"], "water cooler drink", 4,
  "Something to drink")
g("poison", ["poison bottle", "patent medicine advertisement", "quack medicine bottle", "medicine show"],
  "poison medicine bottle food_poisoning ad", 5, "Patent medicine")
g("newsroom", ["newsroom typewriter LCCN", "newspaper office LCCN", "reporters newspaper office", "newsboys LCCN", "printing press newspaper"],
  "newspaper press newsroom tip", 7, "The newsroom")
g("telephone", ["telephone operator LCCN", "man on telephone LCCN", "telephone advertisement", "candlestick telephone",
                "switchboard"], "telephone phone tip", 7, "On the telephone")
g("typewriter", ["typewriter advertisement", "typewriter LCCN", "typist woman typewriter"], "typewriter office", 4, "A typewriter")
g("telegraph", ["telegraph operator", "telegraph key", "stock ticker tape machine", "teletype machine"], "telegraph wire fax ticker", 5,
  "The wire")
g("radio", ["radio receiver 1922", "radio listening LCCN", "radio advertisement 1925", "crystal radio set"], "radio", 5, "On the radio")
g("police", ["police patrol wagon LCCN", "policemen LCCN", "police raid LCCN", "arrested man police LCCN", "paddy wagon"],
  "police arrest crime", 8, "The police arrive")
g("detective", ["detective magnifying", "detectives LCCN", "private detective advertisement", "fingerprints police"],
  "detective police crime spy", 4, "A detective on the case")
g("jail", ["jail cell", "prison cell LCCN", "prisoners jail LCCN", "Sing Sing", "handcuffs"], "jail prison arrest crime", 6, "Behind bars")
g("guard", ["watchman night LCCN", "security guard 1910", "bouncer", "strongman"], "guard security muscle", 4, "Muscle for hire")
g("transformer", ["power station switchboard", "electric transformer 1910", "dynamo generator", "power plant interior LCCN"],
  "power electric blackout plant", 6, "The power plant")
g("streetlight", ["street lamp night LCCN", "street lights night city 1910", "lamplighter", "arc light street", "night city lights"],
  "streetlight night blackout city", 6, "Street lamps at night")
g("candle", ["candlelight reading", "candle illustration", "oil lamp"], "blackout candle night", 3, "By candlelight")
g("gambling", ["gambling LCCN", "card players poker", "dice gambling", "bookmaker race track LCCN", "betting ring"],
  "gambling bet debt cards", 6, "The betting ring")
g("pawn", ["pawn shop LCCN", "pawnbroker", "bank run crowd LCCN", "debtors"], "debt money pawn bank", 4, "Money trouble")
g("kidnap", ["sack burlap", "ransom note", "kidnapping cartoon"], "kidnap sack crime", 3, "Bagged")
g("spy", ["spy illustration", "man in trench coat", "eavesdropping"], "spy signs secret", 3, "Spying")

# ------------------------------------------------------------------ life events
g("wedding", ["wedding party LCCN", "bride groom LCCN", "wedding couple 1910", "wedding church crowd LCCN", "bride bridesmaids LCCN"],
  "wedding love church", 9, "A wedding")
g("baby", ["baby carriage LCCN", "baby show LCCN", "babies LCCN", "infant mother LCCN", "baby advertisement", "stork illustration"],
  "baby birth family", 9, "A new arrival")
g("children", ["children playing LCCN", "kids street baseball LCCN", "sandlot baseball boys", "boys baseball LCCN"],
  "kids family youth coming_of_age baseball", 6, "Kids at play")
g("funeral", ["funeral procession LCCN", "funeral LCCN", "hearse", "cemetery mourners", "graveyard"], "funeral death cemetery", 8,
  "A funeral")
g("party", ["banquet dinner LCCN", "testimonial dinner", "party celebration LCCN", "dinner party 1910", "retirement"],
  "party banquet retirement celebration", 7, "A banquet in his honor")
g("oldman", ["old man rocking chair", "old men porch LCCN", "veteran old man LCCN", "old man fishing"], "retirement old", 5,
  "Retirement")
g("court", ["courtroom LCCN", "court trial LCCN", "jury LCCN", "lawyers court", "courthouse LCCN", "judge bench"],
  "court trial divorce lawyer judge", 9, "In court")
g("divorce", ["divorce cartoon", "quarrel couple illustration", "unhappy marriage cartoon"], "divorce marriage cartoon", 4,
  "A marriage on the rocks")
g("hospital", ["hospital ward LCCN", "nurses hospital LCCN", "ambulance LCCN", "hospital operating room", "crutches"],
  "hospital injury nurse doctor", 9, "In the hospital")
g("doctor", ["doctor LCCN", "physician examining", "doctor bag"], "doctor hospital injury", 4, "The doctor")
g("train", ["railroad station platform LCCN", "train departure", "train depot crowd LCCN", "Pullman car", "locomotive LCCN",
            "baseball team train"], "train travel trade departure station", 10, "All aboard")
g("suitcase", ["suitcases luggage", "trunk luggage porter", "immigrants luggage"], "travel suitcase trade release", 4, "Packing up")
g("bus", ["motor bus 1920", "bus depot"], "bus travel demotion", 3, "The bus to the minors")
g("handshake", ["handshake LCCN", "signing contract LCCN", "signing paper desk", "fountain pen advertisement"],
  "contract signing handshake deal", 6, "Signed")
g("trophy", ["trophy cup LCCN", "loving cup LCCN", "medal ceremony", "pennant flag baseball LCCN", "trophies"],
  "trophy award milestone champion", 7, "Silverware")
g("parade", ["ticker tape parade", "parade crowd LCCN", "victory parade", "parade float LCCN", "brass band parade LCCN"],
  "parade celebration champion city", 8, "A parade")
g("office", ["office desk LCCN", "executive office 1910", "board meeting LCCN", "businessmen meeting", "boardroom"],
  "office business owner hire fire succession", 7, "Behind closed doors")
g("church", ["church interior LCCN", "church congregation", "church steeple LCCN", "cathedral LCCN", "tent revival",
             "nuns LCCN", "priest LCCN"], "church religion stalbans marlow", 10, "At church")
g("mansion", ["mansion LCCN Detroit Publishing", "gentlemen's club interior", "country club", "estate garden party"],
  "mansion rich corinth society", 6, "Old money")

# ------------------------------------------------------------------ world events
g("election", ["campaign speech LCCN", "political rally crowd LCCN", "election night crowd", "ballot box", "voting polls LCCN",
               "stump speech", "candidate speaking crowd"], "election politics podium crowd", 10, "On the campaign trail")
g("politics-cartoon", ["political cartoon Puck", "Judge magazine cartoon", "Thomas Nast cartoon", "political cartoon 1900"],
  "politics cartoon", 6, "A political cartoon")
g("cityhall", ["city hall LCCN", "city council meeting", "mayor office", "capitol building LCCN"], "politics city cityhall", 5,
  "City Hall")
g("strike", ["strikers picket LCCN", "strike pickets", "labor strike crowd LCCN", "strikers parade", "picket line",
             "union meeting LCCN"], "strike labor protest crowd", 10, "On strike")
g("docks", ["docks longshoremen LCCN", "harbor ships LCCN", "wharf LCCN", "steamship pier LCCN", "dock workers", "harbor Detroit Publishing"],
  "docks harbor ships portellis harborcity", 10, "The waterfront")
g("steel", ["steel mill LCCN", "blast furnace LCCN", "steel workers", "foundry workers", "rolling mill", "Bethlehem Steel"],
  "steel mill furnace industry millbrook", 9, "The mill")
g("cattle", ["stockyards LCCN", "cattle drive", "cowboys LCCN", "cattle round-up", "Union Stock Yards", "branding cattle"],
  "cattle stockyard cowboy coldspring", 9, "The stockyards")
g("power", ["power plant LCCN", "hydroelectric power", "electric light tower", "dynamo room", "power lines"],
  "power electric plant electriccity", 7, "Power & light")
g("factory", ["factory workers LCCN", "factory interior", "assembly line"], "factory industry labor", 5, "The factory floor")
g("stock", ["stock exchange floor", "Wall Street crowd LCCN", "stock exchange LCCN", "bank run", "Curb market brokers"],
  "stock market crash money bubble crowd", 9, "The market")
g("comet", ["comet engraving", "Halley's comet 1910", "comet illustration", "astronomical plate Trouvelot", "telescope observatory",
            "meteor shower engraving"], "comet astronomy sky space", 9, "Something in the sky")
g("blizzard", ["blizzard LCCN", "snow storm street LCCN", "snow shovel", "snow covered street 1910", "snowplow"],
  "blizzard snow weather winter", 8, "Snowed in")
g("flood", ["flood LCCN", "flooded street", "flood boats street", "flood 1913", "high water"], "flood water weather", 8,
  "The river rises")
g("heat", ["beach crowd LCCN", "bathing beach", "Coney Island beach crowd", "heat wave", "bathers LCCN", "ice cream cone"],
  "heatwave beach summer weather", 9, "Hot enough for you?")
g("fair", ["world's fair", "exposition grounds", "Panama-Pacific exposition", "Pan-American exposition", "Ferris wheel",
           "amusement park LCCN", "Luna Park"], "fair expo worldsfair amusement", 10, "The fair")
g("fad", ["dance craze", "roller skating LCCN", "yo-yo", "fad 1920s", "marathon dance", "bicycle craze", "flagpole sitter"],
  "fad craze dance", 9, "The latest craze")
g("toy", ["toy advertisement", "toys antique", "doll advertisement", "teddy bear"], "toy fad cards kids", 5, "Toys")
g("troops", ["troops parade LCCN", "soldiers marching LCCN", "soldiers departing", "army camp LCCN"], "troops war army parade", 6,
  "The troops")
g("society-wedding", ["society wedding LCCN", "wedding guests crowd church LCCN", "bridal gown 1910"],
  "wedding celebrity society love", 4, "The wedding of the season")
g("clock", ["clock tower", "clock advertisement", "alarm clock"], "clock time y2k", 4, "Time's up")
g("canned", ["canned goods grocery", "grocery shelves", "pantry canned food"], "y2k grocery panic food", 3, "Stocking up")
g("computer", ["tabulating machine", "Hollerith", "adding machine advertisement", "calculating machine"], "computer y2k machine office", 4,
  "The machine")
g("statue", ["statue unveiling LCCN", "monument dedication", "statue LCCN"], "statue civic city", 4, "A monument")
g("crowd", ["crowd street LCCN", "crowd waiting LCCN", "crowd watching", "spectators crowd"], "crowd city", 6, "A crowd gathers")
g("infomercial", ["advertisement 1900", "trade card", "patent medicine poster", "advertising poster 1890"], "ad fad", 6,
  "An advertisement")
g("tv", ["television 1930", "television set early"], "tv television", 2, "Television")
g("newspaper", ["newspaper headline", "reading newspaper LCCN", "newsstand LCCN"], "newspaper press", 5, "Read all about it")
g("mail", ["mail carrier LCCN", "postman", "post office LCCN", "mail bags"], "mail letter post", 5, "The mail")

# ------------------------------------------------------------------ baseball
g("bb-plate", ["play at the plate baseball LCCN", "sliding home baseball LCCN", "out at home baseball", "catcher tagging runner"],
  "baseball play plate slide action", 8, "Close play at the plate")
g("bb-slide", ["sliding baseball LCCN", "stealing second base LCCN", "slide second base baseball", "baseball runner base LCCN"],
  "baseball slide action steal", 8, "Safe or out")
g("bb-bat", ["baseball batter swinging LCCN", "baseball batting LCCN", "baseball game batter catcher umpire"],
  "baseball batter action hit", 8, "At the plate")
g("bb-pitch", ["baseball pitcher LCCN pitching", "pitcher windup baseball", "baseball pitcher throwing"],
  "baseball pitcher action", 6, "The pitch")
g("bb-field", ["baseball fielder catching", "baseball outfielder LCCN", "baseball infield play LCCN", "baseball catch fly"],
  "baseball fielding action catch", 6, "In the field")
g("bb-dugout", ["baseball bench players LCCN", "dugout baseball", "baseball players sitting bench"],
  "baseball dugout bench team", 6, "The bench")
g("bb-manager", ["baseball manager LCCN", "managers shaking hands baseball", "baseball coach LCCN"], "baseball manager", 4,
  "The skipper")
g("bb-park", ["baseball park LCCN", "baseball grounds stands LCCN", "ballpark grandstand", "baseball stadium 1910", "Polo Grounds",
              "Ebbets Field exterior", "Forbes Field"], "baseball ballpark stadium exterior season", 10, "The ballpark")
g("bb-crowd", ["baseball crowd LCCN", "baseball fans LCCN", "bleachers crowd baseball", "baseball spectators"],
  "baseball crowd fans grandstand", 8, "The faithful")
g("bb-tickets", ["ticket line baseball LCCN", "waiting for tickets world series", "ticket office line", "line outside ballpark"],
  "baseball tickets line crowd", 5, "In line for tickets")
g("bb-scoreboard", ["scoreboard baseball", "world series scoreboard crowd", "playograph", "baseball score board crowd street"],
  "baseball scoreboard crowd", 6, "The scoreboard")
g("bb-team", ["baseball team photograph LCCN", "baseball team 1910", "baseball club players group"], "baseball team", 6,
  "Team photo")
g("bb-warmup", ["baseball practice LCCN", "spring training baseball", "baseball players warming up"], "baseball practice spring training",
  5, "Spring training")
g("bb-umpire", ["umpire calling baseball", "umpire behind plate"], "baseball umpire", 4, "The man in blue")
g("bb-cartoon", ["baseball cartoon", "baseball illustration 1880s", "baseball engraving", "baseball lithograph"],
  "baseball cartoon illustration", 6, "Baseball, as drawn")
g("bb-women", ["women baseball LCCN", "bloomer girls baseball", "women playing baseball"], "baseball women", 3, "Ladies' nine")

# ------------------------------------------------------------------ second pass (thin groups)
g("money", ["dollar bills currency LCCN", "money bag illustration", "cash register advertisement", "counting money LCCN",
            "stack of coins", "paper money 1900 engraving"], "money cash envelope bribe bank", 7, "Cash money")
g("valentine", ["valentine card 1900", "victorian valentine", "valentine postcard", "courting couple illustration",
                "lovers engraving"], "love valentine letter", 7, "With love")
