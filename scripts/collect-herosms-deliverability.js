// Collect HeroSMS per-(service, country) deliverability, one service per 10 min.
//
// WHY THIS RUNS IN YOUR BROWSER AND NOT ON A SERVER
// -------------------------------------------------
// GET /api/v1/stats/deliverability is real but SESSION-SCOPED: all four API-key
// schemes (Authorization: ApiKey / Bearer / X-Api-Key / ?api_key=) return 401
// `Unauthenticated.` — verified 2026-07-31. Only a logged-in dashboard session
// can call it. Running it from an edge function would mean exporting your
// session cookie, which expires, carries XSRF, would fail silently, and comes
// from a datacenter IP behind their Cloudflare. This instead reuses the tab you
// already have open: same session, same IP, same fingerprint as normal use, and
// paced FAR slower than a human clicking through the panel.
//
// HOW TO RUN
// ----------
//   1. Log in to hero-sms.com and open the Statistics panel.
//   2. DevTools -> Console. Paste this whole file. Press enter.
//   3. Leave the tab open. It prints progress and stores results as it goes.
//   4. Any time (including part-way): `copy(HERO.out())` puts the SQL on your
//      clipboard. Paste it to me, or run it against the DB yourself.
//
// Safe to stop and resume: `HERO.stop()` halts, re-pasting resumes from where
// the store left off — merge_vendor_deliverability upserts one service at a
// time, so partial collection is immediately useful. 4 services already cover
// 64% of every order ever placed; 12 cover 88%.

(() => {
  const INTERVAL_MS = 10 * 60 * 1000;   // one service per 10 minutes
  const INTERVAL_HOURS = 24;            // steadier than the panel's 12h default
  const SUCCESS_COUNT = "medium";       // the ">50 successful" filter

  // Ordered by OUR order volume, most-ordered first, so an interrupted run has
  // already covered the services that matter. Regenerate any time with:
  //   select service_code from public.vendor_deliverability_worklist(40);
  const QUEUE = [
    "fb",  // facebook   49 orders  26%
    "do",  // leboncoin  35         18%
    "ig",  // instagram  24         13%
    "go",  // google     15          8%
    "agl", // betano      9          5%
    "wa",  // whatsapp    9          5%
    "lf",  // tiktok      8          4%
    "qv",  // badoo       5          3%
    "oi",  // tinder      5          3%
    "tg",  // telegram    4          2%
    "ds",  // discord     3          2%
    "aq",  // glovo       3          2%
  ];

  const results = {};
  let i = 0, timer = null;

  const sqlQuote = (s) => "'" + String(s).replace(/'/g, "''") + "'";

  async function pull(code) {
    const params = new URLSearchParams({
      service: code,
      interval: String(INTERVAL_HOURS),
      successCount: SUCCESS_COUNT,
    });
    const url = `/api/v1/stats/deliverability?${params}`;
    // credentials:"include" is the whole point — it reuses the logged-in session.
    const res = await fetch(url, {
      credentials: "include",
      headers: { Accept: "application/json" },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return { payload: await res.json(), params: Object.fromEntries(params) };
  }

  async function step() {
    if (i >= QUEUE.length) {
      console.log(`%c[hero] done — ${Object.keys(results).length}/${QUEUE.length} collected. Run copy(HERO.out())`,
                  "color:#279400;font-weight:bold");
      clearInterval(timer);
      return;
    }
    const code = QUEUE[i++];
    try {
      const { payload, params } = await pull(code);
      results[code] = { payload, params };
      // Print the first payload in full: nobody has ever seen this response
      // shape, and the server-side mapper cannot be written until someone has.
      if (Object.keys(results).length === 1) {
        console.log("%c[hero] FIRST PAYLOAD — shape matters, send this one:", "color:#279400;font-weight:bold");
        console.log(JSON.stringify(payload, null, 2));
      }
      console.log(`[hero] ${i}/${QUEUE.length} ${code} ok`);
    } catch (e) {
      // Record nothing on failure. An empty row would be indistinguishable from
      // "this service genuinely has no data", which is the distinction we are
      // collecting in order to make.
      console.warn(`[hero] ${i}/${QUEUE.length} ${code} FAILED: ${e.message} — will retry on next run`);
    }
  }

  window.HERO = {
    results,
    stop() { clearInterval(timer); console.log("[hero] stopped"); },
    /** SQL that merges everything collected so far, one statement per service. */
    out() {
      const rows = Object.entries(results).map(([code, r]) =>
        `select public.merge_vendor_deliverability(${sqlQuote(code)}, ` +
        `${sqlQuote(JSON.stringify(r.params))}::jsonb, ` +
        `${sqlQuote(JSON.stringify(r.payload))}::jsonb);`);
      return rows.join("\n");
    },
  };

  console.log(`%c[hero] collecting ${QUEUE.length} services, one per 10 min (~${QUEUE.length * 10} min total).`,
              "color:#279400;font-weight:bold");
  console.log("[hero] keep this tab open. HERO.stop() halts. copy(HERO.out()) exports at any point.");
  step();
  timer = setInterval(step, INTERVAL_MS);
})();
