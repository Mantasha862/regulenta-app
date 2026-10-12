import { useState } from 'react'
import { supabase } from './supabase'
import { useLoad, must, fmtDateTime, humanError } from './lib.js'

const CATS = [['', 'All types'], ['compliance_reminder', 'Reminders'], ['overdue', 'Overdue'], ['escalation', 'Escalations'],
  ['evidence_missing', 'Missing evidence'], ['approval_pending', 'Pending approvals'], ['amendment', 'Regulatory updates'],
  ['due_date_change', 'Deadline changes'], ['new_compliance', 'New obligations'], ['system_alert', 'System alerts']]

export default function Notifications({ org, go }) {
  const [cat, setCat] = useState('')
  const [prio, setPrio] = useState('')
  const [unreadOnly, setUnreadOnly] = useState(false)
  const [company, setCompany] = useState('')
  const [msg, setMsg] = useState('')
  const list = useLoad(async () => must(await supabase.from('notifications')
    .select('id,category,title,body,priority,read_at,created_at,obligation_id,client_id,clients(name)')
    .eq('org_id', org.id).order('created_at', { ascending: false }).limit(300)), [org.id])
  const companies = [...new Map((list.data || []).filter(n => n.client_id).map(n => [n.client_id, n.clients?.name])).entries()]
  const shown = (list.data || []).filter(n => (!cat || n.category === cat) && (!prio || n.priority === prio)
    && (!unreadOnly || !n.read_at) && (!company || n.client_id === company))

  async function mark(ids) {
    const { error } = await supabase.rpc('mark_notifications_read', { p_ids: ids })
    if (error) setMsg(humanError(error.message)); else list.reload()
  }
  return (
    <section>
      <div className="row"><h2>Notifications</h2>
        <div className="row left"><button className="ghost" onClick={list.reload}>Refresh</button><button onClick={() => mark(null)}>Mark all as read</button></div></div>
      <div className="filters inline-filters">
        <select value={cat} onChange={e => setCat(e.target.value)}>{CATS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
        <select value={prio} onChange={e => setPrio(e.target.value)}><option value="">Any priority</option>{['critical', 'high', 'normal', 'low'].map(p => <option key={p}>{p}</option>)}</select>
        <select value={company} onChange={e => setCompany(e.target.value)}><option value="">All companies</option>{companies.map(([id, n]) => <option key={id} value={id}>{n}</option>)}</select>
        <label className="inline"><input type="checkbox" checked={unreadOnly} onChange={e => setUnreadOnly(e.target.checked)} /> Unread only</label>
      </div>
      {msg && <p className="err">{msg}</p>}
      {list.error && <p className="err">{list.error}</p>}
      <ul className="notes">
        {shown.map(n => (
          <li key={n.id} className={`${n.read_at ? 'read' : 'unread'} p-${n.priority || 'normal'}`}>
            <div className="row"><b>{n.title}</b><span className="muted small">{fmtDateTime(n.created_at)}</span></div>
            <div className="small">{n.body}</div>
            <div className="row left small">
              {n.priority && <span className={`chip p-${n.priority}`}>{n.priority}</span>}
              {n.obligation_id && <button className="link" onClick={() => { mark([n.id]); go('compliance', { obligation: n.obligation_id }) }}>Open record</button>}
              {!n.read_at && <button className="link" onClick={() => mark([n.id])}>Mark as read</button>}
            </div>
          </li>))}
        {list.data && !shown.length && <li className="muted">No notifications.</li>}
      </ul>
    </section>
  )
}
