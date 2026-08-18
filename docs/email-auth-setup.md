# Turning email auth on — the manual half

Everything in the app and the database is built and deployed. What remains is
account setup that only the owner can do. Domain: **vsmsapp.com** (bought
2026-08-18).

Nothing here is optional. Until step 4 passes, `POST /auth/v1/signup` succeeds
and the code never arrives, which is indistinguishable from a broken app.

---

## 1. Resend — add the domain

Resend → Domains → **Add domain** → `mail.vsmsapp.com`.

Pick the **EU (Ireland, `eu-west-1`)** region when it asks. The owner and most
buyers are in Europe, and it keeps the mail path inside the EU — which is the
easier answer for GDPR than explaining a US hop. The region is baked into the
MX value it then gives you, so it cannot be changed by editing DNS later.

⚠️ **A SUBDOMAIN, NOT THE APEX.** Sending reputation is tracked per domain. If
a bounce storm or a spam-trap hit damages `mail.vsmsapp.com`, the apex — where
the Terms and Privacy pages the App Store listing points at will live — is
untouched. Using the apex to send couples the two together permanently.

## 2. DNS — at IONOS

The domain is on IONOS nameservers (`ns10xx.ui-dns.*`), so records go in the
IONOS control panel:

> **Menu → Domains & SSL → the gear icon under _Actions_ for `vsmsapp.com` →
> DNS → Add record**

🔴 **THE HOST NAME FIELD TAKES THE PREFIX ONLY, NEVER THE FULL DOMAIN.** IONOS
appends `.vsmsapp.com` itself and shows it beside the box. Paste
`send.mail.vsmsapp.com` in there and you create
`send.mail.vsmsapp.com.vsmsapp.com`, which resolves to nothing and fails
verification with no clue why. `@` means the apex.

Helpfully, **Resend states its record names relative to the root domain**
already (`send.mail`, not `send.mail.vsmsapp.com`), which is precisely the form
IONOS's Host name field wants. Copy them across verbatim.

The live values for this account, read from the Resend API on 2026-08-18
(domain `2ba3c474-0163-43ed-9f62-dd356e0220c1`, region `eu-west-1`). All three
are public DNS records — nothing here is a secret:

| IONOS type | IONOS **Host name** | value |
|---|---|---|
| `TXT` | `resend._domainkey.mail` | `p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC9QuLXZ48Ixz1khXPi8FzyGQBslLBeXbqzSgIY/Vl9ATvP85ozmDQot2qfLQKvHfbKLQtw9sjNlu32CdQsQldE29qkttmvEtZuNC+Bxa7pLwg0zJjYUkjEMlONsJIuxYFwXatDltEkiw7LYj3DzYV0y2Jufp1yxGIRQyJ607vMTwIDAQAB` |
| `MX` | `send.mail` | `feedback-smtp.eu-west-1.amazonses.com`, priority `10` |
| `TXT` | `send.mail` | `v=spf1 include:amazonses.com ~all` |
| `TXT` | `_dmarc` | `v=DMARC1; p=none;` |

Notes that cost time if missed:

- **Re-read them from the API if the domain is ever recreated** — the DKIM key
  is generated per domain and the bounce host is region-specific:
  `curl -H "Authorization: Bearer $RESEND_KEY" https://api.resend.com/domains/<id>`
- The **MX record needs a Priority**; `10` is fine, it is the only one.
- **Paste the DKIM value as ONE line**, no spaces or breaks. It is ~220
  characters, comfortably inside the 255-char limit for a single TXT string, so
  it does not need splitting.
- **Do not wrap TXT values in quotes.** IONOS adds them.
- ⚠️ **The DMARC record carries NO `rua=` reporting address, deliberately.**
  There is no mailbox on this domain to receive reports, and pointing `rua` at
  an address on a *different* domain (a Gmail, say) silently does nothing
  unless that domain publishes an authorisation record
  (`vsmsapp.com._report._dmarc.<that domain>`). A bare `p=none;` is valid, is
  what Gmail and Yahoo look for, and promises nothing we have not set up.
  Tighten to `p=quarantine` only once you are actually reading reports.

Wait for Resend to show **Verified** (usually minutes, occasionally an hour).
Do not continue before it does: Supabase accepts the SMTP settings regardless
and every message silently bounces.

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
