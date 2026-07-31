# App Store / marketing screenshots

Captured 2026-07-31 on **iPhone 17 Pro Max, iOS 26.5** — **1320 × 2868**, which
is Apple's 6.9" App Store size, so these can be uploaded as-is or used as the
base layer for designed shots.

Status bar is pinned to 09:41 / full bars / charged via `simctl status_bar
override`, matching Apple's own marketing convention.

## ⚠️ Read this before uploading

**Do NOT ship the three eSIM shots** — `light-esim.png`, `light-plans.png`,
`light-activity.png` and their `dark-` variants. The eSIM line was **paused on
2026-07-31** (`app_config.esim_paused = true`, 0 of 1,081 plans active), so they
advertise a product that returns nothing when tapped. That is a live Guideline
2.3 exposure, not just a stale asset. Restore them if eSIM comes back.

**Screenshots 1 and 2 matter far more than the rest.** They are what appears in
search results, and the measured funnel says that is where the loss is: US
tap-through is **2.45%** while tap→install is **68.4%**. The product page already
converts; the result row does not.

| file | screen | why it sells |
|---|---|---|
| `light-email-home.png` | Home, e-mail mode | **New.** The Number/E-mail toggle, Discord + outlook.com, and "Free" stated twice — answers the free-inbox expectation that temp-mail searchers arrive with |
| `light-email-code.png` | E-mail code received | **New.** The payoff for the email line: the code, big, with the address underneath |
| `dark-email-home.png`, `dark-email-code.png` | as above | Dark variants |
| `light-home.png` | Home | The whole product in one view: pick service, pick country, price, big green CTA |
| `light-checkout.png` | Checkout | **Standard 3 cr vs Real SIM 4 cr** tier chips + "only pay if a code arrives" |
| `light-otp.png` | Code received | The payoff moment — the code, big |
| `light-waiting.png` | Waiting | Live timer + animation while the code lands |
| `light-orders.png` | History | Receipts, refunds, past codes |
| `light-esim.png` | eSIM store | The clustered world map — the most visually distinctive screen in the app |
| `light-plans.png` | eSIM plans | Duration chips + BEST VALUE badge |
| `light-activity.png` | eSIM usage | Data ring + history |
| `dark-*.png` | as above | Dark variants of the five strongest screens |

## What is real and what is staged

Everything the catalog controls is **live production data**: service names,
logos, country flags, dial codes and every price (TikTok/Czechia really is
3 credits standard and 4 on the o2 carrier).

Staged, because the simulator cannot sign in with Apple: the credit balance,
and three representative past orders. Phone numbers are Ofcom/ITU
reserved-for-fiction ranges, and each one matches its country's dial code.

For the two e-mail shots the domains and their prices are **real** — outlook.com
and hotmail.com genuinely cost nothing (3/day), gmail.com and icloud.com
genuinely cost 1 credit — and the stock figures are of the order actually
returned by the provider. Staged: the balance, the address itself and the code.
The service is **Discord** rather than the seed default WhatsApp, because
WhatsApp verifies by SMS and has no e-mail signup, so that pairing would have
depicted a flow that cannot exist.

**No delivery statistic is fabricated.** The badges say exactly what the
catalog says — which is why Home reads "Not tested" rather than a success
rate. That is honest, and it is also App Store policy: screenshots must not
misrepresent the app. If you want a delivery figure on a designed shot, take it
from a real measured route rather than inventing one.

## Regenerating

The harness that renders these (`VirtualSIM/__ShotRoot.swift` plus a branch in
`VirtualSIMApp`) is deliberately NOT committed — it bypasses `AuthGate`, and
that must never ship. Recreate it when needed; the recipe is in this session's
history.
