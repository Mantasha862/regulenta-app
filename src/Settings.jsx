import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import { useLoad, must, fmtDateTime, humanError } from './lib.js'

const LEVELS = [[0, 'First reminders (owner)'], [1, 'Escalation 1 (compliance officer)'], [2, 'Escalation 2 (management)']]
const parseList = s => s.split(',').map(x => x.trim()).filter(Boolean).map(Number)

export default function Settings({ org, isAdmin }) {
  const data = useLoad(async () => {
    const [rs, clients, recips, contacts, members, fails] = await Promise.all([
      supabase.from('reminder_settings').select('*').eq('org_id', org.id),
      supabase.from('clients').select('id,name').eq('org_id', org.id).is('archived_at', null).order('name'),
      supabase.from('notification_recipients').select('*,client_contacts(full_name,email,email_verified_at,notify_email),clients(name)').eq('org_id', org.id),
      supabase.from('client_contacts').select('id,full_name,email,client_id,email_verified_at,notify_email,active').eq('org_id', org.id),
      supabase.rpc('org_member_directory', { p_org: org.id }),
      isAdmin ? supabase.from('notification_deliveries').select('id,status,email_snapshot,last_error,updated_at,attempts').eq('org_id', org.id)
        .in('status', ['failed', 'bounced']).order('updated_at', { ascending: false }).limit(20) : Promise.resolve({ data: [] }),
    ])
    for (const r of [rs, clients, recips, contacts, members, fails]) if (r.error) throw new Error(r.error.message)
    return { rs: rs.data, clients: clients.data, recips: recips.data, contacts: contacts.data, members: members.data, fails: fails.data }
  }, [org.id, isAdmin])
  if (data.loading && !data.data) return <p className="muted">Loading…</p>
  if (data.error) return <p className="err">{data.error}</p>
  const v = data.data
  return (
    <section>
      <h2>Reminders &amp; recipients</h2>
      {!isAdmin && <p className="warn">Only organisation admins can change these settings.</p>}
      <Schedule org={org} row={v.rs.find(r => !r.client_id)} isAdmin={isAdmin} onSaved={data.reload} />
      <Recipients org={org} v={v} isAdmin={isAdmin} onSaved={data.reload} />
      {isAdmin && (
        <>
          <h3>Email delivery problems</h3>
          <ul className="simple small">{v.fails.map(f => <li key={f.id}><span className="chip conflict">{f.status}</span> {f.email_snapshot} · {f.last_error} · {fmtDateTime(f.updated_at)}</li>)}
            {!v.fails.length && <li className="muted">No failed or bounced emails.</li>}</ul>
        </>)}
    </section>
  )
}

function Schedule({ org, row, isAdmin, onSaved }) {
  const def = { offsets: [30, 15, 7, 3, 1], overdue_offsets: [1, 3], escalate_after_days: 7, escalate_level2_after_days: 14, repeat_every_days: 7, channels: ['in_app', 'email'], email_enabled: false }
  const [f, setF] = useState({ ...def, ...(row || {}) })
  const [msg, setMsg] = useState('')
  useEffect(() => { setF({ ...def, ...(row || {}) }) }, [row?.id])
  async function save(e) {
    e.preventDefault(); setMsg('')
    const p = { org_id: org.id, client_id: null, offsets: f.offsets, overdue_offsets: f.overdue_offsets, escalate_after_days: Number(f.escalate_after_days),
      escalate_level2_after_days: Number(f.escalate_level2_after_days), repeat_every_days: Number(f.repeat_every_days), channels: f.channels, email_enabled: f.email_enabled }
    const { error } = row ? await supabase.from('reminder_settings').update(p).eq('id', row.id) : await supabase.from('reminder_settings').insert(p)
    setMsg(error ? humanError(error.message) : 'Saved.'); if (!error) onSaved()
  }
  const ch = c => f.channels.includes(c)
  return (
    <form onSubmit={save} className="form wide">
      <h3>Reminder schedule (all companies)</h3>
      <fieldset disabled={!isAdmin}>
        <div className="fields">
          <label>Days before the due date<input value={f.offsets.join(', ')} onChange={e => setF({ ...f, offsets: parseList(e.target.value) })} /></label>
          <label>Days overdue (before escalation)<input value={f.overdue_offsets.join(', ')} onChange={e => setF({ ...f, overdue_offsets: parseList(e.target.value) })} /></label>
          <label>Escalate after (days overdue)<input type="number" min="1" value={f.escalate_after_days} onChange={e => setF({ ...f, escalate_after_days: e.target.value })} /></label>
          <label>Escalate to management after (days)<input type="number" min="2" value={f.escalate_level2_after_days} onChange={e => setF({ ...f, escalate_level2_after_days: e.target.value })} /></label>
          <label>Then repeat every (days)<input type="number" min="1" value={f.repeat_every_days} onChange={e => setF({ ...f, repeat_every_days: e.target.value })} /></label>
          <label className="inline"><input type="checkbox" checked={ch('in_app')} onChange={e => setF({ ...f, channels: e.target.checked ? [...new Set([...f.channels, 'in_app'])] : f.channels.filter(c => c !== 'in_app') })} /> In-app notifications</label>
          <label className="inline"><input type="checkbox" checked={ch('email')} onChange={e => setF({ ...f, channels: e.target.checked ? [...new Set([...f.channels, 'email'])] : f.channels.filter(c => c !== 'email') })} /> Email reminders</label>
          <label className="inline span2"><input type="checkbox" checked={f.email_enabled} onChange={e => setF({ ...f, email_enabled: e.target.checked })} />
            <b>Switch on email delivery for this organisation</b> (until this is on, email reminders are recorded but not sent)</label>
        </div>
        <p className="muted small">Defaults: 30, 15, 7, 3 and 1 days before; on the due date; 1 and 3 days overdue; escalation at 7 days; management at 14 days; then every 7 days until resolved.
          Reminders stop when an item is closed, cancelled or marked not applicable. Statutory due dates are never moved for weekends or holidays unless the approved rule says so.</p>
        {isAdmin && <button>Save schedule</button>}
      </fieldset>
      {msg && <p className="muted">{msg}</p>}
    </form>
  )
}

function Recipients({ org, v, isAdmin, onSaved }) {
  const [f, setF] = useState({ who: '', client_id: '', escalation_level: 0, email: true, in_app: true })
  const [msg, setMsg] = useState('')
  const contactsFor = v.contacts.filter(k => k.active && (!f.client_id || k.client_id === f.client_id))
  async function add(e) {
    e.preventDefault(); setMsg('')
    const [kind, id] = f.who.split(':')
    const channels = [f.email && 'email', f.in_app && 'in_app'].filter(Boolean)
    const row = { org_id: org.id, client_id: f.client_id || null, escalation_level: Number(f.escalation_level), channels,
      ...(kind === 'u' ? { user_id: id } : { contact_id: id }) }
    const { error } = await supabase.from('notification_recipients').insert(row)
    setMsg(error ? (/duplicate|unique/.test(error.message) ? 'Already a recipient for that scope.' : humanError(error.message)) : 'Recipient added.'); if (!error) onSaved()
  }
  async function toggle(r) { const { error } = await supabase.from('notification_recipients').update({ active: !r.active }).eq('id', r.id); if (error) setMsg(humanError(error.message)); onSaved() }
  async function remove(r) { const { error } = await supabase.from('notification_recipients').delete().eq('id', r.id); if (error) setMsg(humanError(error.message)); onSaved() }
  const who = r => r.user_id ? (v.members.find(m => m.user_id === r.user_id)?.email || 'member') : `${r.client_contacts?.full_name} <${r.client_contacts?.email}>`
  const status = r => r.user_id ? 'team member' : !r.client_contacts?.notify_email ? 'not opted in: no emails' : !r.client_contacts?.email_verified_at ? 'email not verified: no emails' : 'verified'
  return (
    <div>
      <h3>Who receives reminders</h3>
      <p className="muted small">Only the people listed here receive reminders (plus the person assigned to an item). External contacts receive email only after opting in and confirming their address. Escalation levels receive reminders only once an item is overdue past the escalation point.</p>
      <table className="tbl"><thead><tr><th>Recipient</th><th>Company</th><th>Level</th><th>Channels</th><th>Status</th><th /></tr></thead>
        <tbody>{v.recips.map(r => (
          <tr key={r.id} className={r.active ? '' : 'dim'}><td>{who(r)}</td><td>{r.clients?.name || 'All companies'}</td><td>{LEVELS[r.escalation_level][1]}</td>
            <td>{r.channels.join(', ')}</td><td className="small">{status(r)}</td>
            <td>{isAdmin && <><button className="ghost" onClick={() => toggle(r)}>{r.active ? 'Pause' : 'Resume'}</button><button className="ghost" onClick={() => remove(r)}>Remove</button></>}</td></tr>))}
          {!v.recips.length && <tr><td colSpan="6" className="muted">No recipients configured. Reminders are shown in-app to the whole organisation until you add some.</td></tr>}</tbody></table>
      {isAdmin && (
        <form onSubmit={add} className="form wide">
          <div className="fields">
            <label>Company<select value={f.client_id} onChange={e => setF({ ...f, client_id: e.target.value, who: '' })}><option value="">All companies</option>{v.clients.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
            <label>Person<select required value={f.who} onChange={e => setF({ ...f, who: e.target.value })}><option value="">Choose…</option>
              <optgroup label="Team members">{v.members.map(m => <option key={m.user_id} value={`u:${m.user_id}`}>{m.email} ({m.role})</option>)}</optgroup>
              <optgroup label="Company contacts">{contactsFor.map(k => <option key={k.id} value={`k:${k.id}`}>{k.full_name} &lt;{k.email}&gt;{k.email_verified_at ? '' : ' (unverified)'}</option>)}</optgroup></select></label>
            <label>Level<select value={f.escalation_level} onChange={e => setF({ ...f, escalation_level: e.target.value })}>{LEVELS.map(([n, l]) => <option key={n} value={n}>{l}</option>)}</select></label>
            <label className="inline"><input type="checkbox" checked={f.email} onChange={e => setF({ ...f, email: e.target.checked })} /> Email</label>
            <label className="inline"><input type="checkbox" checked={f.in_app} onChange={e => setF({ ...f, in_app: e.target.checked })} /> In-app (team members only)</label>
          </div>
          <button>Add recipient</button>
        </form>)}
      {msg && <p className="muted">{msg}</p>}
    </div>
  )
}
