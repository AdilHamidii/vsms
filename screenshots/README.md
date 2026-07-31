# App Store / marketing screenshots

Captured 2026-07-31 on **iPhone 17 Pro Max, iOS 26.5** — **1320 × 2868**, which
is Apple's 6.9" App Store size, so these can be uploaded as-is or used as the
base layer for designed shots.

Status bar is pinned to 09:41 / full bars / charged via `simctl status_bar
override`, matching Apple's own marketing convention.

| file | screen | why it sells |
|---|---|---|
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
