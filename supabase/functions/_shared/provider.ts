// Email provider abstraction. Server-side only: the API key comes from the function's environment, never the browser.

export interface OutgoingEmail {
  to: string;
  subject: string;
  html: string;
  text: string;
  idempotencyKey: string;   // the delivery id: a retried send after an unseen success is not delivered twice
  tags?: Record<string, string>;
}

export interface SendResult {
  ok: boolean;
  messageId?: string;
  error?: string;
  permanent?: boolean;      // true = do not retry (bad address, rejected content)
}

export interface EmailProvider {
  readonly name: string;
  send(msg: OutgoingEmail): Promise<SendResult>;
}

type FetchFn = (input: string, init?: RequestInit) => Promise<Response>;

export class ResendProvider implements EmailProvider {
  readonly name = 'resend';
  private apiKey: string;
  private from: string;
  private fetchFn: FetchFn;
  private replyTo?: string;
  constructor(apiKey: string, from: string, fetchFn: FetchFn = fetch, replyTo?: string) {
    if (!apiKey) throw new Error('RESEND_API_KEY is not set');
    if (!from) throw new Error('EMAIL_FROM is not set');
    this.apiKey = apiKey; this.from = from; this.fetchFn = fetchFn; this.replyTo = replyTo;
  }

  async send(msg: OutgoingEmail): Promise<SendResult> {
    let res: Response;
    try {
      res = await this.fetchFn('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${this.apiKey}`,
          'Content-Type': 'application/json',
          'Idempotency-Key': msg.idempotencyKey,
        },
        body: JSON.stringify({
          from: this.from,
          to: [msg.to],
          subject: msg.subject,
          html: msg.html,
          text: msg.text,
          ...(this.replyTo ? { reply_to: this.replyTo } : {}),
          tags: Object.entries(msg.tags ?? {}).map(([name, value]) => ({ name, value: value.replace(/[^A-Za-z0-9_-]/g, '_') })),
        }),
      });
    } catch (e) {
      return { ok: false, error: `network error: ${(e as Error).message}`, permanent: false };
    }
    let body: Record<string, unknown> = {};
    try { body = await res.json(); } catch { /* non-JSON error body */ }
    if (res.ok && typeof body.id === 'string') return { ok: true, messageId: body.id };
    const detail = `${res.status} ${String(body.name ?? '')} ${String(body.message ?? '')}`.trim();
    // 400/422 = the message itself is invalid (bad address, bad content): retrying will not help.
    // 401/403 = configuration problem; 409 = idempotency conflict; 429/5xx = temporary. These are retried.
    const permanent = res.status === 400 || res.status === 422;
    return { ok: false, error: detail, permanent };
  }
}

// Used when no provider is configured: refuses to send so nothing is ever reported as sent.
export class NotConfiguredProvider implements EmailProvider {
  readonly name = 'not_configured';
  send(): Promise<SendResult> {
    return Promise.resolve({ ok: false, error: 'email provider not configured', permanent: false });
  }
}
