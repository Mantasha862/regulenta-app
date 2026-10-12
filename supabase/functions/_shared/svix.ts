// Verifies Resend webhook signatures (Resend signs webhooks with Svix).
// signed content = `${svix-id}.${svix-timestamp}.${raw body}`, HMAC-SHA256 with the base64 secret after "whsec_".

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function bytesToB64(bytes: ArrayBuffer): string {
  let s = '';
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s);
}
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

export async function verifySvix(secret: string, headers: { id: string | null; timestamp: string | null; signature: string | null },
                                 body: string, nowSeconds = Math.floor(Date.now() / 1000), toleranceSeconds = 300): Promise<boolean> {
  if (!secret || !headers.id || !headers.timestamp || !headers.signature) return false;
  const ts = Number(headers.timestamp);
  if (!Number.isFinite(ts) || Math.abs(nowSeconds - ts) > toleranceSeconds) return false;
  const key = await crypto.subtle.importKey('raw', b64ToBytes(secret.replace(/^whsec_/, '')), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${headers.id}.${headers.timestamp}.${body}`));
  const expected = bytesToB64(mac);
  return headers.signature.split(' ').some(part => {
    const [ver, sig] = part.split(',');
    return ver === 'v1' && !!sig && safeEqual(sig, expected);
  });
}

// maps Resend webhook event types to REGULENTA delivery events
export function mapResendEvent(type: string): 'delivered' | 'bounced' | 'complained' | null {
  switch (type) {
    case 'email.delivered': return 'delivered';
    case 'email.bounced': return 'bounced';
    case 'email.complained': return 'complained';
    default: return null;
  }
}
