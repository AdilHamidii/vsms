# Turning email auth on — the manual half

Everything in the app and the database is built and deployed. What remains is
account setup that only the owner can do. Domain: **vsmsapp.com** (bought
2026-08-18).

Nothing here is optional. Until step 4 passes, `POST /auth/v1/signup` succeeds
and the code never arrives, which is indistinguishable from a broken app.

---

## 1. Resend — add the domain

Resend → Domains → **Add domain** → `mail.vsmsapp.com`.

⚠️ **A SUBDOMAIN, NOT THE APEX.** Sending reputation is tracked per domain. If
a bounce storm or a spam-trap hit damages `mail.vsmsapp.com`, the apex — where
the Terms and Privacy pages the App Store listing points at will live — is
untouched. Using the apex to send couples the two together permanently.

## 2. DNS — at the registrar

Resend generates three records. Two of them (SPF, DKIM) carry values only it
can produce, so copy them verbatim from its screen:

| type | host | value |
|---|---|---|
| `MX` | `send.mail.vsmsapp.com` | (from Resend — its bounce host) |
| `TXT` | `send.mail.vsmsapp.com` | `v=spf1 include:amazonses.com ~all` |
| `TXT` | `resend._domainkey.mail.vsmsapp.com` | (from Resend — the DKIM public key) |

Add one more that Resend does **not** generate, because it is policy rather
than plumbing:

| type | host | value |
|---|---|---|
| `TXT` | `_dmarc.vsmsapp.com` | `v=DMARC1; p=none; rua=mailto:dmarc@vsmsapp.com` |

`p=none` monitors without rejecting anything — the right setting on day one.
Tighten to `p=quarantine` only after the reports show your own mail passing.

Wait for Resend to show **Verified**. It usually takes minutes; DNS can take an
hour. Do not continue before it does — Supabase will accept the SMTP settings
regardless and every message will bounce.

## 3. Supabase — SMTP

Dashboard → Authentication → Emails → SMTP Settings → Enable Custom SMTP:

```
host      smtp.resend.com
port      465                     (implicit TLS; 587 works too)
username  resend
password  <Resend API key, "Sending access" only>
sender    no-reply@mail.vsmsapp.com
name      vSMS
```

Then Authentication → **Rate Limits** → raise "Emails per hour" off the
built-in default of a couple per hour. This is the likeliest cause of a "the
code never arrived" report on launch day, and it fails silently as
`over_email_send_rate_limit` — which the client does render honestly, but only
after the user has already waited.

## 4. Supabase — templates

Authentication → Emails → Templates. Replace **Confirm signup** and **Reset
password** with the contents of `supabase/templates/confirmation.html` and
`supabase/templates/recovery.html`.

🔴 **Both must contain `{{ .Token }}` and NO link.** The client verifies a
6-digit code through `POST /auth/v1/verify`; nothing in the app handles the
`relay://auth` scheme, so a `{{ .ConfirmationURL }}` leads somewhere the app
cannot catch. Mail scanners also pre-fetch links and consume the single-use
token before the recipient sees it.

## 5. Check the provider settings themselves

Authentication → Providers → Email:

- Enable Email provider: **on**
- Confirm email: **on** — load-bearing for money. `handle_new_user` no longer
  pays the signup grant for an unconfirmed address, so turning this off hands a
  grant to any address typed into the box.
- Minimum password length: **8**, matching what the sign-up screen asks for.
  Probed 2026-08-18: the live value was **6**.

## 6. Verify, from the outside

```bash
# Should report email: true, mailer_autoconfirm: false
curl -s "https://enugzltysdmjzavisloy.supabase.co/auth/v1/settings" \
     -H "apikey: <publishable key>" | python3 -m json.tool
```

Then, on a real address you control, walk the whole thing: sign up → receive
the code → confirm → the app opens signed in. Then in SQL:

```sql
-- exactly one grant, and only after confirmation
select u.email_confirmed_at is not null as confirmed,
       w.balance,
       (select count(*) from public.wallet_transactions t
         where t.user_id = u.id and t.reason = 'signup_bonus') as grants
  from auth.users u join public.wallets w on w.user_id = u.id
 where u.email = '<the address>';
```

`scripts/verify-signup-grant.sql` runs the full set of assertions inside a
transaction that rolls back, including the plus-tag farming case.

## 7. Afterwards

- Move Terms / Privacy / Refund / Help off `superficial-watch-d12.notion.site`
  onto `vsmsapp.com` and update `VirtualSIM/LegalLinks.swift` — including
  `supportEmail`, currently a personal Gmail address. Update the App Store
  listing's support and marketing URLs in the same pass.
- ⚠️ **Raising the signup grant is a separate decision, and it is 0 today.**
  With email signup live, the cost of a fresh identity is one mailbox rather
  than one Apple ID. Normalization and confirmation raise that floor; they do
  not make it infinite. See `20260818130000_email_signup_normalized_tombstone.sql`.
