#!/usr/bin/env python3
"""Generate a migration that adds 5sim services to the catalog.

Used for both 2026-08-04 batches (20260804200000, 20260804220000). The `S`
list below is whatever the CURRENT batch is -- it holds batch 2. 5sim carries
1,276 products and we now list ~350, so ~930 remain for the next run.

THREE CHECKS, each of which caught a real defect on the first run:

  1. the product must exist in 5sim's live guest/products/any/any -- a typo
     creates a service that can never be priced and reads "Unavailable" forever;
  2. it must not already be mapped -- otherwise the insert is a duplicate;
  3. OUR service id must not already exist. This is the one that is easy to
     miss: the "missing" set is computed on 5SIM PRODUCT SLUGS, so a brand we
     already carry under a different slug does not appear in it. Four did
     (g2a, hepsiburada, grab, claude) and would have been silently skipped by
     `on conflict (id) do nothing`.

Inputs are three files this script does not fetch itself -- see the repo
history for how they were produced:
  5sim_products.json  curl https://5sim.net/v1/guest/products/any/any
  missing.txt         products not in services.fivesim_product
  existing_ids.txt    select id from public.services

Emits only the VALUES block; the surrounding migration is written by hand so
its rationale is reviewed rather than generated.

A FOURTH check earns its place too: tint_hex must be exactly 7 chars of valid
hex. Batch 2 tripped it twice -- a 3-char shorthand ("#F60") and a Gujarati
digit that had crept into a paste ("#07F૪64"). Neither would have failed the
INSERT; both would have rendered a wrong or default colour in the app.
"""
import json, sys

# (fivesim_product, our_id, display_name, category, domain, tint_hex)
S = [
 # ---- Commerce / retail --------------------------------------------------
 ("lowes","lowes","Lowe's","Commerce","lowes.com","#004990"),
 ("samsclub","samsclub","Sam's Club","Commerce","samsclub.com","#0067A0"),
 ("publix","publix","Publix","Commerce","publix.com","#007A33"),
 ("coles","coles","Coles","Commerce","coles.com.au","#E01A22"),
 ("auchan","auchan","Auchan","Commerce","auchan.fr","#E2001A"),
 ("metro","metro","Metro","Commerce","metro.de","#003D7D"),
 ("boots","boots","Boots","Commerce","boots.com","#05054B"),
 ("watsons","watsons","Watsons","Commerce","watsons.com","#00A5A5"),
 ("jbhifi","jbhifi","JB Hi-Fi","Commerce","jbhifi.com.au","#FFF200"),
 ("catawiki","catawiki","Catawiki","Commerce","catawiki.com","#0B4EA2"),
 ("vestiairecollective","vestiaire","Vestiaire Collective","Commerce","vestiairecollective.com","#000000"),
 ("willhaben","willhaben","willhaben","Commerce","willhaben.at","#F58220"),
 ("shpock","shpock","Shpock","Commerce","shpock.com","#00B3A4"),
 ("donedeal","donedeal","DoneDeal","Commerce","donedeal.ie","#E5322D"),
 ("xianyu","xianyu","Xianyu","Commerce","goofish.com","#FFCC00"),
 ("weidian","weidian","Weidian","Commerce","weidian.com","#FF6F00"),
 ("1688","alibaba-1688","1688","Commerce","1688.com","#FF6A00"),
 ("miravia","miravia","Miravia","Commerce","miravia.es","#FF4D4D"),
 ("bigbasket","bigbasket","BigBasket","Commerce","bigbasket.com","#84C225"),
 ("zepto","zepto","Zepto","Commerce","zeptonow.com","#5C2D91"),
 # ---- Delivery / food ----------------------------------------------------
 ("meituan","meituan","Meituan","Delivery","meituan.com","#FFD100"),
 ("eleme","eleme","Ele.me","Delivery","ele.me","#0099FF"),
 ("keeta","keeta","Keeta","Delivery","keeta.com","#FFD100"),
 ("gopuff","gopuff","Gopuff","Delivery","gopuff.com","#00B2A9"),
 ("picnic","picnic","Picnic","Delivery","picnic.app","#E1071B"),
 ("flink","flink","Flink","Delivery","goflink.com","#FF5A00"),
 ("hungerstation","hungerstation","HungerStation","Delivery","hungerstation.com","#F9A01B"),
 ("snappfood","snappfood","SnappFood","Delivery","snappfood.ir","#FF00A6"),
 ("nandos","nandos","Nando's","Delivery","nandos.com","#D51D29"),
 ("greggs","greggs","Greggs","Delivery","greggs.co.uk","#00539F"),
 # ---- Transport ----------------------------------------------------------
 ("yango","yango","Yango","Transport","yango.com","#FFDD00"),
 ("uklon","uklon","Uklon","Transport","uklon.com.ua","#00A3E0"),
 ("bykea","bykea","Bykea","Transport","bykea.com","#00B140"),
 ("swvl","swvl","Swvl","Transport","swvl.com","#E4002B"),
 ("dott","dott","Dott","Transport","ridedott.com","#1E3A8A"),
 ("tier","tier","TIER","Transport","tier.app","#00E676"),
 ("voi","voi","Voi","Transport","voi.com","#F26B5E"),
 ("tada","tada","TADA","Transport","tada.global","#00C4B3"),
 # ---- Travel -------------------------------------------------------------
 ("trip","trip","Trip.com","Travel","trip.com","#287DFA"),
 ("tujia","tujia","Tujia","Travel","tujia.com","#00B0A6"),
 ("tongchengtravel","tongcheng","Tongcheng Travel","Travel","ly.com","#1E90FF"),
 ("vfsglobal","vfsglobal","VFS Global","Travel","vfsglobal.com","#003865"),
 ("immoscout24","immoscout24","ImmoScout24","Travel","immobilienscout24.de","#FF7300"),
 ("seloger","seloger","SeLoger","Travel","seloger.com","#E2001A"),
 ("fotocasa","fotocasa","Fotocasa","Travel","fotocasa.es","#00A0DF"),
 # ---- Social / messaging -------------------------------------------------
 ("likee","likee","Likee","Social","likee.video","#FFCC00"),
 ("kwai","kwai","Kwai","Social","kwai.com","#FF5000"),
 ("lemon8","lemon8","Lemon8","Social","lemon8-app.com","#FFE411"),
 ("azar","azar","Azar","Social","azarlive.com","#3E5BFF"),
 ("band","band","BAND","Social","band.us","#00C73C"),
 ("tamtam","tamtam","TamTam","Messaging","tamtam.chat","#04A8F5"),
 ("botim","botim","BOTIM","Messaging","botim.me","#00B0FF"),
 ("dingtalk","dingtalk","DingTalk","Messaging","dingtalk.com","#3296FA"),
 ("blued","blued","Blued","Social","blued.com","#2D6CDF"),
 ("weverse","weverse","Weverse","Social","weverse.io","#07F064"),
 # ---- Dating -------------------------------------------------------------
 ("tantan","tantan","Tantan","Dating","tantanapp.com","#FF4E6A"),
 ("hily","hily","Hily","Dating","hily.com","#7B2FF7"),
 ("lovoo","lovoo","LOVOO","Dating","lovoo.com","#00A6E0"),
 ("meetic","meetic","Meetic","Dating","meetic.fr","#E6007E"),
 ("meetme","meetme","MeetMe","Dating","meetme.com","#00AEEF"),
 ("taimi","taimi","Taimi","Dating","taimi.com","#8E44AD"),
 ("muzz","muzz","Muzz","Dating","muzz.com","#00B894"),
 ("ashleymadison","ashleymadison","Ashley Madison","Dating","ashleymadison.com","#B01116"),
 # ---- Entertainment ------------------------------------------------------
 ("iqiyi","iqiyi","iQIYI","Entertainment","iqiyi.com","#00BE06"),
 ("wetv","wetv","WeTV","Entertainment","wetv.vip","#FF6A00"),
 ("sonyliv","sonyliv","SonyLIV","Entertainment","sonyliv.com","#00A3E0"),
 ("vidio","vidio","Vidio","Entertainment","vidio.com","#00B0FF"),
 ("megogo","megogo","MEGOGO","Entertainment","megogo.net","#7B1FA2"),
 ("ximalaya","ximalaya","Ximalaya","Entertainment","ximalaya.com","#FF4B33"),
 ("huya","huya","HUYA","Entertainment","huya.com","#FF6600"),
 ("douyu","douyu","DouYu","Entertainment","douyu.com","#FF5D23"),
 ("bigolive","bigolive","BIGO LIVE","Entertainment","bigo.tv","#00C2FF"),
 ("hoyoverse","hoyoverse","HoYoverse","Entertainment","hoyoverse.com","#4A90D9"),
 ("supercell","supercell","Supercell","Entertainment","supercell.com","#F4B223"),
 ("activision","activision","Activision","Entertainment","activision.com","#000000"),
 # ---- Game marketplaces --------------------------------------------------
 ("g2g","g2g","G2G","Commerce","g2g.com","#FF6B00"),
 ("cdkeys","cdkeys","CDKeys","Commerce","cdkeys.com","#F5A623"),
 ("tcgplayer","tcgplayer","TCGplayer","Commerce","tcgplayer.com","#F37021"),
 ("playerauctions","playerauctions","PlayerAuctions","Commerce","playerauctions.com","#0F5B9E"),
 # ---- Crypto -------------------------------------------------------------
 ("cryptocom","cryptocom","Crypto.com","Crypto","crypto.com","#03316C"),
 ("gemini","gemini-exchange","Gemini","Crypto","gemini.com","#00DCFA"),
 ("blockchain","blockchain","Blockchain.com","Crypto","blockchain.com","#1656E3"),
 ("paxful","paxful","Paxful","Crypto","paxful.com","#4A90E2"),
 ("bitso","bitso","Bitso","Crypto","bitso.com","#0A2C4E"),
 # ---- Finance ------------------------------------------------------------
 ("polymarket","polymarket","Polymarket","Finance","polymarket.com","#1652F0"),
 ("moomoo","moomoo","moomoo","Finance","moomoo.com","#FF6B00"),
 ("mobikwik","mobikwik","MobiKwik","Finance","mobikwik.com","#2C3E82"),
 ("gcash","gcash","GCash","Finance","gcash.com","#007DFE"),
 ("paymaya","maya","Maya","Finance","maya.ph","#4CC55B"),
 ("dana","dana","DANA","Finance","dana.id","#118EEA"),
 ("monobank","monobank","monobank","Finance","monobank.ua","#000000"),
 # ---- Tech ---------------------------------------------------------------
 ("oraclecloud","oraclecloud","Oracle Cloud","Tech","oracle.com","#C74634"),
 ("alibabacloud","alibabacloud","Alibaba Cloud","Tech","alibabacloud.com","#FF6A00"),
 ("byteplus","byteplus","BytePlus","Tech","byteplus.com","#1664FF"),
 ("okta","okta","Okta","Tech","okta.com","#007DC1"),
 ("authy","authy","Authy","Tech","authy.com","#EC1C24"),
 ("kaggle","kaggle","Kaggle","Tech","kaggle.com","#20BEFF"),
 # ---- AI -----------------------------------------------------------------
 ("heygen","heygen","HeyGen","AI","heygen.com","#7C3AED"),
 ("codeium","codeium","Codeium","AI","codeium.com","#09B6A2"),
 ("genspark","genspark","Genspark","AI","genspark.ai","#FF5A1F"),
]

ICON = {
 "Commerce":"bag.fill", "Delivery":"takeoutbag.and.cup.and.straw.fill",
 "Transport":"car.fill", "Travel":"airplane", "Tech":"desktopcomputer",
 "AI":"sparkles", "Entertainment":"gamecontroller.fill", "Social":"person.2.fill",
 "Messaging":"bubble.left.and.bubble.right.fill", "Finance":"creditcard.fill",
 "Productivity":"briefcase.fill", "Specialty":"star.fill", "Dating":"heart.fill",
 "Crypto":"bitcoinsign.circle.fill",
}

def q(s): return "'" + s.replace("'", "''") + "'"

def main():
    products = set(json.load(open('/Users/adyl/.claude/jobs/744c6e4a/tmp/5sim_products.json')))
    missing  = set(open('/Users/adyl/.claude/jobs/744c6e4a/tmp/missing.txt').read().split())
    existing = set(open('/Users/adyl/.claude/jobs/744c6e4a/tmp/existing_ids.txt').read().split())

    errs, seen_p, seen_id = [], set(), set()
    for p, sid, name, cat, dom, tint in S:
        if p not in products: errs.append(f"NOT a 5sim product: {p}")
        elif p not in missing: errs.append(f"already mapped: {p}")
        if sid in existing: errs.append(f"service id ALREADY EXISTS: {sid} ({name})")
        if cat not in ICON: errs.append(f"unknown category {cat} for {p}")
        if p in seen_p: errs.append(f"duplicate product: {p}")
        if sid in seen_id: errs.append(f"duplicate id: {sid}")
        if not tint.startswith('#') or len(tint) != 7 or any(c not in '0123456789ABCDEFabcdef' for c in tint[1:]):
            errs.append(f"bad tint {tint!r} for {p}")
        seen_p.add(p); seen_id.add(sid)
    if errs:
        print("VALIDATION FAILED:"); [print("  -", e) for e in errs]; sys.exit(1)

    print(f"validated {len(S)} services")
    lines = [f"  ({q(sid)}, {q(name)}, {q(cat)}, {q(dom)}, {q(tint)}, "
             f"{q(name[0].upper())}, {q(ICON[cat])}, {11000 + i*10}, {q(p)}, '')"
             for i, (p, sid, name, cat, dom, tint) in enumerate(S)]
    open('/Users/adyl/.claude/jobs/744c6e4a/tmp/services_values2.sql','w').write(",\n".join(lines))
    print("wrote VALUES block")

if __name__ == "__main__":
    main()
