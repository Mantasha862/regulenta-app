import { useState } from 'react'
import { supabase } from './supabase'
import { useLoad, must, fmtDate, fmtDateTime, humanError, today } from './lib.js'

const ENTITY_TYPES = ['Private Limited Company', 'Public Limited Company (Unlisted)', 'Listed Company', 'One Person Company', 'LLP', 'Section 8 Company', 'Partnership / Proprietorship', 'Other']
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
const ROLES = [['compliance_owner', 'Compliance owner'], ['company_admin', 'Company administrator'], ['company_secretary', 'Company secretary'],
  ['compliance_officer', 'Compliance officer'], ['reviewer', 'Reviewer / approver'], ['management', 'Management contact'], ['other', 'Other']]
// Facts the applicability engine can test (rule conditions refer to these keys). Unknown facts stay blank, never guessed.
const FACTS = [['listed', 'Listed on a stock exchange', 'bool'], ['gst_registered', 'GST registered', 'bool'], ['employees', 'Number of employees', 'number'],
  ['paid_up_capital', 'Paid-up capital (₹)', 'number'], ['turnover', 'Turnover, last FY (₹)', 'number'], ['foreign_investment', 'Has foreign investment', 'bool'],
  ['nbfc', 'Registered NBFC', 'bool'], ['state', 'State of registered office', 'text']]

export default function Companies({ org, isAdmin, go }) {
  const [sel, setSel] = useState(null)
  const [editing, setEditing] = useState(null)
  const list = useLoad(async () => must(await supabase.from('clients').select('*').eq('org_id', org.id).is('archived_at', null).order('name')), [org.id])
  const current = list.data?.find(c => c.id === sel)

  return (
    <div className="split">
      <aside className="list">
        <div className="row"><h3>Companies ({list.data?.length ?? 0})</h3><button onClick={() => { setEditing({}); setSel(null) }}>+ Add</button></div>
        {list.error && <p className="err">{list.error}</p>}
        <ul>{list.data?.map(c => (
          <li key={c.id} className={c.id === sel ? 'on' : ''} onClick={() => { setSel(c.id); setEditing(null) }}>
            <b>{c.name}</b><div className="muted small">{c.entity_type}{c.cin_or_llpin ? ` · ${c.cin_or_llpin}` : ''}</div>
          </li>))}
          {list.data && !list.data.length && <li className="muted">No companies yet.</li>}
        </ul>
      </aside>
      <section className="detail">
        {editing && <CompanyForm org={org} item={editing} onClose={() => setEditing(null)} onSaved={id => { setEditing(null); list.reload(); setSel(id) }} />}
        {!editing && current && <CompanyDetail key={current.id} org={org} c={current} isAdmin={isAdmin} go={go}
          onEdit={() => setEditing(current)} onChanged={list.reload} />}
        {!editing && !current && <p className="muted">Select a company or add one.</p>}
      </section>
    </div>
  )
}

function CompanyForm({ org, item, onClose, onSaved }) {
  const [f, setF] = useState({ name: '', cin_or_llpin: '', entity_type: ENTITY_TYPES[0], fy_end_month: 3, state: '', incorporation_date: '',
    registered_office: '', industry: '', listed: null, timezone: 'Asia/Kolkata', ...item })
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)
  const set = k => e => setF({ ...f, [k]: e.target.value })
  async function save(e) {
    e.preventDefault(); setBusy(true); setErr('')
    const cin = f.cin_or_llpin?.trim().toUpperCase() || null
    const payload = { name: f.name.trim(), cin_or_llpin: cin, entity_type: f.entity_type, fy_end_month: Number(f.fy_end_month),
      state: f.state?.trim() || null, incorporation_date: f.incorporation_date || null, registered_office: f.registered_office?.trim() || null,
      industry: f.industry?.trim() || null, timezone: f.timezone || 'Asia/Kolkata',
      listed: f.listed === '' || f.listed === null ? null : f.listed === true || f.listed === 'true' }
    const res = item.id
      ? await supabase.from('clients').update(payload).eq('id', item.id).select('id').single()
      : await supabase.from('clients').insert({ ...payload, org_id: org.id }).select('id').single()
    setBusy(false)
    if (res.error) setErr(/cin_format/.test(res.error.message) ? 'CIN must be 21 characters (e.g. U74999HR2015PTC012345) and LLPIN like AAA-1234.' : humanError(res.error.message))
    else onSaved(res.data.id)
  }
  return (
    <form onSubmit={save} className="form wide">
      <h3>{item.id ? 'Edit company' : 'Add company'}</h3>
      <div className="fields">
        <label>Legal name<input required value={f.name} onChange={set('name')} /></label>
        <label>CIN / LLPIN<input value={f.cin_or_llpin || ''} onChange={set('cin_or_llpin')} placeholder="Leave blank if not known" /></label>
        <label>Entity type<select value={f.entity_type} onChange={set('entity_type')}>{ENTITY_TYPES.map(t => <option key={t}>{t}</option>)}</select></label>
        <label>Incorporation date<input type="date" value={f.incorporation_date || ''} onChange={set('incorporation_date')} /></label>
        <label>Financial year ends in<select value={f.fy_end_month} onChange={set('fy_end_month')}>{MONTHS.map((m, i) => <option key={m} value={i + 1}>{m}</option>)}</select></label>
        <label>State (registered office)<input value={f.state || ''} onChange={set('state')} placeholder="e.g. Haryana" /></label>
        <label className="span2">Registered office address<input value={f.registered_office || ''} onChange={set('registered_office')} /></label>
        <label>Industry / business activity<input value={f.industry || ''} onChange={set('industry')} /></label>
        <label>Listed?<select value={f.listed === null ? '' : String(f.listed)} onChange={set('listed')}><option value="">Not known</option><option value="true">Yes</option><option value="false">No</option></select></label>
      </div>
      <div className="row"><button disabled={busy}>Save</button><button type="button" className="ghost" onClick={onClose}>Cancel</button></div>
      {err && <p className="err">{err}</p>}
    </form>
  )
}

function CompanyDetail({ org, c, isAdmin, go, onEdit, onChanged }) {
  const [tab, setTab] = useState('profile')
  async function archive() {
    const { error } = await supabase.from('clients').update({ archived_at: new Date().toISOString() }).eq('id', c.id)
    if (!error) onChanged()
  }
  return (
    <div>
      <div className="row"><h2>{c.name}</h2>
        <div className="row"><button className="ghost" onClick={onEdit}>Edit details</button>{isAdmin && <Confirm label="Archive" onYes={archive} text="Hide this company? Its records are kept." />}</div></div>
      <p className="muted">{c.entity_type}{c.cin_or_llpin ? ` · ${c.cin_or_llpin}` : ''} · FY ends {MONTHS[c.fy_end_month - 1]}{c.state ? ` · ${c.state}` : ''}{c.incorporation_date ? ` · incorporated ${fmtDate(c.incorporation_date)}` : ''}</p>
      <nav className="subtabs">{[['profile', 'Applicability facts'], ['contacts', 'Contacts'], ['deadlines', 'Generate deadlines'], ['events', 'Record an event']].map(([k, l]) =>
        <button key={k} aria-selected={tab === k} onClick={() => setTab(k)}>{l}</button>)}</nav>
      {tab === 'profile' && <Facts c={c} onSaved={onChanged} />}
      {tab === 'contacts' && <Contacts org={org} c={c} isAdmin={isAdmin} />}
      {tab === 'deadlines' && <Generate c={c} isAdmin={isAdmin} go={go} />}
      {tab === 'events' && <Events c={c} />}
    </div>
  )
}

function Facts({ c, onSaved }) {
  const [p, setP] = useState(c.profile || {})
  const [msg, setMsg] = useState('')
  async function save() {
    const clean = Object.fromEntries(Object.entries(p).filter(([, v]) => v !== '' && v !== null && v !== undefined))
    const { error } = await supabase.from('clients').update({ profile: clean }).eq('id', c.id)
    setMsg(error ? humanError(error.message) : 'Saved.'); if (!error) onSaved()
  }
  return (
    <div className="form wide">
      <p className="muted">These facts decide which approved rules apply. Leave a fact blank if you do not know it: rules that depend on it are shown as "review required", never assumed.</p>
      <div className="fields">
        {FACTS.map(([k, label, type]) => (
          <label key={k}>{label}
            {type === 'bool'
              ? <select value={p[k] === undefined ? '' : String(p[k])} onChange={e => setP({ ...p, [k]: e.target.value === '' ? undefined : e.target.value === 'true' })}>
                  <option value="">Not known</option><option value="true">Yes</option><option value="false">No</option></select>
              : <input type={type === 'number' ? 'number' : 'text'} min="0" value={p[k] ?? ''} onChange={e => setP({ ...p, [k]: e.target.value === '' ? undefined : type === 'number' ? Number(e.target.value) : e.target.value })} />}
          </label>))}
      </div>
      <div className="row"><button onClick={save}>Save facts</button>{msg && <span className="muted">{msg}</span>}</div>
    </div>
  )
}

function Contacts({ org, c, isAdmin }) {
  const list = useLoad(async () => must(await supabase.from('client_contacts').select('*').eq('client_id', c.id).order('full_name')), [c.id])
  const [f, setF] = useState({ full_name: '', email: '', role: 'compliance_owner', designation: '', notify_email: false })
  const [msg, setMsg] = useState('')
  async function add(e) {
    e.preventDefault(); setMsg('')
    const { error } = await supabase.from('client_contacts').insert({ ...f, email: f.email.trim().toLowerCase(), full_name: f.full_name.trim(), org_id: org.id, client_id: c.id })
    if (error) setMsg(/unique/.test(error.message) ? 'This email is already a contact for this company.' : humanError(error.message))
    else { setF({ full_name: '', email: '', role: 'compliance_owner', designation: '', notify_email: false }); list.reload() }
  }
  async function verify(k) {
    setMsg('Sending verification email…')
    const { data, error } = await supabase.functions.invoke('request-contact-verification', { body: { contact_id: k.id } })
    setMsg(error ? `Could not send: ${error.message}. Email delivery may not be configured yet.` : data?.sent ? `Verification email sent to ${k.email}.` : 'Not sent.')
    list.reload()
  }
  async function patch(k, p) { const { error } = await supabase.from('client_contacts').update(p).eq('id', k.id); if (error) setMsg(humanError(error.message)); list.reload() }
  return (
    <div>
      <p className="muted">Contacts receive reminder emails only if an organisation admin opts them in <b>and</b> they confirm their email address.
        Being listed (for example as a director) never authorises emails by itself. Choose who receives which reminders under "Reminders &amp; recipients".</p>
      <table className="tbl"><thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Emails</th><th>Verified</th><th /></tr></thead>
        <tbody>{list.data?.map(k => (
          <tr key={k.id} className={k.active ? '' : 'dim'}>
            <td>{k.full_name}<div className="muted small">{k.designation}</div></td><td>{k.email}</td>
            <td>{ROLES.find(r => r[0] === k.role)?.[1]}</td>
            <td>{isAdmin ? <label className="inline"><input type="checkbox" checked={k.notify_email} onChange={e => patch(k, { notify_email: e.target.checked })} /> opted in</label> : k.notify_email ? 'opted in' : 'off'}</td>
            <td>{k.email_verified_at ? fmtDateTime(k.email_verified_at) : k.verify_sent_at ? `sent ${fmtDateTime(k.verify_sent_at)}` : 'no'}</td>
            <td>{isAdmin && !k.email_verified_at && k.active && <button className="ghost" onClick={() => verify(k)}>Send verification</button>}
              {isAdmin && <button className="ghost" onClick={() => patch(k, { active: !k.active })}>{k.active ? 'Deactivate' : 'Activate'}</button>}</td>
          </tr>))}
          {list.data && !list.data.length && <tr><td colSpan="6" className="muted">No contacts yet.</td></tr>}</tbody></table>
      {isAdmin && (
        <form onSubmit={add} className="form wide">
          <h4>Add contact</h4>
          <div className="fields">
            <label>Full name<input required value={f.full_name} onChange={e => setF({ ...f, full_name: e.target.value })} /></label>
            <label>Email<input required type="email" value={f.email} onChange={e => setF({ ...f, email: e.target.value })} /></label>
            <label>Role<select value={f.role} onChange={e => setF({ ...f, role: e.target.value })}>{ROLES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
            <label>Designation (optional)<input value={f.designation} onChange={e => setF({ ...f, designation: e.target.value })} /></label>
            <label className="inline span2"><input type="checkbox" checked={f.notify_email} onChange={e => setF({ ...f, notify_email: e.target.checked })} /> This person agreed to receive reminder emails</label>
          </div>
          <button>Add contact</button>
        </form>)}
      {msg && <p className="muted">{msg}</p>}
    </div>
  )
}

function Generate({ c, isAdmin, go }) {
  const [from, setFrom] = useState(today())
  const [rows, setRows] = useState(null)
  const [msg, setMsg] = useState('')
  const proposed = useLoad(async () => must(await supabase.from('obligations').select('id,period_label,due_date,non_working_day,rule_versions(rules(form,title))')
    .eq('client_id', c.id).eq('lifecycle', 'proposed').order('due_date')), [c.id])
  async function preview(keepMsg) {
    if (!keepMsg) setMsg('')
    const { data, error } = await supabase.rpc('preview_obligations', { p_client: c.id, p_from: from })
    if (error) setMsg(humanError(error.message)); else setRows(data)
  }
  async function generate() {
    const { data, error } = await supabase.rpc('generate_obligations', { p_client: c.id, p_from: from })
    setMsg(error ? humanError(error.message) : `${data} proposed deadline(s) saved. Review them below, then activate.`)
    await preview(true); proposed.reload()
  }
  async function activate(ids) {
    const { data, error } = await supabase.rpc('activate_obligations', { p_client: c.id, p_ids: ids })
    setMsg(error ? humanError(error.message) : `${data} deadline(s) activated. Reminders now apply to them.`); proposed.reload()
  }
  async function discard() {
    const { data, error } = await supabase.rpc('discard_proposed_obligations', { p_client: c.id, p_ids: null })
    setMsg(error ? humanError(error.message) : `${data} proposed deadline(s) discarded.`); proposed.reload()
  }
  const counts = rows ? rows.reduce((a, r) => (a[r.action] = (a[r.action] || 0) + 1, a), {}) : {}
  return (
    <div>
      <p className="muted">Deadlines are calculated only from rules a reviewer has approved with primary-source evidence. Preview first; nothing is saved until you generate, and reminders start only after you activate.</p>
      <div className="row left"><label className="inline">From <input type="date" value={from} onChange={e => setFrom(e.target.value)} /></label>
        <button className="ghost" onClick={() => preview(false)}>Preview</button>
        {rows && counts.create > 0 && <button onClick={generate}>Save {counts.create} as proposed</button>}</div>
      {msg && <p className="muted">{msg}</p>}
      {rows && (
        <>
          <p className="small">Will create: {counts.create || 0} · Already tracked: {counts.exists || 0} · Review required: {counts.review_required || 0} · Skipped: {counts.skip || 0}</p>
          <table className="tbl"><thead><tr><th>Rule</th><th>Period</th><th>Due</th><th>Result</th><th>Reason</th></tr></thead>
            <tbody>{rows.map((r, i) => (
              <tr key={i} className={r.action === 'create' ? '' : 'dim'}><td><b>{r.rule_key}</b><div className="muted small">{r.title}</div></td><td>{r.period_label || '—'}</td>
                <td>{fmtDate(r.due_date)}{r.non_working_day && <span className="chip warnc" title="Not moved: verify any extension or holiday rule">non-working day</span>}</td>
                <td><span className={`chip ${r.action}`}>{r.action.replace('_', ' ')}</span></td><td className="small">{r.reason}</td></tr>))}
              {!rows.length && <tr><td colSpan="5" className="muted">No approved rules apply yet.</td></tr>}</tbody></table>
        </>)}
      <h4>Proposed (not yet active): {proposed.data?.length ?? 0}</h4>
      {proposed.data?.length > 0 && (
        <>
          <table className="tbl"><tbody>{proposed.data.map(o => <tr key={o.id}><td><b>{o.rule_versions?.rules?.form}</b> {o.rule_versions?.rules?.title}</td><td>{o.period_label}</td><td>{fmtDate(o.due_date)}</td></tr>)}</tbody></table>
          {isAdmin ? <div className="row left"><Confirm label="Activate all" primary text="Activate these deadlines? Reminders will start for them." onYes={() => activate(null)} />
            <Confirm label="Discard all" text="Discard all proposed deadlines for this company?" onYes={discard} /></div>
            : <p className="muted">An organisation admin needs to activate these.</p>}
        </>)}
      <p><button className="link" onClick={() => go('compliance')}>Open the compliance list</button></p>
    </div>
  )
}

function Events({ c }) {
  const rules = useLoad(async () => must(await supabase.from('rule_versions').select('id,due_text,schedule,rules(rule_key,form,title)')
    .eq('state', 'active').eq('schedule->>type', 'event_offset')), [])
  const [f, setF] = useState({ rule: '', date: '', note: '' })
  const [msg, setMsg] = useState('')
  async function submit(e) {
    e.preventDefault()
    const { error } = await supabase.rpc('create_event_obligation', { p_client: c.id, p_rule_key: f.rule, p_event_date: f.date, p_note: f.note || null })
    setMsg(error ? humanError(error.message) : 'Recorded. A proposed deadline was created: activate it under "Generate deadlines".')
  }
  return (
    <form onSubmit={submit} className="form wide">
      <p className="muted">Some deadlines run from an event, such as an AGM or an allotment. Record the event date to create the deadline.</p>
      <div className="fields">
        <label>Rule<select required value={f.rule} onChange={e => setF({ ...f, rule: e.target.value })}><option value="">Choose…</option>
          {rules.data?.map(r => <option key={r.id} value={r.rules.rule_key}>{r.rules.form} — {r.rules.title} ({r.due_text})</option>)}</select></label>
        <label>Event date<input required type="date" value={f.date} onChange={e => setF({ ...f, date: e.target.value })} /></label>
        <label className="span2">Note<input value={f.note} onChange={e => setF({ ...f, note: e.target.value })} /></label>
      </div>
      {rules.data && !rules.data.length && <p className="muted">No approved event-based rules yet.</p>}
      <button disabled={!f.rule || !f.date}>Record event</button>
      {msg && <p className="muted">{msg}</p>}
    </form>
  )
}

// in-page confirmation (no browser dialogs)
export function Confirm({ label, text, onYes, primary, danger }) {
  const [open, setOpen] = useState(false)
  if (!open) return <button className={primary ? '' : danger ? 'danger' : 'ghost'} onClick={() => setOpen(true)}>{label}</button>
  return <span className="confirm">{text} <button className={danger ? 'danger' : ''} onClick={() => { setOpen(false); onYes() }}>Yes</button><button className="ghost" onClick={() => setOpen(false)}>No</button></span>
}
