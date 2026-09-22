/** What an e-mail address costs when the user is NOT covered by the free
 *  lifetime address or the Mail subscription (owner decision 2026-09-22).
 *
 *  ONE definition, read by two functions: `create-email-order` charges it
 *  (when the request carries `pay_credits: true`) and quotes it on every
 *  "not covered" refusal as `credit_price`; `email-domains` quotes it up front
 *  so the paywall can offer it before any refusal. The client renders the
 *  number it is sent and never a literal — change it here and both follow.
 *
 *  A paid address is charged by `begin_email_order`'s `p_credits > 0` branch,
 *  which skips every free/subscription/cap check, and it is refunded by
 *  `close_email_order_claim` / `expire_email_orders` when no code arrives.
 *  The subscriber caps count only `cost_credits = 0`, so a paid address never
 *  consumes the included allowance. */
export const EMAIL_PAID_CREDITS = 1;
