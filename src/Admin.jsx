import { useEffect, useMemo, useState } from 'react'
import { supabase } from './supabase'
import { humanError } from './lib.js'

const STATUSES = ['all', 'new', 'pending_review', 'conflict', 'needs_more_research', 'approved', 'rejected']
const canApprove = roles => roles.some(r => ['super_admin', 'admin', 'reviewer'].includes(r))
// The reviewer ticks these against the ORIGINAL document. They are a discipline aid; the database separately refuses
// approval without evidence or with an open conflict.
const CHECKS = ['Opened the original Act / Rule / notification / circular / Gazette (not a summary)', 'Quoted provision matches the original text',
  'Document number and date checked', 'Effective / commencement date located (separate from publication date)',
  'Applicability conditions checked', 'Due-date logic matches the text (no assumed holiday shift)', 'Superseded / previous version identified',
  'No conflicting source left unresolved']

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
  const shown = rows.filter(r => (filter === 'all' || r.status === filter) && (!q || JSON.stringify(r.proposed).toLowerCase().includes(q.toLowerCase())))
  const current = rows.find(r => r.id === sel)
  return (
    <div className="split">
      <aside className="list">
        <h3>Research and review queue</h3>
        <div className="stats">{STATUSES.slice(1).map(s => <span key={s} className={`chip ${s}`}>{s.replace(/_/g, ' ')}: {counts[s] || 0}</span>)}</div>
        <div className="filters">
          <select value={filter} onChange={e => setFilter(e.target.value)}>{STATUSES.map(s => <option key={s}>{s}</option>)}</select>
          <input placeholder="Search rules…" value={q} onChange={e => setQ(e.target.value)} />
        </div>
        {err && <p className="err">{err}</p>}
        <ul>{shown.map(r => (
          <li key={r.id} className={r.id === sel ? 'on' : ''} onClick={() => setSel(r.id)}>
            <b>{r.proposed?.rule_key || r.proposed?.title}</b> <span className={`chip ${r.status}`}>{r.status.replace(/_/g, ' ')}</span>
            <div className="muted small">{r.proposed?.title}</div>
          </li>))}
          {!shown.length && <li className="muted">Nothing matches.</li>}
        </ul>
      </aside>
      <section className="detail">{current ? <Detail key={current.id} item={current} roles={roles} onDone={load} /> : <p className="muted">Select an item to review.</p>}</section>
    </div>
  )
}

function Detail({ item, roles, onDone }) {
  const [comment, setComment] = useState('')
  const [checks, setChecks] = useState(CHECKS.map(() => false))
  const [confirming, setConfirming] = useState(null)
  const [msg, setMsg] = useState('')
  const [busy, setBusy] = useState(false)
  const evidence = Array.isArray(item.evidence) ? item.evidence : []
  const p = item.proposed || {}
  const final = ['approved', 'rejected', 'superseded'].includes(item.status)
  const missing = [evidence.length === 0 && 'no primary-source evidence attached', item.status === 'conflict' && 'conflicting sources unresolved',
    !checks.every(Boolean) && 'review checklist incomplete', !comment.trim() && 'reviewer note missing'].filter(Boolean)

  async function act(kind) {
    setConfirming(null)
    if (kind !== 'approve' && !comment.trim()) { setMsg('Please give a reason.'); return }
    setBusy(true); setMsg('')
    const { error } = kind === 'approve'
      ? await supabase.rpc('approve_rule_change', { p_queue: item.id, p_comments: comment })
      : await supabase.rpc('reject_rule_change', { p_queue: item.id, p_reason: comment, p_needs_more: kind === 'more' })
    setBusy(false)
    if (error) setMsg(humanError(error.message)); else onDone()
  }
  return (
    <div>
      <h2>{p.rule_key || '(new obligation)'} — {p.title}</h2>
      <p><span className={`chip ${item.status}`}>{item.status.replace(/_/g, ' ')}</span> <span className="chip">confidence: {item.confidence}</span> {p.law && <span className="chip">{p.law} · {p.form}</span>}</p>
      {item.conflict_note && <div className="warn"><b>Conflict:</b> {item.conflict_note}</div>}
      {item.ai_summary && <div className="warn small"><b>AI draft summary (not verified):</b> {item.ai_summary}</div>}
      <dl>
        {[['Section / rule', p.section_or_rule], ['Applies to', p.applicability_text], ['Frequency', p.frequency], ['Due', p.due_text],
          ['Schedule (engine)', p.schedule && JSON.stringify(p.schedule)], ['Previous requirement', item.previous_rule], ['New requirement', p.new_requirement],
          ['Effective date', item.effective_date], ['Penalty / additional fee', p.penalty], ['Source document', p.source_document], ['Notes', p.notes]]
          .map(([k, v]) => v ? <div key={k}><dt>{k}</dt><dd>{v}</dd></div> : null)}
        {p.source_url && <div><dt>Source URL</dt><dd><a href={p.source_url} target="_blank" rel="noreferrer">{p.source_url}</a></dd></div>}
      </dl>
      {p.schedule && !['monthly_day', 'annual_fixed', 'annual_dates', 'after_period_end', 'event_offset', 'manual'].includes(p.schedule.type) &&
        <div className="warn">The schedule is not in a canonical form. If approved as is, the deadline engine will skip it ("non-canonical schedule"). Convert it during review.</div>}
      <h3>Evidence ({evidence.length})</h3>
      {evidence.length === 0 && <div className="warn">No primary-source evidence attached. This item cannot be approved.</div>}
      {evidence.map((e, i) => <blockquote key={i}>{e.passage}<footer className="muted">document {e.document_id}{e.page ? ` · page ${e.page}` : ''}</footer></blockquote>)}
      {!final && canApprove(roles) && <Research item={item} onSaved={onDone} />}
      {!final && canApprove(roles) && item.status !== 'new' && item.status !== 'needs_more_research' && (
        <>
          <h3>Review checklist</h3>
          <ul className="checks">{CHECKS.map((c, i) => <li key={c}><label className="inline"><input type="checkbox" checked={checks[i]} onChange={e => setChecks(checks.map((x, j) => j === i ? e.target.checked : x))} /> {c}</label></li>)}</ul>
          <div className="actions">
            <textarea placeholder="Reviewer note / reason (required)" value={comment} onChange={e => setComment(e.target.value)} />
            {confirming
              ? <span className="confirm">{confirming === 'approve' ? 'Approve and make this the active rule version? Affected clients will be notified.' : 'Record this decision?'}
                  <button onClick={() => act(confirming)}>Yes</button><button className="ghost" onClick={() => setConfirming(null)}>No</button></span>
              : <>
                  <button disabled={busy || missing.length > 0} onClick={() => setConfirming('approve')}>Approve rule</button>
                  <button className="ghost" disabled={busy} onClick={() => setConfirming('more')}>Needs more research</button>
                  <button className="danger" disabled={busy} onClick={() => setConfirming('reject')}>Reject</button>
                </>}
          </div>
          {missing.length > 0 && <p className="muted small">Approve is disabled: {missing.join('; ')}.</p>}
        </>)}
      {msg && <p className="err">{msg}</p>}
    </div>
  )
}

// Research workspace: complete the proposal and attach primary-source evidence, then send it for review.
// The proposal's schedule must use a canonical type so the deadline engine can calculate dates.
function Research({ item, onSaved }) {
  const [json, setJson] = useState(JSON.stringify(item.proposed || {}, null, 2))
  const [ev, setEv] = useState({ document_id: '', passage: '', page: '' })
  const [docs, setDocs] = useState([])
  const [msg, setMsg] = useState('')
  const [open, setOpen] = useState(item.status === 'new' || item.status === 'needs_more_research')
  useEffect(() => { supabase.from('regulatory_documents').select('id,title,doc_number,published_on').order('created_at', { ascending: false }).limit(200).then(({ data }) => setDocs(data || [])) }, [])
  async function save(send) {
    setMsg('')
    let proposed
    try { proposed = JSON.parse(json) } catch { setMsg('The proposal is not valid JSON.'); return }
    const evidence = [...(Array.isArray(item.evidence) ? item.evidence : [])]
    if (ev.document_id && ev.passage.trim()) evidence.push({ document_id: ev.document_id, passage: ev.passage.trim(), page: ev.page ? Number(ev.page) : null })
    const patch = { proposed, evidence, ...(send ? { status: 'pending_review' } : {}) }
    const { error } = await supabase.from('research_queue').update(patch).eq('id', item.id)
    if (error) setMsg(humanError(error.message)); else { setEv({ document_id: '', passage: '', page: '' }); onSaved() }
  }
  if (!open) return <p><button className="link" onClick={() => setOpen(true)}>Edit proposal / add evidence</button></p>
  return (
    <div className="form wide">
      <h3>Research workspace</h3>
      <p className="muted small">Canonical schedule types: monthly_day {'{day}'}, annual_fixed {'{day, month}'}, annual_dates {'{dates:["MM-DD"]}'},
        after_period_end {'{period: month|quarter|half_year|fy, days, day_type}'}, event_offset {'{anchor, days, day_type, direction}'}, manual {'{note}'}.
        Add holiday_rule "next_working_day" only with a holiday_source citing the provision.</p>
      <label>Proposal (JSON)<textarea className="code" rows="12" value={json} onChange={e => setJson(e.target.value)} /></label>
      <h4>Add evidence from an original document</h4>
      <div className="fields">
        <label className="span2">Document<select value={ev.document_id} onChange={e => setEv({ ...ev, document_id: e.target.value })}><option value="">Choose a logged document…</option>
          {docs.map(d => <option key={d.id} value={d.id}>{d.title}{d.doc_number ? ` · ${d.doc_number}` : ''}{d.published_on ? ` · ${d.published_on}` : ''}</option>)}</select></label>
        <label className="span2">Exact passage from the original<textarea value={ev.passage} onChange={e => setEv({ ...ev, passage: e.target.value })} /></label>
        <label>Page<input type="number" min="1" value={ev.page} onChange={e => setEv({ ...ev, page: e.target.value })} /></label>
      </div>
      <div className="row left"><button className="ghost" onClick={() => save(false)}>Save draft</button><button onClick={() => save(true)}>Save and send for review</button></div>
      {msg && <p className="err">{msg}</p>}
    </div>
  )
}
