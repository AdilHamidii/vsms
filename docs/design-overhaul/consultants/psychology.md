# Behavioural psychology consultant — report 1 (2026-09-24)

Standing consultant for the `design-overhaul` branch. To re-create it in a new
session: brief a subagent as a behavioural psychologist / behavioural-economics
consultant, give it this file plus the product facts in CLAUDE.md, and ask for
evidence-cited advice with a risk tag per tactic.

Risk tags: **[App / Legal / Backlash]**, each L/M/H. App = App Store rejection
(2.3, 3.1.1, 3.1.2, 4.5.4, 5.1.1(v), 5.6). Legal = EU (UCPD, CRD, DSA), US (FTC §5,
ROSCA, California ARL), France. Backlash = ratings/refund risk for this app.

## Framing facts
- Expect small effects: academic nudges average +8.7pp, at-scale nudge units
  +1.4pp (DellaVigna & Linos 2022, https://www.nber.org/papers/w27594); after
  publication-bias correction no reliable average effect (Maier et al. 2022 PNAS,
  https://www.pnas.org/doi/10.1073/pnas.2200300119). Prefer structural fixes;
  pre-register read-outs; most A/B tests here are underpowered.
- Legal (not legal advice): DSA Art. 25 yields to UCPD for non-platforms; vSMS is
  UCPD-governed. Apple carries much of the cancellation burden, but in-app claims
  are vSMS's own practice. EU withdrawal button (Dir. 2023/2673, from 19 Jun 2026)
  and France L215-1-1 three-click cancellation. FTC click-to-cancel vacated Jul
  2025 but ROSCA applies. California AB 2863 (from 1 Jul 2025): separate consent to
  renewal, click-to-cancel, promo-price notice. EU Digital Fairness Act due Q4 2026.

## Moment by moment
1. **First screen after sign-up (69% leak).** Move sign-in to the first moment it
   is needed (claim free e-mail or pay); let users pick an app, see ways in and
   prices first (Apple 5.1.1(v)) [L/L/L]; re-baseline activation as orders per
   install. One question, logo grid + search, never pre-selected [L/L/L]. Risk
   reversal on screen one: "If no code arrives, your credits come back
   automatically" [L/L/L]. Make the 10-second explainer just-in-time (after app +
   country, before paying) and behavioural ("request the code right after
   pasting", "wait at least 2 minutes", "if it fails, switch country") [L/L/M].
   Avoid multi-product carousels, credit amounts, success rates on screen one.
2. **Three ways in.** Overload comes from non-comparable options, not count
   (Chernev 2015). Align options on the same rows: Accepted by {app}? / What you
   pay / If no code arrives / Can get a code again later? [L/L/L]. Recommend one
   per service WITH the reason, based on fit + past data, never margin [L/L/L]
   (recommending the subscription without data: [M/M/H]). Unsuitable options
   visible but disabled with the reason [L/L/L]. Truthful anchoring ok [L/L/L].
   No decoys [L/M/M]. Show price early ("from $X"); hidden/drip price [L/M/H].
   Zero-price effect: keep Free e-mail off phone-only services.
3. **Credits vs money.** Keep credits, show money at every decision ("24 credits,
   about $10 at your pack price") [L/L/L]. Say "credits back", never "refund" /
   "money back" (UCPD Art. 6, FTC §5) [wrong wording L/M/H]. Fix mixed locale
   formatting ("0,60 US$ / cr" on a US storefront).
4. **Credit paywall at first order.** Keep smallest-covering pack preselected,
   labelled with leftover ("20: covers it, 1 credit left") [L/L/L]. Do NOT
   preselect larger packs: refunds already fund same-route retries, so "enough for
   retries" is false [M/M-H/H]. Verify "MOST POPULAR" against sales or remove
   [unsubstantiated M/M/M]. Risk reversal as headline [L/L/L]. Keep ascending
   order. Optional: a REAL first-purchase bonus granted on purchase, tombstoned
   against Delete Account; any time limit must be real [L/L-M/L].
5. **The wait.** Time scale on the ring across the 8-minute window + past-tense
   typical arrival ("codes here have usually arrived around 1 minute; some took
   3–5") [L/L/L]. Checklist that decides success ("Pasted the number? Tapped Send
   code?") [L/L/L]. Real operational transparency ("number active · checked 3s
   ago") only if it reflects real polling [L/L/L]. Reroll/cancel behind the 90s
   server hold with the reason; confirm on early cancel [L/L/L-M]. "We'll notify
   you, feel free to leave." Avoid % progress bars, "almost there", odds.
6. **Failure.** Settle the loss first ("Your 24 credits are back") [L/L/L].
   Specific, external, changeable cause; never blame the user [L/L/L]. One default
   next action that changes a variable (another country / High band), plus the
   past-tense survivor line [L/L/M]. Switch product only on evidence (e-mail if the
   service takes e-mail; own number only where measured) [unmeasured M/M/H].
7. **Success.** Clean code moment, one-tap copy, Done, no confetti [L/L/L].
   Cross-sell after copy/Done with the true loss-framed reason ("one-time numbers
   can't receive a code later; if {app} asks again, a number you keep can"), quiet,
   no price, dismissible [L/L/M]. Rating only via Apple's API after success; no
   sentiment pre-question (review gating: excluded).
8. **Subscription paywall (72 → 19 → 3).** Read `line_checkout_exit` first.
   Monthly only up front, yearly behind "Other plans" [L/L/L]. Job-first headline
   + one renewal sentence next to the price [L/L/L]. Honest rental framing: "Only
   need it for a month? Turn off renewal right after buying; the number stays
   yours until {date}" [L/L/L] (never "rental" without the renewal clause). Order
   disclosures: benefits, then one "Before you buy" block, uncollapsed for US/PR
   [removing US warning L/M/H]. In-app Manage/cancel link [L/L/L]. Reservation
   hold countdown ONLY if the server truly enforces it [L/L/M]. Don't call the
   intro "limited time" (it isn't).
9. **Returning users.** Activity as memory with one-tap "Get another for {app} ·
   {country}" (user's own past choice) [L/L/L]. Transactional pushes fine;
   marketing pushes need in-app opt-in (4.5.4) + frequency cap [L/L-M/M].

## Top 10 by leverage
1. Sign-in at first claim/payment, not before browsing. 2. Redesigned wait
(time scale, past-tense arrival, checklist, 90s reroll, notify-and-leave).
3. Failure screen (credits back first, not-your-fault cause, one variable-changing
next action). 4. Per-service recommendation with reason on aligned rows; disabled
unsuitable options; price early. 5. Subscription paywall (monthly first, one
renewal sentence, "turn off renewal, keep until {date}", ordered disclosures).
6. Risk reversal as headline everywhere ("credits back"). 7. Money beside credits
at every decision; smallest-covering default with leftover; verify "Most
popular". 8. Clean success then truthful cross-sell; API rating, no gating.
9. One-tap "Again" in Activity + opted-in capped pushes. 10. Real tombstoned
first-purchase bonus and/or real reservation hold.

## Advised against even though truthful
Preselecting larger/best-value pack [M/M-H/H]; descending pack order at first
purchase [L/L/M]; recommending the subscription for failed temp orders without
per-service data [M/M/H].

## Excluded as deceptive
Fake/resetting countdowns; invented scarcity; fake live counts or unsubstantiated
"Most popular"; fake/incentivised/gated reviews; hidden renewal terms or "rental"
without renewal clause; forecasting success; "money-back guarantee" for credits;
confirmshaming; cancel friction / retention walls; drip pricing; fake progress
steps during the wait.

## Red lines for vSMS
1. Never imply a code will arrive. 2. "Credits back", never "refund"/"money back"
unless Apple refunds cash. 3. No way-in recommendation without measured evidence.
4. Money shown at decision time; nothing revealed after commitment. 5. Renewal
terms beside the intro price; cancel one tap away. 6. No marketing push without
opt-in. 7. Bonuses granted after purchase, real limits, tombstoned. 8. No supplier
named. 9. Nothing pre-selected on first run; a recommendation is a label with a
reason. 10. No review gating.

## Evidence warnings
Ego depletion failed replication (Hagger 2016); money priming contested; decoy and
social-norm effects fragile in natural settings; nudge effects shrink at scale;
Baymard 18–26% is e-commerce survey data. The "friction signals importance" belief
behind the 10-second gate has no direct evidence either way; measure via
shown-minus-acknowledged. Unverified: Apple 5.6.1 exact wording on custom review
prompts; whether AB 2863's promo notice applies when Apple bills.

## Spec review 1 (2026-09-24) — applied to the spec
1. "Best pick" → "Recommended for"; own number not recommended on n=1 — bar ≥3
   codes on ≥2 lines/90d (WhatsApp 16/7 qualifies; TikTok, DoorDash 1/1 do not).
2. §6.7 cross-sell claims a capability only for measured-line services; generic
   copy otherwise; "once this order closes" (true through the resend window).
3. §6.8 cause line: "No code reached this number. That's common with one-time
   numbers." (never "the service didn't send", never "not something you did");
   9-in-10 line only on 1st/2nd consecutive failure.
4. §6.10 CTA "Subscribe" + intro/renewal line under it; "stays yours for the
   month you paid for" (no pre-purchase date).
5. "Our pick" on the 30 acceptable as opinion if: shown only at shortfall ≥13,
   text tag only, reason only if runtime-true; "Best value" computed live.
6. Money beside credits for guests too (StoreKit works without a session).
7. Waiting: notify line only when authorized; reroll countdown framing; "Closing
   keeps your order running".
8. Low-row note past tense. 9. Risk reversal on Verify subtitle.

## Verify review 1 (2026-09-24, Plan 1 first cut)

Reviewed: `t6-homeRouter.png`, `t6-homeLine.png`, `VerifyScreen.swift`, spec §6.1/§7.
The headline, the subtitle risk reversal ("Your credits come back", never "money
back"), the search count from the catalog and the user-owned tile pick all clear
the red lines. Three changes, most important first:

1. **§6.1 / §6.4: the first tile tap hits the 10-second wall.** `pick()` calls
   `openCodeStore()`, which pushes `TempScreen`, and its `.task` raises the gated
   `DeliveryInfoSheet` 550 ms later for every user without
   `deliveryInfoAcked`. So a new user's first action on the new first screen is
   answered by a non-dismissible 10-second read, before they have picked a
   country or seen a price. That is the activation moment the whole overhaul is
   for. Move the trigger to the "Get number" tap (spec §6.4 already puts it at
   checkout) now, in Plan 1, not in Plan 2. The gate itself stays as the owner
   designed it. As built: [App L / Legal L / Backlash M]. Moved: [L/L/L].
2. **§6.1 subscriber strip: it reads as "use this number to verify".** A
   "Your number · Copy" card directly under "What do you want to verify?"
   implies the rented line works for any of the tiles below it. That is red
   line 3: the line is VoIP, WhatsApp is on Meta's VoIP-strict list, and codes
   are proven only for WhatsApp, TikTok and DoorDash. Move the strip below the
   grid and chips, label it "Your own number" (spec §4 vocabulary; the current
   "Your number" breaks it), and format the digits ("+1 212 555 0128") so they
   read as a number, not an ID. Don't add any "use it here" wording until the
   Ways screen can scope it to the proven set. As built: [L/L/M]. Changed: [L/L/L].
3. **§6.1 credits pill: hide it at a zero balance with no purchase history.**
   A "0" coin pill in the top corner of a new user's first screen puts the
   empty wallet in view before any need exists. That adds pain of paying at
   the wrong moment; the one that converts is balance < price at checkout. Show
   the pill once the balance is above 0 or the user has bought before. The
   fixture's "42" hides this, so capture a real zero-balance frame. [L/L/L].

Nothing here contradicts the red lines except item 2, which is a moderate
capability implication, not a false statement.
