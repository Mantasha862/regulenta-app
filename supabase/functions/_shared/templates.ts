// REGULENTA reminder email templates. Pure functions (no I/O) so they can be unit-tested.
// Content rules: no attachments, no evidence links, no secrets; the record link needs a normal sign-in.

export interface ReminderData {
  delivery_id: string;
  email: string;
  recipient_name: string | null;
  company: string;
  compliance: string | null;        // form / short code, e.g. "MGT-7"
  compliance_title: string | null;  // descriptive title
  due_date: string;                 // YYYY-MM-DD
  current_status: string;           // obligation stage
  priority: string;                 // low | normal | high | critical
  trigger_type: string;
  assigned_to: string | null;
  required_action: string;
  legal_reference: string | null;   // only present when the rule is verified
  verification_status: string;      // approved_rule | unverified
  obligation_id: string;
  escalation_level: number;
}

export interface RenderOptions {
  appUrl: string;                   // e.g. https://app.example.com (no trailing slash needed)
  supportEmail?: string | null;     // shown only if configured
}

export interface RenderedEmail { subject: string; html: string; text: string }

const STAGE_LABEL: Record<string, string> = {
  initiated: 'Not started', preparing: 'In preparation', in_review: 'Awaiting review', approved: 'Approved, not yet filed',
  executed: 'Executed, filing pending', filed: 'Filed', evidence_pending: 'Filed, evidence pending', closed: 'Closed',
  cancelled: 'Cancelled', not_applicable: 'Not applicable',
};

export function subjectPrefix(trigger: string, priority: string): { tag: string; headline: string } {
  switch (trigger) {
    case 'upcoming':
      return priority === 'high' || priority === 'critical'
        ? { tag: '[URGENT]', headline: 'Compliance Deadline Approaching' }
        : { tag: '[REMINDER]', headline: 'Compliance Deadline Approaching' };
    case 'due_today': return { tag: '[DUE TODAY]', headline: 'Compliance Due Today' };
    case 'overdue':
    case 'overdue_followup':
    case 'overdue_repeat': return { tag: '[OVERDUE]', headline: 'Action Required' };
    case 'escalation': return { tag: '[ESCALATION]', headline: 'Overdue Compliance' };
    case 'evidence_missing': return { tag: '[ACTION]', headline: 'Supporting Evidence Missing' };
    case 'approval_pending': return { tag: '[APPROVAL]', headline: 'Review and Approval Pending' };
    case 'filing_confirmation_pending': return { tag: '[ACTION]', headline: 'Filing Confirmation Pending' };
    case 'not_started': return { tag: '[REMINDER]', headline: 'Compliance Not Started' };
    case 'reopened': return { tag: '[REOPENED]', headline: 'Compliance Item Reopened' };
    default: return { tag: '[NOTICE]', headline: 'Compliance Notice' };
  }
}

export function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// strip CR/LF so a company or rule name can never inject email headers via the subject
function oneLine(s: string): string { return s.replace(/[\r\n]+/g, ' ').trim(); }

export function formatDate(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  if (!y || !m || !d) return iso;
  return `${String(d).padStart(2, '0')} ${months[m - 1]} ${y}`;
}

export function recordUrl(appUrl: string, obligationId: string): string {
  if (!/^[0-9a-f-]{36}$/i.test(obligationId)) throw new Error('invalid obligation id');
  return `${appUrl.replace(/\/+$/, '')}/?obligation=${obligationId}`;
}

export function renderReminder(d: ReminderData, o: RenderOptions): RenderedEmail {
  const name = oneLine(d.compliance || d.compliance_title || 'Compliance item');
  const company = oneLine(d.company);
  const { tag, headline } = subjectPrefix(d.trigger_type, d.priority);
  const subject = `${tag} ${headline} — ${company} — ${name}`;
  const status = STAGE_LABEL[d.current_status] ?? d.current_status;
  const link = recordUrl(o.appUrl, d.obligation_id);
  const unverified = d.verification_status !== 'approved_rule';
  const greeting = d.recipient_name ? `Dear ${oneLine(d.recipient_name)},` : 'Hello,';

  const rows: [string, string][] = [
    ['Company', company],
    ['Compliance', d.compliance_title && d.compliance ? `${d.compliance} — ${d.compliance_title}` : name],
    ['Due date', formatDate(d.due_date)],
    ['Current status', status],
    ['Priority', d.priority.charAt(0).toUpperCase() + d.priority.slice(1)],
    ['Assigned to', d.assigned_to || 'Not assigned'],
  ];
  if (d.legal_reference && !unverified) rows.push(['Legal reference', d.legal_reference]);

  const verifyLine = unverified
    ? 'Note: the deadline or legal interpretation for this item is awaiting verification. Treat the date as provisional.'
    : null;
  const escalLine = d.escalation_level > 0
    ? `You are receiving this as an escalation contact (level ${d.escalation_level}) because the item is still outstanding.`
    : null;
  const disclaimer = 'This notification reflects the current status recorded in REGULENTA. Please review the applicable legal requirements and company records before taking action.';
  const support = o.supportEmail ? `Questions: ${o.supportEmail}` : null;

  const text = [
    greeting, '',
    d.trigger_type.startsWith('overdue') || d.trigger_type === 'escalation'
      ? 'The compliance obligation listed below is still marked as incomplete in REGULENTA.'
      : 'This is a reminder about the compliance obligation listed below.',
    '',
    ...rows.map(([k, v]) => `${k}: ${v}`),
    '',
    'Required action:', d.required_action, '',
    ...(escalLine ? [escalLine, ''] : []),
    ...(verifyLine ? [verifyLine, ''] : []),
    `Open the compliance record (sign-in required): ${link}`, '',
    disclaimer, '',
    ...(support ? [support, ''] : []),
    'Regards,', 'REGULENTA',
  ].join('\n');

  const accent = d.priority === 'critical' ? '#9b1c1c' : d.priority === 'high' ? '#a35200' : '#1d4e5f';
  const html = `<!doctype html><html><body style="margin:0;padding:0;background:#f4f2ee;font-family:Arial,Helvetica,sans-serif;color:#1f2328">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f2ee;padding:24px 0"><tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border:1px solid #e2ded6">
<tr><td style="padding:18px 24px;border-bottom:3px solid ${accent}">
<span style="font-size:18px;letter-spacing:2px;font-weight:bold;color:#1d4e5f">REGULENTA</span>
<span style="float:right;font-size:12px;font-weight:bold;color:${accent}">${escapeHtml(tag)}</span></td></tr>
<tr><td style="padding:24px">
<p style="margin:0 0 12px">${escapeHtml(greeting)}</p>
<p style="margin:0 0 16px">${escapeHtml(d.trigger_type.startsWith('overdue') || d.trigger_type === 'escalation'
    ? 'The compliance obligation listed below is still marked as incomplete in REGULENTA.'
    : 'This is a reminder about the compliance obligation listed below.')}</p>
<table role="presentation" cellpadding="6" cellspacing="0" style="border-collapse:collapse;width:100%;font-size:14px">
${rows.map(([k, v]) => `<tr><td style="color:#5b616b;width:140px;border-bottom:1px solid #eee">${escapeHtml(k)}</td><td style="border-bottom:1px solid #eee"><strong>${escapeHtml(v)}</strong></td></tr>`).join('\n')}
</table>
<p style="margin:18px 0 6px;font-weight:bold">Required action</p>
<p style="margin:0 0 16px">${escapeHtml(d.required_action)}</p>
${escalLine ? `<p style="margin:0 0 16px;color:${accent}">${escapeHtml(escalLine)}</p>` : ''}
${verifyLine ? `<p style="margin:0 0 16px;padding:10px;background:#fff6e5;border:1px solid #f0c36d">${escapeHtml(verifyLine)}</p>` : ''}
<p style="margin:0 0 20px"><a href="${escapeHtml(link)}" style="display:inline-block;background:${accent};color:#ffffff;text-decoration:none;padding:10px 18px;border-radius:4px">Open Compliance Record</a>
<br><span style="font-size:12px;color:#5b616b">Sign-in required.</span></p>
<p style="margin:0;font-size:12px;color:#5b616b">${escapeHtml(disclaimer)}</p>
${support ? `<p style="margin:8px 0 0;font-size:12px;color:#5b616b">${escapeHtml(support)}</p>` : ''}
</td></tr>
<tr><td style="padding:14px 24px;border-top:1px solid #e2ded6;font-size:12px;color:#5b616b">Regards,<br>REGULENTA</td></tr>
</table></td></tr></table></body></html>`;

  return { subject, html, text };
}

export function renderContactVerification(p: { name: string; company: string; link: string; supportEmail?: string | null }): RenderedEmail {
  const subject = `Confirm your email for compliance reminders — ${oneLine(p.company)}`;
  const text = [
    `Dear ${oneLine(p.name)},`, '',
    `An administrator has added you as a contact for ${oneLine(p.company)} in REGULENTA, to receive compliance reminder emails.`,
    'Please confirm this address by opening the link below (valid for 7 days):', p.link, '',
    'If you did not expect this, ignore this email and you will not receive reminders.', '',
    ...(p.supportEmail ? [`Questions: ${p.supportEmail}`, ''] : []),
    'Regards,', 'REGULENTA',
  ].join('\n');
  const html = `<!doctype html><html><body style="font-family:Arial,Helvetica,sans-serif;color:#1f2328">
<p>Dear ${escapeHtml(p.name)},</p>
<p>An administrator has added you as a contact for <strong>${escapeHtml(p.company)}</strong> in REGULENTA, to receive compliance reminder emails.</p>
<p><a href="${escapeHtml(p.link)}">Confirm this email address</a> (valid for 7 days).</p>
<p style="font-size:12px;color:#5b616b">If you did not expect this, ignore this email and you will not receive reminders.</p>
${p.supportEmail ? `<p style="font-size:12px;color:#5b616b">Questions: ${escapeHtml(p.supportEmail)}</p>` : ''}
<p>Regards,<br>REGULENTA</p></body></html>`;
  return { subject, html, text };
}
