import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import Login from './Login.jsx'
import VerifyEmail from './VerifyEmail.jsx'
import Admin from './Admin.jsx'
import RegIntel from './RegIntel.jsx'
import Health from './Health.jsx'
import Dashboard from './Dashboard.jsx'
import Companies from './Companies.jsx'
import Compliance from './Compliance.jsx'
import Notifications from './Notifications.jsx'
import Settings from './Settings.jsx'
import { must } from './lib.js'

export default function App() {
  const params = new URLSearchParams(window.location.search)
  const verifyToken = params.get('verify_email')
  const [session, setSession] = useState(undefined)
  const [roles, setRoles] = useState(null)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session))
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => sub.subscription.unsubscribe()
  }, [])
  useEffect(() => {
    if (!session) { setRoles(null); return }
    supabase.from('platform_roles').select('role').eq('user_id', session.user.id)
      .then(({ data }) => setRoles((data || []).map(r => r.role)))
  }, [session])

  if (verifyToken) return <VerifyEmail token={verifyToken} />
  if (session === undefined) return <div className="center">Loading…</div>
  if (!session) return <Login />
  if (roles === null) return <div className="center">Checking access…</div>
  return <Shell session={session} roles={roles} deepObligation={params.get('obligation')} />
}

function Shell({ session, roles, deepObligation }) {
  const staff = roles.length > 0
  const [orgs, setOrgs] = useState(null)
  const [orgId, setOrgId] = useState(null)
  const [view, setView] = useState(deepObligation ? 'compliance' : 'dashboard')
  const [filter, setFilter] = useState(deepObligation ? { obligation: deepObligation } : {})
  const [unread, setUnread] = useState(0)
  const [myRole, setMyRole] = useState(null)

  async function loadOrgs() {
    const data = must(await supabase.from('orgs').select('id,name,type,plan').order('created_at'))
    setOrgs(data)
    if (data.length && !data.find(o => o.id === orgId)) setOrgId(data[0].id)
  }
  useEffect(() => { loadOrgs().catch(() => setOrgs([])) }, [])
  useEffect(() => {
    if (!orgId) return
    supabase.from('org_members').select('role').eq('org_id', orgId).eq('user_id', session.user.id).maybeSingle()
      .then(({ data }) => setMyRole(data?.role ?? null))
    const count = () => supabase.from('notifications').select('id', { count: 'exact', head: true }).eq('org_id', orgId).is('read_at', null)
      .then(({ count }) => setUnread(count || 0))
    count(); const t = setInterval(count, 60000); return () => clearInterval(t)
  }, [orgId, view])

  const isAdmin = ['owner', 'admin'].includes(myRole)
  const org = orgs?.find(o => o.id === orgId)
  const go = (v, f = {}) => { setFilter(f); setView(v) }

  const tabs = [
    ['dashboard', 'Dashboard'], ['companies', 'Companies'], ['compliance', 'Compliance'],
    ['notifications', `Notifications${unread ? ` (${unread})` : ''}`], ['settings', 'Reminders & recipients'],
  ]
  const staffTabs = [['review', 'Review queue'], ['regintel', 'Regulatory intelligence'], ['health', 'Delivery health']]

  let body
  if (orgs === null) body = <div className="center">Loading…</div>
  else if (!orgs.length && !staffTabs.some(t => t[0] === view)) body = <CreateOrg onDone={async id => { setOrgId(id); await loadOrgs() }} />
  else if (view === 'review') body = <Admin roles={roles} />
  else if (view === 'regintel') body = <RegIntel roles={roles} />
  else if (view === 'health') body = <Health />
  else if (!org) body = <div className="center">Select an organisation.</div>
  else if (view === 'dashboard') body = <Dashboard org={org} isAdmin={isAdmin} go={go} />
  else if (view === 'companies') body = <Companies org={org} isAdmin={isAdmin} go={go} />
  else if (view === 'compliance') body = <Compliance org={org} isAdmin={isAdmin} user={session.user} filter={filter} setFilter={setFilter} />
  else if (view === 'notifications') body = <Notifications org={org} go={go} onChange={() => setView('notifications')} />
  else if (view === 'settings') body = <Settings org={org} isAdmin={isAdmin} />

  return (
    <div className="shell">
      <header className="top">
        <strong className="brand">REGULENTA</strong>
        {orgs?.length > 1 && <select className="orgsel" value={orgId || ''} onChange={e => setOrgId(e.target.value)}>{orgs.map(o => <option key={o.id} value={o.id}>{o.name}</option>)}</select>}
        {orgs?.length === 1 && <span className="muted">{orgs[0].name}</span>}
        <span className="grow" />
        <span className="muted small">{session.user.email}{myRole ? ` · ${myRole}` : ''}{staff ? ` · staff: ${roles.join(', ')}` : ''}</span>
        <button className="ghost" onClick={() => supabase.auth.signOut()}>Sign out</button>
      </header>
      <nav className="nav">
        {orgs?.length > 0 && tabs.map(([k, l]) => <button key={k} className={view === k ? 'on' : 'ghost'} onClick={() => go(k)}>{l}</button>)}
        {staff && <span className="sep" />}
        {staff && staffTabs.map(([k, l]) => <button key={k} className={view === k ? 'on' : 'ghost'} onClick={() => go(k)}>{l}</button>)}
      </nav>
      <main className="page">{body}</main>
    </div>
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
    <div className="login">
      <form onSubmit={submit} className="card">
        <h2>Set up your workspace</h2>
        <p className="muted">The firm or company that will track compliance. You add client companies next.</p>
        <label>Name<input required value={name} onChange={e => setName(e.target.value)} /></label>
        <label>Type
          <select value={type} onChange={e => setType(e.target.value)}>
            <option value="firm">CS / law / accounting firm (manages several companies)</option>
            <option value="company">A single company (manages its own compliance)</option>
          </select>
        </label>
        <button disabled={busy || !name.trim()}>Create workspace</button>
        {err && <p className="err">{err}</p>}
      </form>
    </div>
  )
}
