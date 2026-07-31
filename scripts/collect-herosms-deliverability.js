// Collect HeroSMS per-(service, country) deliverability for the whole catalog.
//
// ── HOW TO RUN ─────────────────────────────────────────────────────────────
//   1. Log in to hero-sms.com and open the Statistics page (the session cookie
//      is origin-scoped, so it must be a hero-sms.com tab).
//   2. F12 -> Console. If Chrome refuses to paste, type  allow pasting  first,
//      press enter, then paste.
//   3. Paste this whole file, press enter. Leave the tab open.
//   4. At ANY point:  copy(HERO.sql())  puts the merge SQL on your clipboard.
//
//   HERO.stop()      halt          HERO.status()   progress
//   HERO.sql()       export SQL    HERO.reset()    start over (wipes progress)
//
// Progress is saved to localStorage after every service, so closing the tab,
// reloading, or a crash loses nothing — re-paste and it resumes where it left
// off. Only unfetched services are requested again.
//
// ── WHY THIS RUNS IN YOUR BROWSER ──────────────────────────────────────────
// GET /api/v1/stats/deliverability is real but SESSION-SCOPED: Authorization
// ApiKey / Bearer / X-Api-Key and ?api_key= all return 401 Unauthenticated
// (verified 2026-07-31). Only a logged-in dashboard session can call it. Doing
// this server-side would mean exporting your session cookie to an edge
// function: it expires, it carries XSRF, it would fail silently, and it would
// originate from a datacenter IP behind their Cloudflare. Here it reuses the
// tab you already have open — same session, same IP, same fingerprint.

(() => {
  // ── Pace ──────────────────────────────────────────────────────────────────
  // 147 services, so the interval decides how long this takes:
  //     600s -> ~25 h      120s -> ~5 h      60s -> ~2.5 h      30s -> ~74 min
  // For calibration: a person exploring that panel — changing service, interval
  // and the successCount filter — fires a request per interaction, easily 10-20
  // in a couple of minutes. 30s (2/min) is slower than active browsing, but it
  // is SUSTAINED for over an hour, which is a different signature from a burst.
  // If anything starts 429ing or challenging, raise this rather than retrying:
  // the account serves ~all SMS volume and is worth more than the data.
  // The FIRST FOUR services cover 64% of every order ever taken and the first
  // twelve cover 88%, so the valuable part lands in the opening minutes.
  const INTERVAL_SECONDS = 30;

  const INTERVAL_HOURS = 24;      // longer window than the panel's 12h default
  const SUCCESS_COUNT  = "medium"; // the ">50 successful" filter
  const STORE_KEY      = "hero_deliverability_v1";

  // Every visible service with a HeroSMS code, ordered by OUR order volume so
  // an interrupted run has already covered what matters. Regenerate with:
  //   select service_code from public.vendor_deliverability_worklist(500);
  const QUEUE = [...new Set([
    "fb", "do", "ig", "go", "agl", "wa", "lf", "qv", "oi", "tg", "ds",
    "aq", "qq", "rr", "dr", "tw", "hw", "wx", "mo", "me", "vm", "pf", "gp",
    "kc", "wr", "wb", "bex", "ya", "uk", "am", "pm", "gr", "cb",
    "ov", "ie", "vd", "bz", "tx", "aiz", "ahe", "apr", "ls", "brc", "azy",
    "boo", "acz", "et", "re", "wc", "aje", "zk", "xk", "ac", "we", "uf",
    "bcr", "bhz", "ws", "abe", "nz", "uz", "ccu", "ccx", "gf", "jg", "agd",
    "yw", "df", "gx", "vz", "kk", "pd", "im", "il", "za", "kt", "afz",
    "aop", "aid", "fh", "dl", "tn", "ex", "tu", "mg", "ma", "fd", "agj",
    "axr", "bpq", "mm", "bry", "hc", "py", "qo", "nv", "aok", "nf", "zm",
    "aor", "sn", "ue", "auz", "sg", "cw", "bla", "nc", "ts", "jq", "tr",
    "alo", "dp", "aga", "bnl", "aiv", "ij", "afn", "jr", "ka", "bw", "bmi",
    "aps", "wg", "aqt", "fu", "bai", "mt", "lc", "avj", "ayr", "xr", "mw",
    "tl", "ada", "ee", "hb", "ub", "vi", "atp", "bmd", "bbr", "abo",
    "qj", "bo", "ama", "mb", "zh",
  ])];

  const load = () => { try { return JSON.parse(localStorage.getItem(STORE_KEY)) || {}; } catch { return {}; } };
  const save = (d) => { try { localStorage.setItem(STORE_KEY, JSON.stringify(d)); } catch (e) { console.warn("[hero] localStorage full:", e.message); } };

  let results = load();
  let timer = null, shownShape = false;
  const sqlQuote = (s) => "'" + String(s).replace(/'/g, "''") + "'";
  const pending = () => QUEUE.filter((c) => !results[c]);

  async function pull(code) {
    const params = new URLSearchParams({
      service: code, interval: String(INTERVAL_HOURS), successCount: SUCCESS_COUNT,
    });
    // credentials:"include" is the point — it reuses the logged-in session.
    const res = await fetch(`/api/v1/stats/deliverability?${params}`, {
      credentials: "include", headers: { Accept: "application/json" },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return { payload: await res.json(), params: Object.fromEntries(params) };
  }

  async function step() {
    const todo = pending();
    if (!todo.length) {
      clearInterval(timer);
      console.log(`%c[hero] COMPLETE — ${Object.keys(results).length} services. Run: copy(HERO.sql())`,
                  "color:#279400;font-weight:bold;font-size:14px");
      return;
    }
    const code = todo[0];
    const done = QUEUE.length - todo.length;
    try {
      const r = await pull(code);
      results[code] = r;
      save(results);                       // persist after EVERY service
      if (!shownShape) {
        shownShape = true;
        console.log("%c[hero] FIRST PAYLOAD — send this one; the mapper cannot be written without it:",
                    "color:#279400;font-weight:bold");
        console.log(JSON.stringify(r.payload, null, 2));
      }
      console.log(`[hero] ${done + 1}/${QUEUE.length} ${code} ok`);
    } catch (e) {
      // Store NOTHING on failure. An empty row is indistinguishable from "this
      // service genuinely has no data", which is the distinction being
      // collected. It simply stays in the queue and is retried next pass.
      console.warn(`[hero] ${done + 1}/${QUEUE.length} ${code} FAILED (${e.message}) — stays queued`);
      if (String(e.message).includes("401")) {
        clearInterval(timer);
        console.error("%c[hero] session expired — log in again and re-paste. Progress is saved.",
                      "color:#c00;font-weight:bold");
      }
    }
  }

  window.HERO = {
    get results() { return results; },
    stop() { clearInterval(timer); console.log("[hero] stopped. Re-paste to resume."); },
    reset() { localStorage.removeItem(STORE_KEY); results = {}; console.log("[hero] progress cleared."); },
    status() {
      const have = Object.keys(results).length;
      const mins = Math.round((QUEUE.length - have) * INTERVAL_SECONDS / 60);
      console.log(`[hero] ${have}/${QUEUE.length} collected, ~${mins} min remaining at ${INTERVAL_SECONDS}s spacing`);
      return { collected: have, total: QUEUE.length, remaining: pending() };
    },
    /** Merge SQL for everything collected so far. Safe to run repeatedly. */
    sql() {
      return Object.entries(results).map(([code, r]) =>
        `select public.merge_vendor_deliverability(${sqlQuote(code)}, ` +
        `${sqlQuote(JSON.stringify(r.params))}::jsonb, ` +
        `${sqlQuote(JSON.stringify(r.payload))}::jsonb);`).join("\n");
    },
  };

  const have = Object.keys(results).length;
  console.log(`%c[hero] ${QUEUE.length} services, ${have} already collected, one per ${INTERVAL_SECONDS}s (~${Math.round((QUEUE.length - have) * INTERVAL_SECONDS / 60)} min).`,
              "color:#279400;font-weight:bold;font-size:14px");
  console.log("[hero] progress saves after each service — closing the tab is safe. HERO.status() / HERO.sql() / HERO.stop()");
  step();
  timer = setInterval(step, INTERVAL_SECONDS * 1000);
})();
