// APNs HTTP/2 push notification sender for Deno.
// Uses token-based auth (.p8 key) — JWT signed with ES256.

import { SignJWT, importPKCS8 } from "https://esm.sh/jose@5.9.4";

interface ApnsConfig {
  keyId: string;
  teamId: string;
  keyP8: string;       // contents of .p8 file
  bundleId: string;
  environment: "sandbox" | "production";
}

function loadConfig(): ApnsConfig {
  const need = (k: string) => {
    const v = Deno.env.get(k);
    if (!v) throw new Error(`Missing env var ${k}`);
    return v;
  };
  return {
    keyId:       need("APNS_KEY_ID"),
    teamId:      need("APNS_TEAM_ID"),
    keyP8:       need("APNS_KEY_P8"),
    bundleId:    need("APNS_BUNDLE_ID"),
    environment: (Deno.env.get("APNS_ENV") ?? "sandbox") as "sandbox" | "production",
  };
}

// Cached JWT, signed every ~50 minutes per Apple's recommendation (max 60).
let cachedJwt: { token: string; expires: number } | null = null;

async function providerToken(config: ApnsConfig): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && cachedJwt.expires - 60 > now) return cachedJwt.token;

  const key = await importPKCS8(config.keyP8, "ES256");
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: config.keyId })
    .setIssuer(config.teamId)
    .setIssuedAt(now)
    .sign(key);

  cachedJwt = { token, expires: now + 50 * 60 };
  return token;
}

export interface PushPayload {
  alertTitle: string;
  alertBody: string;
  sound?: string;
  badge?: number;
  customData?: Record<string, unknown>;
}

export async function sendPush(
  deviceToken: string,
  payload: PushPayload,
  envOverride?: "sandbox" | "production",
): Promise<{ ok: boolean; status: number; body?: string }> {
  const config = loadConfig();
  const env = envOverride ?? config.environment;
  const host = env === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";

  const jwt = await providerToken(config);
  const body = {
    aps: {
      alert: { title: payload.alertTitle, body: payload.alertBody },
      sound: payload.sound ?? "default",
      ...(payload.badge !== undefined ? { badge: payload.badge } : {}),
    },
    ...(payload.customData ?? {}),
  };

  const resp = await fetch(`${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": config.bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  return {
    ok: resp.ok,
    status: resp.status,
    body: resp.ok ? undefined : await resp.text(),
  };
}
