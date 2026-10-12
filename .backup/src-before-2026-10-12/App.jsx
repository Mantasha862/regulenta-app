import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import Login from './Login.jsx'
import Admin from './Admin.jsx'
import Workspace from './Workspace.jsx'

export default function App() {
  const [session, setSession] = useState(undefined)
  const [roles, setRoles] = useState(null)
  const [view, setView] = useState('workspace')

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

  if (session === undefined) return <div className="center">Loading…</div>
  if (!session) return <Login />
  if (roles === null) return <div className="center">Checking access…</div>

  const staff = roles.length > 0
  return (
    <div className="shell">
      <header className="top">
        <strong>REGULENTA AI</strong>
        {staff && (
          <nav className="tabs">
            <button className={view === 'workspace' ? '' : 'ghost'} onClick={() => setView('workspace')}>Workspace</button>
            <button className={view === 'admin' ? '' : 'ghost'} onClick={() => setView('admin')}>Admin console</button>
          </nav>
        )}
        <span className="muted">{session.user.email}{staff ? ` · ${roles.join(', ')}` : ''}</span>
        <button className="ghost" onClick={() => supabase.auth.signOut()}>Sign out</button>
      </header>
      {staff && view === 'admin' ? <Admin roles={roles} /> : <Workspace user={session.user} />}
    </div>
  )
}
