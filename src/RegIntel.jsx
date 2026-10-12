import { useState } from 'react'
import { supabase } from './supabase'
import { useLoad, must, fmtDate, fmtDateTime, humanError } from './lib.js'

const LEGAL = [['binding_act', 'Act / Amendment Act (binding law)'], ['delegated_legislation', 'Rules / Regulations / notification (delegated legislation)'],
  ['official_guidance', 'Circular / FAQ / clarification (official guidance)'], ['draft_proposal', 'Draft / consultation paper (not law)'], ['informational', 'Informational publication']]
const ACTIONS = ['new', 'inserted', 'amended', 'substituted', 'omitted', 'repealed', 'clarified', 'commencement', 'corrigendum']
const CHANGE_TYPES = ['amendment', 'new_notification', 'new_circular', 'new_order', 'new_regulation', 'new_rule', 'repeal', 'replacement', 'extension',
  'due_date_extension', 'new_form', 'revised_form', 'new_filing_requirement', 'changed_threshold', 'changed_applicability', 'changed_penalty',
  'changed_frequency', 'changed_reporting', 'new_exemption', 'withdrawal', 'clarification', 'judicial', 'interpretation']

export default function RegIntel({ roles }) {
  const [tab, setTab] = useState('changes')
  const [sel, setSel] = useState(null)
  const [fl, setFl] = useState({ authority: '', legal: '', status: '', from: '' })
  const data = useLoad(async () => {
    const [ch, auth, src, rules] = await Promise.all([
      supabase.from('regulatory_changes').select('*,regulatory_authorities(code,name),regulatory_documents(title,doc_number,official_url,published_on,doc_date,retrieval_status)').order('detected_at', { ascending: false }).limit(300),
      supabase.from('regulatory_authorities').select('*').order('code'),
      supabase.from('regulatory_sources').select('*,regulatory_authorities(code)').order('name'),
      supabase.from('rules').select('id,rule_key,form,title').order('rule_key'),
    ])
    for (const r of [ch, auth, src, rules]) if (r.error) throw new Error(r.error.message)
    return { ch: ch.data, auth: auth.data, src: src.data, rules: rules.data }
  }, [])
  if (data.loading && !data.data) return <p className="muted">Loading…</p>
  if (data.error) return <p className="err">{data.error}</p>
  const v = data.data
  const isAdmin = roles.some(r => ['super_admin', 'admin'].includes(r))
  const shown = v.ch.filter(c => (!fl.authority || c.authority_id === fl.authority) && (!fl.legal || c.legal_status === fl.legal)
    && (!fl.status || c.status === fl.status) && (!fl.from || (c.published_on || '') >= fl.from))
  const soon = v.ch.filter(c => c.effective_on && c.effective_on >= new Date().toISOString().slice(0, 10)).length
  const cur = v.ch.find(c => c.id === sel)
  return (
    <section>
      <h2>Regulatory intelligence</h2>
      <p className="muted">Detected publications stay here, labelled by legal status, until a reviewer verifies them against the original and approves a rule version. Nothing here changes a client's obligations by itself.</p>
      <div className="tiles">
        {[['Logged changes', v.ch.length], ['Awaiting review', v.ch.filter(c => ['new', 'pending_review', 'ai_researched'].includes(c.status)).length],
          ['Approved', v.ch.filter(c => c.status === 'approved').length], ['Effective soon / future', soon],
          ['Interpretation required', v.ch.filter(c => c.interpretation_required).length], ['Failed retrievals', v.src.filter(s => s.status === 'failing').length + v.ch.filter(c => c.regulatory_documents?.retrieval_status === 'failed').length],
          ['Sources needing verification', v.src.filter(s => s.status === 'needs_verification').length]].map(([l, n]) =>
          <div key={l} className="tile static"><span className="n">{n}</span><span>{l}</span></div>)}
      </div>
      <nav className="subtabs">{[['changes', 'Changes'], ['log', 'Log a publication'], ['sources', 'Sources & authorities']].map(([k, l]) =>
        <button key={k} className={tab === k ? 'on' : 'ghost'} onClick={() => setTab(k)}>{l}</button>)}</nav>

      {tab === 'changes' && (
        <div className="split inner">
          <aside className="list">
            <div className="filters">
              <select value={fl.authority} onChange={e => setFl({ ...fl, authority: e.target.value })}><option value="">All authorities</option>{v.auth.map(a => <option key={a.id} value={a.id}>{a.code}</option>)}</select>
              <select value={fl.legal} onChange={e => setFl({ ...fl, legal: e.target.value })}><option value="">Any legal status</option>{LEGAL.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
              <select value={fl.status} onChange={e => setFl({ ...fl, status: e.target.value })}><option value="">Any review status</option>{['new', 'pending_review', 'approved', 'rejected', 'needs_more_research', 'conflict', 'superseded'].map(s => <option key={s}>{s}</option>)}</select>
              <label className="inline small">Published from <input type="date" value={fl.from} onChange={e => setFl({ ...fl, from: e.target.value })} /></label>
            </div>
            <ul>{shown.map(c => (
              <li key={c.id} className={c.id === sel ? 'on' : ''} onClick={() => setSel(c.id)}>
                <b>{c.title || c.regulatory_documents?.title}</b>
                <div className="small"><span className={`chip ${c.status}`}>{c.status.replace(/_/g, ' ')}</span> {c.legal_status && <span className="chip">{c.legal_status.replace(/_/g, ' ')}</span>}</div>
                <div className="muted small">{c.regulatory_authorities?.code} · published {fmtDate(c.published_on)}{c.effective_on ? ` · effective ${fmtDate(c.effective_on)}` : ''}</div>
              </li>))}
              {!shown.length && <li className="muted">No changes logged.</li>}</ul>
          </aside>
          <section className="detail">{cur ? <ImpactReport key={cur.id} c={cur} rules={v.rules} /> : <p className="muted">Select a change to see its impact report.</p>}</section>
        </div>)}
      {tab === 'log' && <LogForm v={v} onSaved={() => { data.reload(); setTab('changes') }} />}
      {tab === 'sources' && <Sources v={v} isAdmin={isAdmin} onSaved={data.reload} />}
    </section>
  )
}

function ImpactReport({ c, rules }) {
  const impact = useLoad(async () => must(await supabase.rpc('change_impact', { p_change: c.id })), [c.id])
  const doc = c.regulatory_documents || {}
  return (
    <div>
      <h3>Regulatory change impact report</h3>
      <dl>
        {[['Document', `${doc.title || ''}${doc.doc_number ? ` · ${doc.doc_number}` : ''}`], ['Legal status', c.legal_status?.replace(/_/g, ' ')],
          ['Change', `${c.change_type.replace(/_/g, ' ')}${c.action ? ` · provision ${c.action}` : ''}`], ['Affected law / provision', [c.affected_law, c.affected_provision].filter(Boolean).join(' · ')],
          ['Document date', fmtDate(doc.doc_date)], ['Publication date', fmtDate(c.published_on)], ['Effective date', fmtDate(c.effective_on)], ['Commencement date', fmtDate(c.commencement_on)],
          ['What existed before', c.previous_requirement], ['What changed', c.new_requirement], ['Client action', c.client_action],
          ['Review status', c.status.replace(/_/g, ' ')], ['Detected', fmtDateTime(c.detected_at)]].map(([k, val]) => val && val !== '—' ? <div key={k}><dt>{k}</dt><dd>{val}</dd></div> : null)}
        {doc.official_url && <div><dt>Official source</dt><dd><a href={doc.official_url} target="_blank" rel="noreferrer">{doc.official_url}</a> <span className="muted small">({doc.retrieval_status})</span></dd></div>}
      </dl>
      {c.interpretation_required && <div className="warn">Human interpretation required: this is not binding law on its own, or it needs legal judgement before any rule changes.</div>}
      {c.impact_summary && <div className="warn small"><b>Draft impact note (unverified):</b> {c.impact_summary}</div>}
      <h4>Affected rules and companies</h4>
      {impact.error && <p className="err">{impact.error}</p>}
      <table className="tbl"><thead><tr><th>Rule</th><th>Active version</th><th>Open items</th><th>Companies</th><th>Organisations</th></tr></thead>
        <tbody>{impact.data?.map(r => <tr key={r.rule_id}><td><b>{r.rule_key}</b> {r.title}</td><td>{r.active_version ?? '—'}</td><td>{r.open_obligations}</td><td>{r.companies}</td><td>{r.organisations}</td></tr>)}
          {impact.data && !impact.data.length && <tr><td colSpan="5" className="muted">No existing rule linked: may be a new obligation.</td></tr>}</tbody></table>
      <p className="muted small">Client obligations change only when a reviewer approves a new rule version in the review queue; affected companies are then recalculated and notified automatically.</p>
    </div>
  )
}

function LogForm({ v, onSaved }) {
  const [f, setF] = useState({ authority: '', title: '', doc_type: 'notification', url: '', legal: 'delegated_legislation', change_type: 'amendment', action: 'amended',
    doc_number: '', published: '', doc_date: '', effective: '', commencement: '', jurisdiction: '', law: '', provision: '', prev: '', next: '', rules: [] })
  const [msg, setMsg] = useState('')
  const set = k => e => setF({ ...f, [k]: e.target.value })
  async function submit(e) {
    e.preventDefault(); setMsg('')
    const { error } = await supabase.rpc('log_regulatory_change', {
      p_authority: f.authority, p_title: f.title, p_doc_type: f.doc_type, p_official_url: f.url, p_legal_status: f.legal, p_change_type: f.change_type,
      p_action: f.action, p_doc_number: f.doc_number || null, p_published_on: f.published || null, p_doc_date: f.doc_date || null,
      p_effective_on: f.effective || null, p_commencement_on: f.commencement || null, p_jurisdiction: f.jurisdiction || null, p_affected_law: f.law || null,
      p_affected_provision: f.provision || null, p_previous_requirement: f.prev || null, p_new_requirement: f.next || null, p_affected_rule_ids: f.rules,
      p_source: null, p_sha256: null, p_storage_path: null })
    if (error) setMsg(humanError(error.message)); else onSaved()
  }
  return (
    <form onSubmit={submit} className="form wide">
      <p className="muted">Record a publication from an official source. Keep publication, document and effective dates separate. Drafts and guidance are tracked but never turned into rules directly.</p>
      <div className="fields">
        <label>Authority<select required value={f.authority} onChange={set('authority')}><option value="">Choose…</option>{v.auth.map(a => <option key={a.id} value={a.id}>{a.code} — {a.name}</option>)}</select></label>
        <label>Legal status<select value={f.legal} onChange={set('legal')}>{LEGAL.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
        <label className="span2">Title<input required value={f.title} onChange={set('title')} /></label>
        <label>Document type<input value={f.doc_type} onChange={set('doc_type')} placeholder="notification / circular / Act / rules / order…" /></label>
        <label>Notification / circular number<input value={f.doc_number} onChange={set('doc_number')} /></label>
        <label className="span2">Official source URL<input required type="url" value={f.url} onChange={set('url')} /></label>
        <label>Document date<input type="date" value={f.doc_date} onChange={set('doc_date')} /></label>
        <label>Publication (Gazette) date<input type="date" value={f.published} onChange={set('published')} /></label>
        <label>Effective date<input type="date" value={f.effective} onChange={set('effective')} /></label>
        <label>Commencement date<input type="date" value={f.commencement} onChange={set('commencement')} /></label>
        <label>Change type<select value={f.change_type} onChange={set('change_type')}>{CHANGE_TYPES.map(t => <option key={t}>{t}</option>)}</select></label>
        <label>Provision was<select value={f.action} onChange={set('action')}>{ACTIONS.map(t => <option key={t}>{t}</option>)}</select></label>
        <label>Jurisdiction<input value={f.jurisdiction} onChange={set('jurisdiction')} placeholder="India / Maharashtra / …" /></label>
        <label>Affected law<input value={f.law} onChange={set('law')} /></label>
        <label className="span2">Affected section / rule / regulation / paragraph<input value={f.provision} onChange={set('provision')} /></label>
        <label className="span2">What existed before<textarea value={f.prev} onChange={set('prev')} /></label>
        <label className="span2">What changed<textarea value={f.next} onChange={set('next')} /></label>
        <label className="span2">Existing rules affected (hold Ctrl / ⌘ to choose several)
          <select multiple size="6" value={f.rules} onChange={e => setF({ ...f, rules: [...e.target.selectedOptions].map(o => o.value) })}>
            {v.rules.map(r => <option key={r.id} value={r.id}>{r.rule_key} — {r.title}</option>)}</select></label>
      </div>
      <button>Log publication</button>
      {msg && <p className="err">{msg}</p>}
    </form>
  )
}

function Sources({ v, isAdmin, onSaved }) {
  const [a, setA] = useState({ code: '', name: '', level: 'central', jurisdiction: '', website: '' })
  const [s, setS] = useState({ authority_id: '', name: '', url: '', source_type: 'notification_page', check_every_hours: 24, notes: '' })
  const [msg, setMsg] = useState('')
  async function addA(e) { e.preventDefault(); const { error } = await supabase.from('regulatory_authorities').insert(a); setMsg(error ? humanError(error.message) : 'Authority added.'); if (!error) onSaved() }
  async function addS(e) { e.preventDefault(); const { error } = await supabase.from('regulatory_sources').insert({ ...s, check_every_hours: Number(s.check_every_hours) }); setMsg(error ? humanError(error.message) : 'Source added (status: needs verification).'); if (!error) onSaved() }
  return (
    <div>
      <p className="muted">Register each official source and how it can be monitored (feed, API, email alert or manual checking). A source is "needs verification" until an admin confirms the address and method; nothing is scraped from sites that do not permit it.</p>
      <table className="tbl"><thead><tr><th>Source</th><th>Authority</th><th>Type</th><th>Status</th><th>Last checked</th></tr></thead>
        <tbody>{v.src.map(x => <tr key={x.id}><td>{x.name}<div className="muted small"><a href={x.url} target="_blank" rel="noreferrer">{x.url}</a></div></td><td>{x.regulatory_authorities?.code}</td><td>{x.source_type}</td><td>{x.status}</td><td>{fmtDateTime(x.last_checked_at)}</td></tr>)}
          {!v.src.length && <tr><td colSpan="5" className="muted">No sources registered.</td></tr>}</tbody></table>
      {isAdmin && (
        <div className="two">
          <form onSubmit={addA} className="form"><h4>Add authority</h4>
            <label>Code<input required value={a.code} onChange={e => setA({ ...a, code: e.target.value.toUpperCase() })} placeholder="MCA" /></label>
            <label>Name<input required value={a.name} onChange={e => setA({ ...a, name: e.target.value })} /></label>
            <label>Level<select value={a.level} onChange={e => setA({ ...a, level: e.target.value })}><option>central</option><option>state</option><option>local</option></select></label>
            <label>Jurisdiction<input value={a.jurisdiction} onChange={e => setA({ ...a, jurisdiction: e.target.value })} /></label>
            <label>Website<input type="url" value={a.website} onChange={e => setA({ ...a, website: e.target.value })} /></label>
            <button>Add authority</button></form>
          <form onSubmit={addS} className="form"><h4>Add source</h4>
            <label>Authority<select required value={s.authority_id} onChange={e => setS({ ...s, authority_id: e.target.value })}><option value="">Choose…</option>{v.auth.map(x => <option key={x.id} value={x.id}>{x.code}</option>)}</select></label>
            <label>Name<input required value={s.name} onChange={e => setS({ ...s, name: e.target.value })} /></label>
            <label>URL<input required type="url" value={s.url} onChange={e => setS({ ...s, url: e.target.value })} /></label>
            <label>Type<select value={s.source_type} onChange={e => setS({ ...s, source_type: e.target.value })}>{['webpage', 'notification_page', 'circular_repository', 'pdf', 'gazette', 'document', 'announcement', 'rss', 'api'].map(t => <option key={t}>{t}</option>)}</select></label>
            <label>Check every (hours)<input type="number" min="1" value={s.check_every_hours} onChange={e => setS({ ...s, check_every_hours: e.target.value })} /></label>
            <label>How it may be monitored<input value={s.notes} onChange={e => setS({ ...s, notes: e.target.value })} placeholder="RSS / email alert / manual — permitted method" /></label>
            <button>Add source</button></form>
        </div>)}
      {msg && <p className="muted">{msg}</p>}
    </div>
  )
}
