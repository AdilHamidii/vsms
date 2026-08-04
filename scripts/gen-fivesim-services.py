#!/usr/bin/env python3
"""Generate a migration that adds 5sim services to the catalog.

Used for the 100 added on 2026-08-04 (migration 20260804200000). Keep it for
the next batch -- 5sim carries 1,276 products and we now list ~250, so there is
a long tail left.

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
"""


import json, sys

# (fivesim_product, our_id, display_name, category, domain, tint_hex)
S = [
 # ---- Commerce / marketplaces -------------------------------------------
 ("ebay","ebay","eBay","Commerce","ebay.com","#E53238"),
 ("etsy","etsy","Etsy","Commerce","etsy.com","#F1641E"),
 ("aliexpress","aliexpress","AliExpress","Commerce","aliexpress.com","#E62E04"),
 ("temu","temu","Temu","Commerce","temu.com","#FB7701"),
 ("shein","shein","SHEIN","Commerce","shein.com","#000000"),
 ("wish","wish","Wish","Commerce","wish.com","#2FB7EC"),
 ("taobao","taobao","Taobao","Commerce","taobao.com","#FF4400"),
 ("jd","jd","JD.com","Commerce","jd.com","#E1251B"),
 ("pinduoduo","pinduoduo","Pinduoduo","Commerce","pinduoduo.com","#E22E1F"),
 ("rakuten","rakuten","Rakuten","Commerce","rakuten.com","#BF0000"),
 ("allegro","allegro","Allegro","Commerce","allegro.pl","#FF5A00"),
 ("emag","emag","eMAG","Commerce","emag.ro","#0071BC"),
 ("rozetka","rozetka","Rozetka","Commerce","rozetka.com.ua","#00A046"),
 ("trendyol","trendyol","Trendyol","Commerce","trendyol.com","#F27A1A"),
 ("baidu","baidu","Baidu","Tech","baidu.com","#2932E1"),
 ("flipkart","flipkart","Flipkart","Commerce","flipkart.com","#2874F0"),
 ("myntra","myntra","Myntra","Commerce","myntra.com","#FF3F6C"),
 ("meesho","meesho","Meesho","Commerce","meesho.com","#F43397"),
 ("tokopedia","tokopedia","Tokopedia","Commerce","tokopedia.com","#42B549"),
 ("bukalapak","bukalapak","Bukalapak","Commerce","bukalapak.com","#E31E52"),
 ("coupang","coupang","Coupang","Commerce","coupang.com","#B12704"),
 ("carousell","carousell","Carousell","Commerce","carousell.com","#FF4F4F"),
 ("noon","noon","Noon","Commerce","noon.com","#FEEE00"),
 ("poshmark","poshmark","Poshmark","Commerce","poshmark.com","#731A25"),
 ("depop","depop","Depop","Commerce","depop.com","#FF0000"),
 ("gumtree","gumtree","Gumtree","Commerce","gumtree.com","#72EF36"),
 ("shopify","shopify","Shopify","Commerce","shopify.com","#95BF47"),
 ("duolingo","duolingo","Duolingo","Productivity","duolingo.com","#58CC02"),
 ("humblebundle","humblebundle","Humble Bundle","Commerce","humblebundle.com","#CC2929"),
 # ---- Retail brands ------------------------------------------------------
 ("nike","nike","Nike","Commerce","nike.com","#111111"),
 ("adidas","adidas","Adidas","Commerce","adidas.com","#000000"),
 ("zara","zara","Zara","Commerce","zara.com","#000000"),
 ("footlocker","footlocker","Foot Locker","Commerce","footlocker.com","#E4002B"),
 ("carrefour","carrefour","Carrefour","Commerce","carrefour.com","#004E9F"),
 ("tesco","tesco","Tesco","Commerce","tesco.com","#00539F"),
 ("lidl","lidl","Lidl","Commerce","lidl.com","#0050AA"),
 ("7eleven","seven-eleven","7-Eleven","Commerce","7-eleven.com","#F37021"),
 ("cocacola","cocacola","Coca-Cola","Commerce","coca-cola.com","#F40009"),
 # ---- Food / delivery ----------------------------------------------------
 ("mcdonalds","mcdonalds","McDonald's","Delivery","mcdonalds.com","#FFC72C"),
 ("burgerking","burgerking","Burger King","Delivery","bk.com","#D62300"),
 ("kfc","kfc","KFC","Delivery","kfc.com","#A50034"),
 ("pizzahut","pizzahut","Pizza Hut","Delivery","pizzahut.com","#EE3A43"),
 ("dominospizza","dominos","Domino's Pizza","Delivery","dominos.com","#006491"),
 ("dunkin","dunkin","Dunkin'","Delivery","dunkindonuts.com","#FF671F"),
 ("justeat","justeat","Just Eat","Delivery","just-eat.com","#FF8000"),
 ("zomato","zomato","Zomato","Delivery","zomato.com","#E23744"),
 ("swiggy","swiggy","Swiggy","Delivery","swiggy.com","#FC8019"),
 ("talabat","talabat","Talabat","Delivery","talabat.com","#FF5A00"),
 ("getir","getir","Getir","Delivery","getir.com","#5D3EBC"),
 ("rappi","rappi","Rappi","Delivery","rappi.com","#FF441F"),
 # ---- Transport ----------------------------------------------------------
 ("gojek","gojek","Gojek","Transport","gojek.com","#00AA13"),
 ("paytm","paytm","Paytm","Finance","paytm.com","#00BAF2"),
 ("blablacar","blablacar","BlaBlaCar","Transport","blablacar.com","#00AFF5"),
 ("indriver","indriver","inDrive","Transport","indrive.com","#C1F11D"),
 ("rapido","rapido","Rapido","Transport","rapido.bike","#FFCC00"),
 ("olacabs","olacabs","Ola","Transport","olacabs.com","#B4D22E"),
 ("freenow","freenow","FREENOW","Transport","free-now.com","#FF00FF"),
 ("lime","lime","Lime","Transport","li.me","#00DD00"),
 # ---- Travel -------------------------------------------------------------
 ("irctc","irctc","IRCTC","Travel","irctc.co.in","#213B78"),
 ("redbus","redbus","redBus","Travel","redbus.in","#D84E55"),
 ("klook","klook","Klook","Travel","klook.com","#FF5722"),
 ("oyo","oyo","OYO","Travel","oyorooms.com","#EE2E24"),
 ("qantas","qantas","Qantas","Travel","qantas.com","#E40000"),
 ("unitedairlines","united-airlines","United Airlines","Travel","united.com","#002244"),
 ("airasia","airasia","AirAsia","Travel","airasia.com","#FF0000"),
 # ---- Tech ---------------------------------------------------------------
 ("nvidia","nvidia","NVIDIA","Tech","nvidia.com","#76B900"),
 ("gitlab","gitlab","GitLab","Tech","gitlab.com","#FC6D26"),
 ("adobe","adobe","Adobe","Tech","adobe.com","#FF0000"),
 ("opera","opera","Opera","Tech","opera.com","#FF1B2D"),
 ("proton","proton","Proton","Tech","proton.me","#6D4AFF"),
 ("xiaomi","xiaomi","Xiaomi","Tech","mi.com","#FF6900"),
 ("razer","razer","Razer","Tech","razer.com","#44D62C"),
 ("tradingview","tradingview","TradingView","Finance","tradingview.com","#2962FF"),
 ("skype","skype","Skype","Messaging","skype.com","#00AFF0"),
 # ---- AI -----------------------------------------------------------------
 ("instacart","instacart","Instacart","Delivery","instacart.com","#43B02A"),
 ("perplexity","perplexity","Perplexity","AI","perplexity.ai","#20808D"),
 ("deepseek","deepseek","DeepSeek","AI","deepseek.com","#4D6BFE"),
 ("mistralai","mistral","Mistral AI","AI","mistral.ai","#FA520F"),
 ("suno","suno","Suno","AI","suno.com","#000000"),
 # ---- Gaming / entertainment --------------------------------------------
 ("roblox","roblox","Roblox","Entertainment","roblox.com","#E2231A"),
 ("epicgames","epicgames","Epic Games","Entertainment","epicgames.com","#2A2A2A"),
 ("nintendo","nintendo","Nintendo","Entertainment","nintendo.com","#E60012"),
 ("ubisoft","ubisoft","Ubisoft","Entertainment","ubisoft.com","#000000"),
 ("riotgames","riotgames","Riot Games","Entertainment","riotgames.com","#D32936"),
 ("pubg","pubg","PUBG","Entertainment","pubg.com","#F2A900"),
 ("garena","garena","Garena","Entertainment","garena.com","#EE3B33"),
 ("faceit","faceit","FACEIT","Entertainment","faceit.com","#FF5500"),
 ("bilibili","bilibili","Bilibili","Entertainment","bilibili.com","#00A1D6"),
 ("spotify","spotify","Spotify","Entertainment","spotify.com","#1DB954"),
 # ---- Social -------------------------------------------------------------
 ("bereal","bereal","BeReal","Social","bereal.com","#000000"),
 ("bluesky","bluesky","Bluesky","Social","bsky.app","#0085FF"),
 ("nextdoor","nextdoor","Nextdoor","Social","nextdoor.com","#8ED500"),
 ("weibo","weibo","Weibo","Social","weibo.com","#E6162D"),
 ("medium","medium","Medium","Social","medium.com","#000000"),
 ("substack","substack","Substack","Social","substack.com","#FF6719"),
 # ---- Work / misc --------------------------------------------------------
 ("upwork","upwork","Upwork","Productivity","upwork.com","#14A800"),
 ("fiverr","fiverr","Fiverr","Productivity","fiverr.com","#1DBF73"),
 ("indeed","indeed","Indeed","Productivity","indeed.com","#2164F3"),
 ("eventbrite","eventbrite","Eventbrite","Specialty","eventbrite.com","#F05537"),
 ("gofundme","gofundme","GoFundMe","Finance","gofundme.com","#02A95C"),
]

ICON = {
 "Commerce":"bag.fill", "Delivery":"takeoutbag.and.cup.and.straw.fill",
 "Transport":"car.fill", "Travel":"airplane", "Tech":"desktopcomputer",
 "AI":"sparkles", "Entertainment":"gamecontroller.fill", "Social":"person.2.fill",
 "Messaging":"bubble.left.and.bubble.right.fill", "Finance":"creditcard.fill",
 "Productivity":"briefcase.fill", "Specialty":"star.fill",
}
VALID_CATS = set(ICON)

def q(s): return "'" + s.replace("'", "''") + "'"

def main():
    products = set(json.load(open('/Users/adyl/.claude/jobs/744c6e4a/tmp/5sim_products.json')))
    missing = set(open('/Users/adyl/.claude/jobs/744c6e4a/tmp/missing.txt').read().split())
    existing = set(open('/Users/adyl/.claude/jobs/744c6e4a/tmp/existing_ids.txt').read().split())

    errs = []
    seen_p, seen_id = set(), set()
    for p, sid, name, cat, dom, tint in S:
        if p not in products: errs.append(f"NOT a 5sim product: {p}")
        if p not in missing:  errs.append(f"already mapped (would duplicate): {p}")
        if cat not in VALID_CATS: errs.append(f"unknown category {cat} for {p}")
        if sid in existing: errs.append(f"service id ALREADY EXISTS in catalog: {sid} ({name})")
        if p in seen_p: errs.append(f"duplicate product: {p}")
        if sid in seen_id: errs.append(f"duplicate id: {sid}")
        if not tint.startswith('#') or len(tint) != 7: errs.append(f"bad tint {tint} for {p}")
        seen_p.add(p); seen_id.add(sid)
    if errs:
        print("VALIDATION FAILED:"); [print("  -", e) for e in errs]; sys.exit(1)

    print(f"validated {len(S)} services, all present in 5sim catalog and none already mapped")
    if len(S) != 100:
        print(f"WARNING: {len(S)} rows, expected 100")

    lines = []
    for i, (p, sid, name, cat, dom, tint) in enumerate(S):
        lines.append(
          f"  ({q(sid)}, {q(name)}, {q(cat)}, {q(dom)}, {q(tint)}, "
          f"{q(name[0].upper())}, {q(ICON[cat])}, {10000 + i*10}, {q(p)}, '')")
    open('/Users/adyl/.claude/jobs/744c6e4a/tmp/services_values.sql','w').write(",\n".join(lines))
    print("wrote VALUES block")

if __name__ == "__main__":
    main()
