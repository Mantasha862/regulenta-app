import { useState } from 'react'
import { supabase } from './supabase'

export default function Login() {
  const [mode, setMode] = useState('in')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [msg, setMsg] = useState('')
  const [busy, setBusy] = useState(false)

  async function submit(e) {
    e.preventDefault()
    setBusy(true); setMsg('')
    const fn = mode === 'in'
      ? supabase.auth.signInWithPassword({ email, password })
      : supabase.auth.signUp({ email, password })
    const { error, data } = await fn
    setBusy(false)
    if (error) setMsg(error.message)
    else if (mode === 'up' && !data.session) setMsg('Check your email to confirm your account, then sign in.')
  }

  return (
    <main className="login">
      <form onSubmit={submit} className="card">
        <h1>REGULENTA AI</h1>
        <p className="muted">Compliance tracking for CS and law firms</p>
        <label>Email<input type="email" required value={email} onChange={e => setEmail(e.target.value)} autoComplete="email" /></label>
        <label>Password<input type="password" required minLength={8} value={password} onChange={e => setPassword(e.target.value)} autoComplete={mode === 'in' ? 'current-password' : 'new-password'} /></label>
        <button disabled={busy}>{mode === 'in' ? 'Sign in' : 'Create account'}</button>
        {msg && <p className="err">{msg}</p>}
        <button type="button" className="link" onClick={() => { setMode(mode === 'in' ? 'up' : 'in'); setMsg('') }}>
          {mode === 'in' ? 'New here? Create an account' : 'Have an account? Sign in'}
        </button>
      </form>
    </main>
  )
}
