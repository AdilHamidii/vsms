// Behavioural checks for the subscription family split.
// Run: deno run --allow-read scripts/verify-subscription-families.ts
import {
  subscriptionFamily, isSubscriptionProduct, creditsForProduct,
  LINE_SUBSCRIPTION_PRODUCT_IDS, MAIL_SUBSCRIPTION_PRODUCT_IDS,
} from "../supabase/functions/_shared/iap.ts";

let failures = 0;
function check(name: string, ok: boolean) {
  console.log(`${ok ? "ok  " : "FAIL"}  ${name}`);
  if (!ok) failures++;
}

check("line monthly is family line",
  subscriptionFamily("com.anthersystems.VirtualSIM.line.monthly") === "line");
check("line yearly is family line",
  subscriptionFamily("com.anthersystems.VirtualSIM.line.yearly") === "line");
check("mail monthly is family mail",
  subscriptionFamily("com.anthersystems.VirtualSIM.mail.monthly") === "mail");
check("mail yearly is family mail",
  subscriptionFamily("com.anthersystems.VirtualSIM.mail.yearly") === "mail");
check("a credit pack has no family",
  subscriptionFamily("credits.12") === null);
check("an unknown id has no family",
  subscriptionFamily("com.anthersystems.VirtualSIM.nonsense") === null);

// The iap-verify contract: every subscription, both families, must be covered
// or a legitimate purchase 400s as unknown_product and pages the owner.
for (const id of [...LINE_SUBSCRIPTION_PRODUCT_IDS, ...MAIL_SUBSCRIPTION_PRODUCT_IDS]) {
  check(`isSubscriptionProduct covers ${id}`, isSubscriptionProduct(id));
}
check("isSubscriptionProduct rejects a credit pack",
  !isSubscriptionProduct("credits.12"));

// 🔴 The money invariant: a subscription in PRODUCT_TO_CREDITS pays credits on
// every renewal forever.
for (const id of [...LINE_SUBSCRIPTION_PRODUCT_IDS, ...MAIL_SUBSCRIPTION_PRODUCT_IDS]) {
  check(`${id} maps to NO credits`, creditsForProduct(id) === null);
}

// The two families must be disjoint — an id in both would make dispatch
// order-dependent.
const overlap = MAIL_SUBSCRIPTION_PRODUCT_IDS
  .filter((id) => LINE_SUBSCRIPTION_PRODUCT_IDS.includes(id));
check("families are disjoint", overlap.length === 0);

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILED`);
if (failures > 0) Deno.exit(1);
