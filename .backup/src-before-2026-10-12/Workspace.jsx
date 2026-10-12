import { useEffect, useState } from 'react'
import { supabase } from './supabase'

const ENTITY_TYPES = ['Private Limited Company', 'Public Limited Company (Unlisted)', 'Listed Company', 'One Person Company', 'LLP', 'Section 8 Company', 'Partnership / Proprietorship', 'Other']
const MONTHS = ['January','February','March','April','May','June','July','August','September','October','November','December']

export default function Workspace({ user }) {
  const [orgs, setOrgs] = useState(null)
  const [orgId, setOrgId] = useState(null)
  const [tab, setTab] = useState('companies')

  async function loadOrgs() {
    const { data } = await supabase.from('orgs').select('id,name,type,plan').order('created_at')
    setOrgs(data || [])
    if (data?.length && !orgId) setOrgId(data[0].id)
  }
  useEffect(() => { loadOrgs() }, [])

  if (orgs === null) return <div className="center">Loading…</div>
  if (!orgs.length) return <CreateOrg onDone={async id => { setOrgId(id); await loadOrgs() }} />
  const org = orgs.find(o => o.id === orgId) || orgs[0]

  return (
    <main className="ws">
      <div className="wsbar">
        <h2>{org.name} <span className="chip">{org.type === 'firm' ? 'Firm' : 'Company'}</span></h2>
        {orgs.length > 1 && <select value={org.id} onChange={e => setOrgId(e.target.value)}>{orgs.map(o => <option key={o.id} value={o.id}>{o.name}</option>)}</select>}
        <nav className="tabs">
          <button className={tab === 'companies' ? '' : 'ghost'} onClick={() => setTab('companies')}>Companies</button>
          <button className={tab === 'deadlines' ? '' : 'ghost'} onClick={() => setTab('deadlines')}>Deadlines</button>
        </nav>
      </div>
      {tab === 'companies' ? <Companies org={org} /> : <Deadlines org={org} />}
    </main>
  )
}

function CreateOrg({ onDone }) {
  const [name, setName] = useState('')
  const [type, setType] = useState('firm')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)
  async function submit(e) {
    e.preventDefault(); setBusy(true); setErr('')
    const { data, error } = await supabase.rpc('create_org', { p_name: name.trim(), p_type: type })
    setBusy(false)
    if (error) setErr(error.message); else onDone(data)
  }
  return (
    <main className="login">
      <form onSubmit={submit} className="card">
        <h2>Set up your workspace</h2>
        <p className="muted">This is the firm or company that will track compliance. You can add client companies next.</p>
        <label>Name<input required value={name} onChange={e => setName(e.target.value)} placeholder="e.g. Insight Juris LLP" /></label>
        <label>Type
          <select value={type} onChange={e => setType(e.target.value)}>
            <option value="firm">CS / law / accounting firm (manages several clients)</option>
            <option value="company">A single company (manages its own compliance)</option>
          </select>
        </label>
        <button disabled={busy || !name.trim()}>Create workspace</button>
        {err && <p className="err">{err}</p>}
      </form>
    </main>
  )
}

function Companies({ org }) {
  const [rows, setRows] = useState([])
  const [editing, setEditing] = useState(null)
  const [err, setErr] = useState('')

  async function load() {
    const { data, error } = await supabase.from('clients').select('*').eq('org_id', org.id).is('archived_at', null).order('name')
    if (error) setErr(error.message); else { setErr(''); setRows(data) }
  }
  useEffect(() => { load() }, [org.id])

  async function archive(c) {
    if (!window.confirm(`Archive ${c.name}? It will be hidden but not deleted.`)) return
    const { error } = await supabase.from('clients').update({ archived_at: new Date().toISOString() }).eq('id', c.id)
    if (error) setErr(error.message); else load()
  }

  return (
    <section>
      <div className="row"><h3>Companies ({rows.length})</h3><button onClick={() => setEditing({})}>+ Add company</button></div>
      {err && <p className="err">{err}</p>}
      {editing && <CompanyForm org={org} item={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); load() }} />}
      {!rows.length && !editing && <p className="muted">No companies yet. Add the first one to start tracking.</p>}
      <div className="grid">
        {rows.map(c => (
          <div key={c.id} className="card">
            <b>{c.name}</b>
            <span className="muted">{c.entity_type}{c.cin_or_llpin ? ` · ${c.cin_or_llpin}` : ''}</span>
            <span className="muted">FY ends {MONTHS[c.fy_end_month - 1]}{c.state ? ` · ${c.state}` : ''}</span>
            <div className="row"><button className="ghost" onClick={() => setEditing(c)}>Edit</button><button className="ghost" onClick={() => archive(c)}>Archive</button></div>
          </div>
        ))}
      </div>
    </section>
  )
}

function CompanyForm({ org, item, onClose, onSaved }) {
  const [f, setF] = useState({ name: '', cin_or_llpin: '', entity_type: ENTITY_TYPES[0], fy_end_month: 3, state: '', ...item })
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)
  const set = k => e => setF({ ...f, [k]: e.target.value })

  async function save(e) {
    e.preventDefault(); setBusy(true); setErr('')
    const payload = { name: f.name.trim(), cin_or_llpin: f.cin_or_llpin?.trim() || null, entity_type: f.entity_type, fy_end_month: Number(f.fy_end_month), state: f.state?.trim() || null }
    const { error } = item.id
      ? await supabase.from('clients').update(payload).eq('id', item.id)
      : await supabase.from('clients').insert({ ...payload, org_id: org.id })
    setBusy(false)
    if (error) setErr(error.message); else onSaved()
  }

  return (
    <form onSubmit={save} className="card form">
      <h3>{item.id ? 'Edit company' : 'Add company'}</h3>
      <label>Name<input required value={f.name} onChange={set('name')} /></label>
      <label>CIN / LLPIN (optional)<input value={f.cin_or_llpin || ''} onChange={set('cin_or_llpin')} /></label>
      <label>Entity type<select value={f.entity_type} onChange={set('entity_type')}>{ENTITY_TYPES.map(t => <option key={t}>{t}</option>)}</select></label>
      <label>Financial year ends in<select value={f.fy_end_month} onChange={set('fy_end_month')}>{MONTHS.map((m, i) => <option key={m} value={i + 1}>{m}</option>)}</select></label>
      <label>State (for state-level laws)<input value={f.state || ''} onChange={set('state')} placeholder="e.g. Haryana" /></label>
      <div className="row"><button disabled={busy}>Save</button><button type="button" className="ghost" onClick={onClose}>Cancel</button></div>
      {err && <p className="err">{err}</p>}
    </form>
  )
}

const STATUS = ['upcoming', 'in_progress', 'filed', 'not_applicable', 'waived']

function Deadlines({ org }) {
  const [rows, setRows] = useState([])
  const [err, setErr] = useState('')
  const [show, setShow] = useState('open')

  async function load() {
    const { data, error } = await supabase.from('obligations')
      .select('id,period_label,due_date,status,filed_on,reference_no,clients(name),rule_versions(due_text,rules(rule_key,form,title))')
      .eq('org_id', org.id).order('due_date')
    if (error) setErr(error.message); else { setErr(''); setRows(data) }
  }
  useEffect(() => { load() }, [org.id])

  async function setStatus(o, status) {
    const patch = { status, filed_on: status === 'filed' ? new Date().toISOString().slice(0, 10) : null }
    const { error } = await supabase.from('obligations').update(patch).eq('id', o.id)
    if (error) setErr(error.message); else load()
  }

  const today = new Date().toISOString().slice(0, 10)
  const list = rows.filter(r => show === 'all' || ['upcoming', 'in_progress'].includes(r.status))

  return (
    <section>
      <div className="row"><h3>Deadlines</h3>
        <select value={show} onChange={e => setShow(e.target.value)}><option value="open">Open</option><option value="all">All</option></select></div>
      {err && <p className="err">{err}</p>}
      {!rows.length && (
        <div className="warn">No deadlines yet. Deadlines appear here once compliance rules have been verified and approved by the platform's reviewers. Until then nothing is shown, so you never see an unverified date.</div>
      )}
      <ul className="dl">
        {list.map(o => {
          const r = o.rule_versions?.rules
          const overdue = o.due_date < today && ['upcoming', 'in_progress'].includes(o.status)
          return (
            <li key={o.id} className={overdue ? 'over' : ''}>
              <div><b>{r?.form || r?.rule_key}</b> — {r?.title}<div className="muted">{o.clients?.name} · {o.period_label}</div></div>
              <div><b>{o.due_date}</b>{overdue && <span className="chip conflict">overdue</span>}</div>
              <select value={o.status} onChange={e => setStatus(o, e.target.value)}>{STATUS.map(s => <option key={s} value={s}>{s.replace(/_/g, ' ')}</option>)}</select>
            </li>
          )
        })}
      </ul>
    </section>
  )
}
