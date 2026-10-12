import { supabase } from './supabase'
import { useLoad, must, daysUntil, OPEN, fmtDate, fmtDateTime, today, addDays } from './lib.js'

// Every figure is counted from records this user is allowed to read. Nothing is hard-coded.
export default function Dashboard({ org, isAdmin, go }) {
  const { data, error, loading, reload } = useLoad(async () => {
    const obs = must(await supabase.from('obligations')
      .select('id,due_date,stage,lifecycle,requires_evidence,period_label,clients(name),rule_versions(rules(form,title))')
      .eq('org_id', org.id).order('due_date'))
    const docs = new Set(must(await supabase.from('documents').select('obligation_id').eq('org_id', org.id).not('obligation_id', 'is', null)).map(d => d.obligation_id))
    const since = addDays(today(), -7)
    const events = must(await supabase.from('notification_events').select('id,priority,obligation_id,created_at')
      .eq('org_id', org.id).in('priority', ['high', 'critical']).gte('event_date', since))
    const reg = must(await supabase.from('notifications').select('id,title,body,created_at,category')
      .eq('org_id', org.id).in('category', ['amendment', 'due_date_change', 'regulatory_update']).order('created_at', { ascending: false }).limit(5))
    const unread = (await supabase.from('notifications').select('id', { count: 'exact', head: true }).eq('org_id', org.id).is('read_at', null)).count || 0
    const failures = isAdmin ? ((await supabase.from('notification_deliveries').select('id', { count: 'exact', head: true })
      .eq('org_id', org.id).in('status', ['failed', 'bounced'])).count || 0) : null
    return { obs, docs, events, reg, unread, failures }
  }, [org.id, isAdmin])

  if (loading && !data) return <p className="muted">Loading…</p>
  if (error) return <p className="err">{error}</p>
  const active = data.obs.filter(o => o.lifecycle === 'active')
  const open = active.filter(o => OPEN(o.stage))
  const notFiled = o => ['initiated', 'preparing', 'in_review', 'approved', 'executed'].includes(o.stage)
  const due30 = open.filter(o => notFiled(o) && daysUntil(o.due_date) >= 0 && daysUntil(o.due_date) <= 30)
  const dueToday = open.filter(o => notFiled(o) && daysUntil(o.due_date) === 0)
  const overdue = open.filter(o => notFiled(o) && daysUntil(o.due_date) < 0)
  const approvals = open.filter(o => o.stage === 'in_review')
  const missingEv = open.filter(o => ['filed', 'evidence_pending'].includes(o.stage) && o.requires_evidence && !data.docs.has(o.id))
  const critIds = new Set(data.events.map(e => e.obligation_id))
  const critical = open.filter(o => critIds.has(o.id))
  const proposed = data.obs.filter(o => o.lifecycle === 'proposed')

  const cards = [
    ['Due in next 30 days', due30.length, () => go('compliance', { preset: 'due30' })],
    ['Due today', dueToday.length, () => go('compliance', { preset: 'today' }), dueToday.length ? 'hot' : ''],
    ['Overdue', overdue.length, () => go('compliance', { preset: 'overdue' }), overdue.length ? 'bad' : ''],
    ['High / critical alerts (7 days)', critical.length, () => go('compliance', { preset: 'critical', ids: [...critIds] })],
    ['Pending approvals', approvals.length, () => go('compliance', { preset: 'approvals' })],
    ['Missing evidence', missingEv.length, () => go('compliance', { preset: 'evidence' })],
    ['Unread notifications', data.unread, () => go('notifications')],
    ...(isAdmin ? [['Email delivery failures', data.failures, () => go('settings'), data.failures ? 'bad' : '']] : []),
    ...(proposed.length ? [['Proposed deadlines awaiting activation', proposed.length, () => go('companies'), 'hot']] : []),
  ]

  return (
    <section>
      <div className="row"><h2>Compliance overview</h2><button className="ghost" onClick={reload}>Refresh</button></div>
      {!data.obs.length && (
        <div className="warn">No deadlines yet. Add a company, complete its profile, then generate deadlines from rules that reviewers have verified and approved.
          Only approved rules with primary-source evidence produce deadlines.</div>
      )}
      <div className="tiles">
        {cards.map(([label, n, onClick, tone]) => (
          <button key={label} className={`tile ${tone || ''}`} onClick={onClick}>
            <span className="n">{n}</span><span>{label}</span>
          </button>
        ))}
      </div>
      <div className="two">
        <div>
          <h3>Next due</h3>
          <ul className="simple">
            {[...overdue, ...due30].slice(0, 8).map(o => (
              <li key={o.id} onClick={() => go('compliance', { obligation: o.id })}>
                <b>{o.rule_versions?.rules?.form}</b> {o.clients?.name}
                <span className={daysUntil(o.due_date) < 0 ? 'err' : 'muted'}> · {fmtDate(o.due_date)}{daysUntil(o.due_date) < 0 ? ` (${-daysUntil(o.due_date)} days overdue)` : ''}</span>
              </li>
            ))}
            {!overdue.length && !due30.length && <li className="muted">Nothing due in the next 30 days.</li>}
          </ul>
        </div>
        <div>
          <h3>Recent regulatory alerts</h3>
          <p className="muted small">Only changes that a reviewer has verified and approved appear here.</p>
          <ul className="simple">
            {data.reg.map(n => <li key={n.id}><b>{n.title}</b><div className="muted small">{n.body} · {fmtDateTime(n.created_at)}</div></li>)}
            {!data.reg.length && <li className="muted">No approved regulatory changes affecting your companies yet.</li>}
          </ul>
        </div>
      </div>
    </section>
  )
}
