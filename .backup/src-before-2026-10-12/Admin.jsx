import { useEffect, useMemo, useState } from 'react'
import { supabase } from './supabase'

const STATUSES = ['all', 'pending_review', 'conflict', 'needs_more_research', 'approved', 'rejected']
const canApprove = roles => roles.some(r => ['super_admin', 'admin', 'reviewer'].includes(r))

export default function Admin({ roles }) {
  const [rows, setRows] = useState([])
  const [filter, setFilter] = useState('all')
  const [q, setQ] = useState('')
  const [sel, setSel] = useState(null)
  const [err, setErr] = useState('')

  async function load() {
    const { data, error } = await supabase.from('research_queue').select('*').order('created_at', { ascending: true }).limit(500)
    if (error) setErr(error.message); else { setErr(''); setRows(data) }
  }
  useEffect(() => { load() }, [])

  const counts = useMemo(() => rows.reduce((a, r) => (a[r.status] = (a[r.status] || 0) + 1, a), {}), [rows])
  const shown = rows.filter(r => (filter === 'all' || r.status === filter) &&
    (!q || JSON.stringify(r.proposed).toLowerCase().includes(q.toLowerCase())))
  const current = rows.find(r => r.id === sel)

  return (
    <div className="admin">
      <aside className="list">
        <div className="stats">
          {STATUSES.slice(1).map(s => <span key={s} className={`chip ${s}`}>{s.replace(/_/g, ' ')}: {counts[s] || 0}</span>)}
        </div>
        <div className="filters">
          <select value={filter} onChange={e => setFilter(e.target.value)}>{STATUSES.map(s => <option key={s}>{s}</option>)}</select>
          <input placeholder="Search rules…" value={q} onChange={e => setQ(e.target.value)} />
        </div>
        {err && <p className="err">{err}</p>}
        <ul>
          {shown.map(r => (
            <li key={r.id} className={r.id === sel ? 'on' : ''} onClick={() => setSel(r.id)}>
              <b>{r.proposed?.rule_key}</b> <span className={`chip ${r.status}`}>{r.status.replace(/_/g, ' ')}</span>
              <div className="muted">{r.proposed?.title}</div>
            </li>
          ))}
          {!shown.length && <li className="muted">Nothing matches.</li>}
        </ul>
      </aside>
      <section className="detail">
        {current ? <Detail key={current.id} item={current} roles={roles} onDone={load} /> : <p className="muted">Select a rule to review.</p>}
      </section>
    </div>
  )
}

function Detail({ item, roles, onDone }) {
  const [comment, setComment] = useState('')
  const [msg, setMsg] = useState('')
  const [busy, setBusy] = useState(false)
  const evidence = Array.isArray(item.evidence) ? item.evidence : []
  const p = item.proposed || {}
  const blocked = evidence.length === 0 || item.status === 'conflict'
  const final = item.status === 'approved' || item.status === 'rejected'

  async function act(kind) {
    if (kind !== 'approve' && !comment.trim()) { setMsg('Please give a reason.'); return }
    if (!window.confirm(kind === 'approve' ? 'Approve this rule version and make it active? This changes live compliance rules.' : 'Record this decision?')) return
    setBusy(true); setMsg('')
    const { error } = kind === 'approve'
      ? await supabase.rpc('approve_rule_change', { p_queue: item.id, p_comments: comment || null })
      : await supabase.rpc('reject_rule_change', { p_queue: item.id, p_reason: comment, p_needs_more: kind === 'more' })
    setBusy(false)
    if (error) setMsg(error.message); else onDone()
  }

  return (
    <div>
      <h2>{p.rule_key} — {p.title}</h2>
      <p><span className={`chip ${item.status}`}>{item.status.replace(/_/g, ' ')}</span> <span className="chip">confidence: {item.confidence}</span> <span className="chip">{p.law} · {p.form}</span></p>
      {item.conflict_note && <div className="warn"><b>Conflict:</b> {item.conflict_note}</div>}
      <dl>
        {[['Section / rule', p.section_or_rule], ['Applies to', p.applicability_text], ['Frequency', p.frequency], ['Due', p.due_text], ['Penalty / additional fee', p.penalty], ['Source document', p.source_document], ['Notes', p.notes]].map(([k, v]) => v ? <div key={k}><dt>{k}</dt><dd>{v}</dd></div> : null)}
        {p.source_url && <div><dt>Source URL</dt><dd><a href={p.source_url} target="_blank" rel="noreferrer">{p.source_url}</a></dd></div>}
      </dl>
      <h3>Evidence ({evidence.length})</h3>
      {evidence.length === 0 && <div className="warn">No primary-source evidence attached. This item cannot be approved.</div>}
      {evidence.map((e, i) => <blockquote key={i}>{e.passage}<footer className="muted">document {e.document_id}{e.page ? ` · page ${e.page}` : ''}</footer></blockquote>)}
      {!final && canApprove(roles) && (
        <div className="actions">
          <textarea placeholder="Reviewer comments / reason" value={comment} onChange={e => setComment(e.target.value)} />
          <button disabled={busy || blocked} onClick={() => act('approve')} title={blocked ? 'Needs evidence and no open conflict' : ''}>Approve</button>
          <button className="ghost" disabled={busy} onClick={() => act('more')}>Needs more research</button>
          <button className="danger" disabled={busy} onClick={() => act('reject')}>Reject</button>
        </div>
      )}
      {msg && <p className="err">{msg}</p>}
    </div>
  )
}
