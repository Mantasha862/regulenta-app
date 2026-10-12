// Email worker: claim due deliveries, render, send, record the provider's answer.
// The database decides who receives what; this code only delivers what the database queued.
import { renderReminder, type ReminderData, type RenderOptions } from './templates.ts';
import type { EmailProvider } from './provider.ts';

export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>;

export interface BatchResult { claimed: number; accepted: number; retrying: number; failed: number; errors: string[] }

export async function processBatch(rpc: Rpc, provider: EmailProvider, opts: RenderOptions & { limit?: number }): Promise<BatchResult> {
  const out: BatchResult = { claimed: 0, accepted: 0, retrying: 0, failed: 0, errors: [] };
  const { data, error } = await rpc('claim_email_deliveries', { p_limit: opts.limit ?? 25 });
  if (error) throw new Error(`claim failed: ${error.message}`);
  const rows = (data ?? []) as ReminderData[];
  out.claimed = rows.length;

  for (const row of rows) {
    let result;
    try {
      const mail = renderReminder(row, opts);
      result = await provider.send({
        to: row.email, subject: mail.subject, html: mail.html, text: mail.text, idempotencyKey: row.delivery_id,
        tags: { kind: row.trigger_type, priority: row.priority },
      });
    } catch (e) {
      result = { ok: false, error: `render/send error: ${(e as Error).message}`, permanent: false };
    }
    const rec = await rpc('record_email_result', {
      p_delivery: row.delivery_id, p_ok: result.ok, p_provider: provider.name,
      p_message_id: result.messageId ?? null, p_error: result.error ?? null, p_permanent: result.permanent ?? false,
    });
    if (rec.error) { out.errors.push(`record ${row.delivery_id}: ${rec.error.message}`); continue; }
    const status = rec.data as string;
    if (status === 'accepted') out.accepted++;
    else if (status === 'failed') out.failed++;
    else out.retrying++;
  }
  return out;
}
