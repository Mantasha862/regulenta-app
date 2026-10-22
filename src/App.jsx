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

function Ic({ name, className = '' }) {
  return <i className={`ic i-${name} ${className}`} aria-hidden="true" />
}

function ThemeToggle() {
  const [theme, setTheme] = useState(() => document.documentElement.getAttribute('data-theme') || 'light')
  function toggle() {
    const next = theme === 'dark' ? 'light' : 'dark'
    document.documentElement.setAttribute('data-theme', next)
    setTheme(next)
    try { localStorage.setItem('regulenta-theme', next) } catch {}
  }
  return <button className="btn icon sm" aria-label="Switch theme" onClick={toggle}><Ic name={theme === 'dark' ? 'sun' : 'moon'} /></button>
}

export default function App() {
  useEffect(() => {
    try { const t = localStorage.getItem('regulenta-theme'); if (t) document.documentElement.setAttribute('data-theme', t) } catch {}
  }, [])

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

  if (verifyToken) return <div className="app"><VerifyEmail token={verifyToken} /></div>
  if (session === undefined) return <div className="app"><div className="center">Loading…</div></div>
  if (!session) return <div className="app"><Login /></div>
  if (roles === null) return <div className="app"><div className="center">Checking access…</div></div>
  return <div className="app"><Shell session={session} roles={roles} deepObligation={params.get('obligation')} /></div>
}

function NavItem({ icon, label, count, active, onClick }) {
  return (
    <button className="nav" aria-current={active ? 'page' : undefined} onClick={onClick}>
      <Ic name={icon} />
      {label}
      {count ? <span className="cnt">{count}</span> : null}
    </button>
  )
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

  const initials = (session.user.email || '').split('@')[0].split('.').map(s => s[0]?.toUpperCase()).join('').slice(0, 2)

  const navItems = [
    { key: 'dashboard', icon: 'grid', label: 'Workspace' },
    { key: 'companies', icon: 'building', label: 'Companies' },
    { key: 'compliance', icon: 'shield', label: 'Compliance' },
    { key: 'notifications', icon: 'bell', label: 'Notifications', count: unread || null },
    { key: 'settings', icon: 'sliders', label: 'Settings' },
  ]
  const staffItems = [
    { key: 'review', icon: 'search', label: 'Review queue' },
    { key: 'regintel', icon: 'gavel', label: 'Regulatory intelligence' },
    { key: 'health', icon: 'book', label: 'Delivery health' },
  ]

  let body
  if (orgs === null) body = <div className="center" style={{ minHeight: '60vh' }}>Loading…</div>
  else if (!orgs.length && !staffItems.some(t => t.key === view)) body = <CreateOrg onDone={async id => { setOrgId(id); await loadOrgs() }} />
  else if (view === 'review') body = <Admin roles={roles} />
  else if (view === 'regintel') body = <RegIntel roles={roles} />
  else if (view === 'health') body = <Health />
  else if (!org) body = <div className="center" style={{ minHeight: '60vh' }}>Select an organisation.</div>
  else if (view === 'dashboard') body = <Dashboard org={org} isAdmin={isAdmin} go={go} />
  else if (view === 'companies') body = <Companies org={org} isAdmin={isAdmin} go={go} />
  else if (view === 'compliance') body = <Compliance org={org} isAdmin={isAdmin} user={session.user} filter={filter} setFilter={setFilter} />
  else if (view === 'notifications') body = <Notifications org={org} go={go} onChange={() => setView('notifications')} />
  else if (view === 'settings') body = <Settings org={org} isAdmin={isAdmin} />

  const topTitle = view === 'dashboard' ? 'Workspace'
    : view === 'companies' ? 'Companies'
    : view === 'compliance' ? 'Compliance'
    : view === 'notifications' ? 'Notifications'
    : view === 'settings' ? 'Settings'
    : view === 'review' ? 'Review queue'
    : view === 'regintel' ? 'Regulatory intelligence'
    : view === 'health' ? 'Delivery health' : ''
  const topSub = view === 'dashboard' ? new Date().toLocaleDateString('en-IN', { weekday: 'long', day: '2-digit', month: '2-digit', year: 'numeric' }) + ' · all times IST' : null

  return (
    <div className="shell">
      {/* ─── sidebar (desktop) ─── */}
      <aside className="side" style={{ gap: 6 }}>
        <div className="brandmark" style={{ padding: '6px 8px 14px' }}>
          <b>REGULENTA</b>
        </div>
        {orgs?.length > 1 && (
          <button className="btn" style={{ justifyContent: 'space-between', width: '100%', marginBottom: 10 }}>
            <span className="row g8"><Ic name="building" />{org?.name || 'Select org'}</span>
            <Ic name="down" />
          </button>
        )}
        {orgs?.length > 1 && (
          <select className="orgsel" value={orgId || ''} onChange={e => setOrgId(e.target.value)} style={{ marginBottom: 10, width: '100%' }}>
            {orgs.map(o => <option key={o.id} value={o.id}>{o.name}</option>)}
          </select>
        )}

        {orgs?.length > 0 && navItems.map(n => (
          <NavItem key={n.key} icon={n.icon} label={n.label} count={n.count} active={view === n.key} onClick={() => go(n.key)} />
        ))}

        {staff && <div className="sf">Staff</div>}
        {staff && staffItems.map(n => (
          <NavItem key={n.key} icon={n.icon} label={n.label} active={view === n.key} onClick={() => go(n.key)} />
        ))}

        <div style={{ flex: 1 }} />

        <div className="row g12" style={{ padding: '10px 8px', borderTop: '1px solid var(--line)', marginTop: 12 }}>
          <div className="avatar">{initials}</div>
          <div>
            <div style={{ fontWeight: 600, fontSize: 14 }}>{session.user.email?.split('@')[0]}</div>
            <div className="t-xs faint">{myRole || 'member'}{staff ? ` · staff` : ''}</div>
            {orgs?.length === 1 && <div className="t-xs faint">{orgs[0].name}</div>}
          </div>
        </div>
        <button className="btn sm" onClick={() => supabase.auth.signOut()}>Sign out</button>
      </aside>

      {/* ─── main area ─── */}
      <main className="main">
        <div className="top" style={{ justifyContent: 'space-between' }}>
          <div>
            <h1 className="t-h1">{topTitle}</h1>
            {topSub && <div className="t-sm faint">{topSub}</div>}
          </div>
          <div className="row g8">
            <ThemeToggle />
            {view === 'dashboard' && <button className="btn primary sm hide-m" onClick={() => go('companies')}><Ic name="plus" />Add client</button>}
          </div>
        </div>
        <div className="page" style={{ padding: 20, flex: 1 }}>{body}</div>
      </main>

      {/* ─── bottom tabbar (mobile) ─── */}
      <nav className="tabbar" aria-label="Main">
        <button aria-current={view === 'dashboard' ? 'page' : undefined} onClick={() => go('dashboard')}><Ic name="grid" className="ic-lg" />Workspace</button>
        <button aria-current={view === 'companies' ? 'page' : undefined} onClick={() => go('companies')}><Ic name="building" className="ic-lg" />Companies</button>
        <button aria-current={view === 'compliance' ? 'page' : undefined} onClick={() => go('compliance')}><Ic name="shield" className="ic-lg" />Compliance</button>
        {staff
          ? <button aria-current={['review', 'regintel', 'health'].includes(view) ? 'page' : undefined} onClick={() => go('review')}><Ic name="eye" className="ic-lg" />Staff</button>
          : <button aria-current={view === 'notifications' ? 'page' : undefined} onClick={() => go('notifications')}><Ic name="bell" className="ic-lg" />Alerts</button>
        }
      </nav>
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
