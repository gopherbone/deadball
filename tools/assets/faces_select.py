"""Caption-level filtering for the face bank: who is a usable, non-famous single sitter,
how to group photos of the same real person, and caption hints for sex/age."""
import re

# People we never want as faces (in-game names are fictional; famous faces would clash).
# Lower-case substrings matched against the title and the subject headings.
FAMOUS = """
babe ruth|ruth, babe|cobb, ty|ty cobb|mathewson|christy matty|walter johnson|johnson, walter|wagner, honus|honus wagner
|cy young|young, cy|connie mack|mack, connie|mcgillicuddy|mcgraw|landis|comiskey|tris speaker|speaker, tris|eddie collins
|collins, eddie|nap lajoie|lajoie|grover cleveland alexander|alexander, grover|pete alexander|frank chance|chance, frank
|johnny evers|evers, john|joe tinker|tinker, joe|rube marquard|marquard|eddie plank|plank, eddie|chief bender|bender, charles
|home run baker|baker, frank|frank baker|ed walsh|walsh, ed|george sisler|sisler|rogers hornsby|hornsby|joe jackson
|jackson, joe|shoeless|eddie cicotte|cicotte|buck weaver|chick gandil|lefty williams|happy felsch|swede risberg
|fred mcmullin|hughie jennings|jennings, hugh|miller huggins|huggins|wilbert robinson|robinson, wilbert|branch rickey|rickey
|ban johnson|johnson, ban|harry frazee|frazee|jacob ruppert|ruppert|charles ebbets|ebbets|barney dreyfuss|dreyfuss
|clark griffith|griffith, clark|roger bresnahan|bresnahan|ray schalk|schalk|max carey|zack wheat|wheat, zack|sam crawford
|crawford, sam|harry hooper|hooper, harry|rabbit maranville|maranville|dave bancroft|frankie frisch|frisch|george kelly
|ross youngs|casey stengel|stengel|burleigh grimes|stan coveleski|coveleski|red faber|faber, urban|eppa rixey|herb pennock
|waite hoyt|bob meusel|lou gehrig|gehrig|heinie groh|edd roush|roush|harry heilmann|heilmann|goose goslin|sam rice
|bucky harris|ty cobb|hank gowdy|three finger|mordecai brown|brown, mordecai|rube waddell|waddell|addie joss|joss
|jimmy collins|hugh duffy|duffy, hugh|bill klem|klem|silk o'loughlin|jim thorpe|thorpe|fred merkle|merkle|smoky joe wood
|eddie ainsmith|joe mcginnity|mcginnity|chief meyers|larry doyle|fred clarke|clarke, fred|bill dahlen|willie keeler|keeler
|dazzy vance|ray chapman|carl mays|george stallings|pat moran|fielder jones|kid gleason|gleason, william|jim mcaleer
|wilson, woodrow|woodrow wilson|president wilson|taft|roosevelt|harding|coolidge|hoover|bryan, william|william jennings
|pershing|joffre|foch|haig|kitchener|kaiser|wilhelm|king george|queen|prince of wales|tsar|czar|nicholas ii|edison|ford, henry
|henry ford|wright, orville|wilbur wright|orville wright|rockefeller|carnegie|vanderbilt|astor|morgan, j. p|j.p. morgan
|pierpont|caruso|chaplin|houdini|pickford|fairbanks|gish|valentino|barrymore|al jolson|jolson|irving berlin|cohan
|sousa|paderewski|pavlova|nijinsky|isadora duncan|sarah bernhardt|bernhardt|lillian russell|helen keller|keller, helen
|einstein|marconi|tesla|jack johnson|johnson, jack|jess willard|willard, jess|jack dempsey|dempsey|georges carpentier
|carpentier|jim jeffries|jeffries|bobby jones|walter hagen|bill tilden|tilden|suzanne lenglen|lenglen|pankhurst|alice paul
|paul, alice|catt, carrie|carrie chapman|milholland|anna howard shaw|shaw, anna|lucy burns|harriot stanton|blatch
|jane addams|addams|emma goldman|goldman, emma|mother jones|big bill haywood|haywood|debs|gompers|lindbergh
|amelia earhart|earhart|harry thaw|evelyn nesbit|nesbit|stanford white|lodge, henry|la follette|hughes, charles
|lansing|tumulty|mcadoo|daniels, josephus|baker, newton|bryan|marshall, thomas|sims, william|dewey|peary|cook, frederick
|amundsen|shackleton|scott, robert|lloyd george|clemenceau|orlando, vittorio|lenin|trotsky|kerensky|mussolini|gandhi
|sun yat|yuan shi|alfonso|victor emmanuel|albert i|pope|cardinal gibbons|gibbons, james|billy sunday|sunday, billy
|john d.|grace coolidge|edith wilson|eleanor roosevelt|alice roosevelt|longworth|helen taft|nellie taft|jim corbett
|corbett, james|john l. sullivan|ty  cobb|barney oldfield|oldfield|ralph depalma|de palma|eddie rickenbacker|rickenbacker
|glenn curtiss|curtiss|harry k. thaw|charlie chaplin|mary pickford|douglas fairbanks|w. c. fields|will rogers|rogers, will
|fanny brice|ziegfeld|eva tanguay|nora bayes|elsie janis|irene castle|vernon castle|castle, irene|castle, vernon
|annette kellerman|kellerman|enrico|fritz kreisler|kreisler|geraldine farrar|farrar|mme. schumann|schumann-heink
|lillian gish|dorothy gish|theda bara|pearl white|billie burke|maude adams|ethel barrymore|john barrymore|william s. hart
|tom mix|cobb|spalding|hanlon|mckechnie|morgenthau|rathenau|sadi carnot|garibaldi|greasy neale
|joe wood|alice hamilton|john evers|hooper|chesbro|elmer flick|traynor|hank o'day|hal chase|langtry|franklin baker
|"home run" baker|jay gould|cassatt|william t. jerome|curie|bernard shaw|lafollette|c.e. hughes|winston churchill
|jack london|westinghouse|tetrazzini|sembrich|schumann|hearst|planck|planeck|blériot|bleriot|eugene ely|bizet
|bramwell booth|c.c. catt|alma gluck|chanute|darwin|rostron|eaker|royal copeland|john b. murphy|pupin|gullstrand
|abderhalden|virchow|willstätter|willstatter|kammerer|f.r. burnham|bullard|guynemar|guynemer|h.c. lodge|cortelyou
|wm. loeb|manners|pulitzer|stewart richardson|grace george|hazel dawn|ethel clayton|bonaparte|breckinridge
|marguerite-durand|i.k. funk|emmett holt|sigsbee|thomas s. baldwin|billy wells|al palzer|cantacuzene
|walter dill scott|pickering|curtis guild|spooner|fortune gallo|millerand|harry c. new|lady carson|h.b. irving
|russell sage|badoglio|randolph churchill|upton sinclair|learned hand|toscanini|rodgers|orozco|krogh|locatelli|bowes-lyon|asquith|cornwallis west|hyacinthe|c.h. best|stanley hall|w.t. turner|highpockets|benj. strong|sam hughes|harry new|whitney's|vanderbilt|belmont|mrs. jack|dumas|lily elsie|duffy lewis|mabel normand|fatty arbuckle|arbuckle|mack sennett|d.w. griffith|griffith, d|thomas ince|jack pickford
""".replace("\n", "")
FAMOUS_RE = re.compile("|".join(re.escape(s.strip()) for s in FAMOUS.split("|") if s.strip()))

# Captions that suggest not-a-single-adult-portrait.
GROUP_RE = re.compile(r"\b(and|&|group|team|teams|crowd|parade|scene|view|game|games|children|child|baby|babies|"
                      r"boys|girls|boy|girl|kids|infant|family|brothers|sisters|wedding party|party|meeting|"
                      r"funeral|ruins|building|ship|automobile race|street|horse show|dog show|camp|class|"
                      r"stadium|grounds|bleachers|statue|monument|house|home of|residence|cartoon|drawing|"
                      r"painting|sketch|map|poster|race|regatta|chorus|band|delegation|delegates|committee|"
                      r"officers|members|players|men|women|ladies|nurses|soldiers|troops|squad|crew|bust|statue|"
                      r"painting|caricature|sculpture|wax|effigy)\b", re.I)

FEMALE_RE = re.compile(r"\b(mrs|miss|mme|mlle|madame|mademoiselle|lady|countess|princess|duchess|baroness|"
                       r"marchioness|senora|signora|frau|fraulein|actress|suffragist|suffragette|"
                       r"woman|wife|widow|bride|heiress|her|she|daughter|mother|aunt|nun|sister)\b", re.I)
FEMALE_SUBJ_RE = re.compile(r"^(Women|Actresses|Suffragists|Female|Wives|Mothers|Daughters|Nuns|Girls)", re.I)
OLD_RE = re.compile(r"\b(old|aged|elderly|veteran|oldest|centenarian|grandmother|grandfather|"
                    r"civil war|g\.a\.r\.|pioneer)\b", re.I)


def person_subject(e):
    """First personal-name subject heading ('Last, First,--1889-1958.') or None."""
    for s in e.get("subjects", []):
        head = s.split("--")[0]
        if "," in head and not re.match(r"^(Baseball|Group|Portrait|Photographic|Women|Men|Children)", head):
            return s
    return None


def life_years(subject):
    if not subject:
        return None, None
    m = re.search(r"(\d{4})\??-(\d{4})?", subject)
    if not m:
        m = re.search(r"b\. ?(\d{4})", subject)
        return (int(m.group(1)), None) if m else (None, None)
    return int(m.group(1)), (int(m.group(2)) if m.group(2) else None)


def photo_year(e):
    m = re.search(r"(1[89]\d\d)", e.get("date", "") or "")
    if m:
        return int(m.group(1))
    for s in e.get("subjects", []):
        m = re.search(r"--(1[89]\d0)-(1[89]\d0)\.?$", s)
        if m:
            return (int(m.group(1)) + int(m.group(2))) // 2
    return None


def clean_title(t):
    t = t.strip().strip("[]").strip()
    return re.sub(r"\s+", " ", t)


def person_key(e):
    """Stable key grouping photos of the same real person."""
    s = person_subject(e)
    if s:
        head = s.split("--")[0]
        name = re.sub(r",?\s*\d{4}.*$", "", head).strip(" ,.")
        return "s:" + re.sub(r"[^a-z]+", " ", name.lower()).strip()
    t = clean_title(e["title"])
    name = re.split(r",|\(|\bof\b|\bat\b|\bin\b|\bwith\b", t)[0]
    return "t:" + re.sub(r"[^a-z]+", " ", name.lower()).strip()


def is_famous(e):
    blob = (e.get("title", "") + " | " + " | ".join(e.get("subjects", []))).lower()
    return bool(FAMOUS_RE.search(blob))


FEMALE_FIRST = set("""ada adele agnes alice alma amelia amy ann anna anne annie beatrice bertha bessie blanche
carolina caroline carrie catherine charlotte clara constance cora daisy dorothy edith edna eleanor elinor
eliza elizabeth ella ellen elsie emily emma ethel eva evelyn florence frances gertrude grace hannah harriet
hazel helen helena henrietta ida inez irene isabel jane janet jean jennie jessie josephine julia kate
katherine kathleen laura lillian lily lois louise lucy mabel madeleine mae margaret marguerite maria marie
marion martha mary maud maude mildred minnie muriel myrtle nancy nellie nora olga olive pauline pearl
rachel rose ruth sadie sallie sarah sophie susan theodora vera violet virginia viola winifred""".split())


def caption_sex(e):
    t = clean_title(e["title"])
    name = re.split(r"[,(]", t.lower())[0]
    toks = [w.strip('."') for w in name.split()[:3]]
    if any(w in FEMALE_FIRST for w in toks):
        return "F"
    if FEMALE_RE.search(t):
        return "F"
    if any(FEMALE_SUBJ_RE.match(s) for s in e.get("subjects", [])):
        return "F"
    return None


def caption_age(e):
    b, _ = life_years(person_subject(e))
    y = photo_year(e)
    if b and y and 1840 < b < y:
        age = y - b
        if age <= 25:
            return "young", age
        if age >= 50:
            return "old", age
        return "adult", age
    if OLD_RE.search(e["title"]):
        return "old", None
    return None, None


# public officials / nobility: skip as potentially "famous" (and they read as non-baseball anyway)
OFFICIAL_RE = re.compile(r"\b(senator|sen\.|gov\.|governor|hon\.|secretary|sec\.|ambassador|minister to|"
                         r"congressman|rep\.|president|vice president|king|queen|prince|princess|count|"
                         r"countess|baron|baroness|duke|duchess|lord|emperor|empress|general|gen\.|admiral|"
                         r"adm\.|mayor|president's|cardinal|pope|bishop)(?!\w)", re.I)


BYART_RE = re.compile(r"\bby [A-Z][a-z]+$|\bby [A-Z]\.|cameo|engraving|etching|lithograph|\bwater baseball\b|"
                      r"activities|\bbombs\b", re.I)


def prefilter(index):
    """pk list of single-sitter, non-famous candidates."""
    out = []
    for pk, e in index.items():
        t = clean_title(e["title"])
        if is_famous(e):
            continue
        # strip parenthetical "(baseball)" etc. before group test
        core = re.sub(r"\(.*?\)", "", t)
        if "&" in core or GROUP_RE.search(core) or OFFICIAL_RE.search(core) or BYART_RE.search(t) or t.count(",") >= 3 and "baseball" not in t.lower():
            continue
        out.append(pk)
    return out


TITLE_WORDS = set("""mrs mr miss mme mlle dr prof rev judge capt col lieut lt major maj manager pitcher catcher
coach umpire sgt jr sr hon lady sir inspector""".split())


def name_parts(e):
    """(last, {first names / nicknames}) from the caption, for merging photos of one person."""
    t = clean_title(e["title"])
    nick = set(w.lower() for w in re.findall(r'"([^"]+)"', t))
    name = re.split(r"[,(]", re.sub(r'"[^"]*"', " ", t))[0]
    name = re.sub(r"\bi\.e\.?", " ", name, flags=re.I)
    toks = [w.strip(".").lower() for w in re.findall(r"[A-Za-z][A-Za-z.'\-]*", name)]
    toks = [w for w in toks if w not in TITLE_WORDS and len(w) > 1]
    if len(toks) < 2:
        return None
    return toks[-1], set(toks[:-1]) | nick


ABBREV = set("wm chas geo jas thos robt rob't edw jno benj sam'l saml wm. dr j h c a b e f g l m r s t w".split())


def same_person_names(fa, fb, ea, eb):
    """Shared first name/nickname (not an abbreviation), same sex, and no "Mrs. <husband>" captions."""
    if caption_sex(ea) != caption_sex(eb):
        return False
    if re.match(r"\s*\[?mrs\.", ea["title"], re.I) or re.match(r"\s*\[?mrs\.", eb["title"], re.I):
        return False
    shared = {w for w in fa & fb if w not in ABBREV and len(w) > 2 and "." not in w}
    return bool(shared)
