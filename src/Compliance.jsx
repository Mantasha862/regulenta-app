import { useMemo, useState } from 'react'
import { supabase } from './supabase'
import { useLoad, must, fmtDate, fmtDateTime, daysUntil, OPEN, STAGES, STAGE_LABEL, nextSteps, humanError } from './lib.js'

const PRESETS = { due30: 'Due in next 30 days', today: 'Due today', overdue: 'Overdue', approvals: 'Pending approvals', evidence: 'Missing evidence', critical: 'High / critical alerts' }

export default function Compliance({ org, isAdmin, user, filter, setFilter }) {
  const [company, setCompany] = useState('')
  const [stage, setStage] = useState('open')
  const [q, setQ] = useState('')
  const [sel, setSel] = useState(filter.obligation || null)
  const list = useLoad(async () => {
    const obs = must(await supabase.from('obligations')
      .select('id,due_date,stage,lifecycle,period_label,requires_evidence,requires_approval,client_id,assignee,non_working_day,clients(name),rule_versions(rules(form,title))')
      .eq('org_id', org.id).eq('lifecycle', 'active').order('due_date'))
    const docs = new Set(must(await supabase.from('documents').select('obligation_id').eq('org_id', org.id).not('obligation_id', 'is', null)).map(d => d.obligation_id))
    return obs.map(o => ({ ...o, hasDoc: docs.has(o.id) }))
  }, [org.id])
  const companies = useMemo(() => [...new Map((list.data || []).map(o => [o.client_id, o.clients?.name])).entries()], [list.data])

  const notFiled = o => ['initiated', 'preparing', 'in_review', 'approved', 'executed'].includes(o.stage)
  const preset = filter.preset
  const shown = (list.data || []).filter(o => {
    if (company && o.client_id !== company) return false
    if (preset === 'due30' && !(notFiled(o) && daysUntil(o.due_date) >= 0 && daysUntil(o.due_date) <= 30)) return false
    if (preset === 'today' && !(notFiled(o) && daysUntil(o.due_date) === 0)) return false
    if (preset === 'overdue' && !(notFiled(o) && daysUntil(o.due_date) < 0)) return false
    if (preset === 'approvals' && o.stage !== 'in_review') return false
    if (preset === 'evidence' && !(['filed', 'evidence_pending'].includes(o.stage) && o.requires_evidence && !o.hasDoc)) return false
    if (preset === 'critical' && !(filter.ids || []).includes(o.id)) return false
    if (!preset && stage === 'open' && !OPEN(o.stage)) return false
    if (!preset && stage !== 'open' && stage !== 'all' && o.stage !== stage) return false
    if (q && !`${o.clients?.name} ${o.rule_versions?.rules?.form} ${o.rule_versions?.rules?.title} ${o.period_label}`.toLowerCase().includes(q.toLowerCase())) return false
    return true
  })
  const current = (list.data || []).find(o => o.id === sel)

  return (
    <div className="split">
      <aside className="list">
        <h3>Compliance calendar</h3>
        {preset && <p className="chip on">{PRESETS[preset]} <button className="link" onClick={() => setFilter({})}>clear</button></p>}
        <div className="filters">
          <select value={company} onChange={e => setCompany(e.target.value)}><option value="">All companies</option>{companies.map(([id, n]) => <option key={id} value={id}>{n}</option>)}</select>
          {!preset && <select value={stage} onChange={e => setStage(e.target.value)}><option value="open">Open items</option><option value="all">All</option>{STAGES.map(s => <option key={s} value={s}>{STAGE_LABEL[s]}</option>)}</select>}
          <input placeholder="Search…" value={q} onChange={e => setQ(e.target.value)} />
        </div>
        {list.error && <p className="err">{list.error}</p>}
        <ul>{shown.map(o => {
          const d = daysUntil(o.due_date), late = d < 0 && notFiled(o)
          return (
            <li key={o.id} className={`${o.id === sel ? 'on' : ''} ${late ? 'late' : ''}`} onClick={() => setSel(o.id)}>
              <div className="row"><b>{o.rule_versions?.rules?.form}</b><span className={`chip st-${o.stage}`}>{STAGE_LABEL[o.stage]}</span></div>
              <div className="small">{o.clients?.name} · {o.period_label}</div>
              <div className={`small ${late ? 'err' : 'muted'}`}>Due {fmtDate(o.due_date)}{late ? ` · ${-d} days overdue` : d >= 0 && notFiled(o) ? ` · in ${d} days` : ''}</div>
            </li>)
        })}
          {list.data && !shown.length && <li className="muted">Nothing matches.</li>}
        </ul>
      </aside>
      <section className="detail">
        {current ? <Obligation key={current.id} id={current.id} org={org} isAdmin={isAdmin} user={user} onChanged={list.reload} />
          : <p className="muted">{sel ? 'This item is not in your active list.' : 'Select an item.'}</p>}
      </section>
    </div>
  )
}

function Obligation({ id, org, isAdmin, user, onChanged }) {
  const d = useLoad(async () => {
    const o = must(await supabase.from('obligations')
      .select('*,clients(name,timezone),rule_versions(id,version,state,due_text,section_or_rule,authority,source_document,source_url,effective_from,approved_at,confidence,rules(rule_key,form,title))')
      .eq('id', id).single())
    const [tr, calc, docs, ev, ruleEv, members] = await Promise.all([
      supabase.from('obligation_transitions').select('*').eq('obligation_id', id).order('at'),
      supabase.from('due_date_calculations').select('*').eq('obligation_id', id).order('created_at'),
      supabase.from('documents').select('*').eq('obligation_id', id).order('created_at'),
      supabase.from('notification_events').select('id,trigger_type,stage_key,priority,event_date,due_date_snapshot').eq('obligation_id', id).order('created_at', { ascending: false }).limit(20),
      supabase.from('rule_evidence').select('id', { count: 'exact', head: true }).eq('rule_version_id', o.rule_version_id),
      supabase.rpc('org_member_directory', { p_org: org.id }),
    ])
    return { o, tr: tr.data || [], calc: calc.data || [], docs: docs.data || [], ev: ev.data || [], evidenceCount: ruleEv.count || 0, members: members.data || [] }
  }, [id])
  const [note, setNote] = useState('')
  const [ref, setRef] = useState('')
  const [msg, setMsg] = useState('')
  const [busy, setBusy] = useState(false)
  const [ext, setExt] = useState({ date: '', reason: '' })

  if (d.loading && !d.data) return <p className="muted">Loading…</p>
  if (d.error) return <p className="err">{d.error}</p>
  const { o, tr, calc, docs, ev, evidenceCount, members } = d.data
  const rv = o.rule_versions, rule = rv?.rules
  const verified = rv?.state === 'active' && rv?.approved_at && evidenceCount > 0
  const late = daysUntil(o.due_date) < 0 && ['initiated', 'preparing', 'in_review', 'approved', 'executed'].includes(o.stage)
  const refresh = () => { d.reload(); onChanged() }

  async function move(step) {
    setMsg('')
    if (step.needsNote && !note.trim()) { setMsg('Please write a reason first.'); return }
    if (step.needsRef && !ref.trim() && !o.reference_no) { setMsg('Enter the acknowledgement / SRN / ARN first.'); return }
    setBusy(true)
    const { error } = await supabase.rpc('transition_obligation', { p_obligation: o.id, p_to: step.to, p_note: note.trim() || null, p_reference: ref.trim() || null })
    setBusy(false)
    if (error) setMsg(humanError(error.message)); else { setNote(''); setRef(''); refresh() }
  }
  async function upload(e) {
    const file = e.target.files?.[0]; if (!file) return
    setMsg('Uploading…')
    const path = `${org.id}/${o.client_id}/${o.id}/${Date.now()}-${file.name.replace(/[^\w.\-]+/g, '_')}`
    const up = await supabase.storage.from('client-evidence').upload(path, file, { upsert: false })
    if (up.error) { setMsg(`Upload failed: ${up.error.message}`); return }
    const { error } = await supabase.from('documents').insert({ org_id: org.id, client_id: o.client_id, obligation_id: o.id, storage_path: path, file_name: file.name, uploaded_by: user.id })
    setMsg(error ? humanError(error.message) : 'Evidence uploaded.'); e.target.value = ''; refresh()
  }
  async function openDoc(doc) {
    const { data, error } = await supabase.storage.from('client-evidence').createSignedUrl(doc.storage_path, 60)
    if (error) setMsg(error.message); else window.open(data.signedUrl, '_blank', 'noopener')
  }
  async function extend(e) {
    e.preventDefault()
    const { error } = await supabase.rpc('extend_obligation', { p_obligation: o.id, p_new_date: ext.date, p_reason: ext.reason, p_change: null })
    setMsg(error ? humanError(error.message) : 'Deadline revised. Future reminders follow the new date.'); setExt({ date: '', reason: '' }); refresh()
  }
  async function patch(p) { const { error } = await supabase.from('obligations').update(p).eq('id', o.id); if (error) setMsg(humanError(error.message)); else refresh() }

  return (
    <div>
      <div className="row"><h2>{rule?.form} — {rule?.title}</h2><span className={`chip st-${o.stage}`}>{STAGE_LABEL[o.stage]}</span></div>
      <p className="muted">{o.clients?.name} · {o.period_label}</p>
      <dl>
        <div><dt>Due date</dt><dd className={late ? 'err' : ''}><b>{fmtDate(o.due_date)}</b>{late ? ` · ${-daysUntil(o.due_date)} days overdue` : ''}
          {o.original_due_date && o.original_due_date !== o.due_date && <span className="muted"> (originally {fmtDate(o.original_due_date)})</span>}
          {o.non_working_day && <div className="warn small">Falls on a non-working day. The date has not been moved: check whether an extension or holiday rule applies.</div>}</dd></div>
        <div><dt>How calculated</dt><dd>{o.due_date_basis || rv?.due_text}</dd></div>
        <div><dt>Legal basis</dt><dd>{[rv?.authority, rv?.section_or_rule, rv?.source_document].filter(Boolean).join(' · ') || '—'}
          {rv?.source_url && <> · <a href={rv.source_url} target="_blank" rel="noreferrer">official source</a></>}</dd></div>
        <div><dt>Verification</dt><dd>{verified
          ? <span className="chip approved">Approved rule v{rv.version} · {evidenceCount} evidence record(s) · approved {fmtDate(rv.approved_at)}</span>
          : <span className="chip conflict">Not verified: reminders for this item go to reviewers only</span>}
          {rv?.effective_from && <span className="muted small"> · effective from {fmtDate(rv.effective_from)}</span>}</dd></div>
        <div><dt>Assigned to</dt><dd><select value={o.assignee || ''} onChange={e => patch({ assignee: e.target.value || null })}>
          <option value="">Not assigned</option>{members.map(m => <option key={m.user_id} value={m.user_id}>{m.email}</option>)}</select></dd></div>
        <div><dt>Workflow</dt><dd>{o.requires_approval ? 'Review and approval required' : 'No approval step'} · {o.requires_evidence ? 'evidence required to close' : 'evidence optional'}
          {o.reference_no && <> · reference <b>{o.reference_no}</b></>}</dd></div>
      </dl>

      <h3>Next step</h3>
      <div className="actions">
        <textarea placeholder="Note or reason (required to return, reopen, cancel)" value={note} onChange={e => setNote(e.target.value)} />
        {nextSteps(o, isAdmin).some(s => s.needsRef) && <input placeholder="Acknowledgement / SRN / ARN" value={ref} onChange={e => setRef(e.target.value)} />}
        {nextSteps(o, isAdmin).map(s => <button key={s.to + s.label} disabled={busy} className={s.danger ? 'danger' : s.to === 'preparing' && o.stage !== 'initiated' ? 'ghost' : ''} onClick={() => move(s)}>{s.label}</button>)}
      </div>
      {msg && <p className="muted">{msg}</p>}

      <h3>Evidence ({docs.length})</h3>
      <ul className="simple">{docs.map(doc => <li key={doc.id}><button className="link" onClick={() => openDoc(doc)}>{doc.file_name}</button> <span className="muted small">{fmtDateTime(doc.created_at)}</span></li>)}</ul>
      {OPEN(o.stage) && <label className="inline">Upload evidence <input type="file" onChange={upload} /></label>}

      {OPEN(o.stage) && (
        <form onSubmit={extend} className="form wide">
          <h4>Revise the deadline</h4>
          <p className="muted small">Use only for an official extension (cite the notification or circular). The original date is kept and every change is recorded.</p>
          <div className="fields"><label>New due date<input type="date" required value={ext.date} onChange={e => setExt({ ...ext, date: e.target.value })} /></label>
            <label className="span2">Reason / authority<input required value={ext.reason} onChange={e => setExt({ ...ext, reason: e.target.value })} /></label></div>
          <button className="ghost">Revise deadline</button>
        </form>)}

      <h3>History</h3>
      <ul className="simple small">
        {calc.map(c => <li key={c.id}>{fmtDateTime(c.created_at)} · due date {c.kind}: {fmtDate(c.due_date)}{c.previous_due_date ? ` (was ${fmtDate(c.previous_due_date)})` : ''} · {c.explanation}</li>)}
        {tr.map(t => <li key={t.id}>{fmtDateTime(t.at)} · {STAGE_LABEL[t.from_stage] || '—'} → <b>{STAGE_LABEL[t.to_stage]}</b>{t.reference_no ? ` · ref ${t.reference_no}` : ''}{t.note ? ` · ${t.note}` : ''}</li>)}
      </ul>
      <h4>Reminders sent</h4>
      <ul className="simple small">{ev.map(e => <li key={e.id}>{fmtDate(e.event_date)} · {e.trigger_type.replace(/_/g, ' ')} ({e.stage_key}) · {e.priority}</li>)}
        {!ev.length && <li className="muted">None yet.</li>}</ul>
    </div>
  )
}
