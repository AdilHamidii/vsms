// Typed wrapper around SMSPVA v2's single-endpoint API.
// All calls go to https://smspva.com/priemnik.php?metod=<X>&apikey=<KEY>&...
//
// The API uses "response" in some payloads and "responce" (sic) in others.
// We normalize via `okCode` helpers below.

const BASE = "https://smspva.com/priemnik.php";

function apiKey(): string {
  const k = Deno.env.get("SMSPVA_API_KEY");
  if (!k) throw new Error("SMSPVA_API_KEY env var not set");
  return k;
}

async function call<T>(metod: string, params: Record<string, string>): Promise<T> {
  const url = new URL(BASE);
  url.searchParams.set("metod", metod);
  url.searchParams.set("apikey", apiKey());
  for (const [k, v] of Object.entries(params)) {
    url.searchParams.set(k, v);
  }
  const resp = await fetch(url, { method: "GET" });
  const text = await resp.text();
  if (!resp.ok) {
    throw new Error(`SMSPVA ${metod} HTTP ${resp.status}: ${text}`);
  }
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new Error(`SMSPVA ${metod} non-JSON response: ${text}`);
  }
}

// ─────────── Endpoints we use ───────────

export interface GetNumberResponse {
  response: string;
  number?: string;
  id?: string | number;
}

export async function getNumber(
  country: string,
  service: string,
): Promise<GetNumberResponse> {
  return await call<GetNumberResponse>("get_number", { country, service });
}

export interface GetSmsResponse {
  response: string;
  number?: string | null;
  sms?: string | null;
  text?: string | null;
}

export async function getSms(
  country: string,
  service: string,
  id: string,
): Promise<GetSmsResponse> {
  return await call<GetSmsResponse>("get_sms", { country, service, id });
}

export interface DenialResponse {
  responce?: string;
  response?: string;
}

export async function denial(
  country: string,
  service: string,
  id: string,
): Promise<DenialResponse> {
  return await call<DenialResponse>("denial", { country, service, id });
}

export async function ban(service: string, id: string): Promise<DenialResponse> {
  return await call<DenialResponse>("ban", { service, id });
}

/** True if the response indicates success regardless of which field they used. */
export function isOk(r: { response?: string; responce?: string }): boolean {
  return r.response === "1" || r.responce === "1";
}
