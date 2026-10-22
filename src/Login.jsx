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
    let res
    if (mode === 'in') res = await supabase.auth.signInWithPassword({ email, password })
    else if (mode === 'up') res = await supabase.auth.signUp({ email, password })
    else res = await supabase.auth.resetPasswordForEmail(email, { redirectTo: window.location.origin })
    setBusy(false)
    if (res.error) setMsg(res.error.message)
    else if (mode === 'up' && !res.data.session) setMsg('Check your email to confirm your account, then sign in.')
    else if (mode === 'reset') setMsg('If an account exists for this email, a reset link has been sent.')
  }

  return (
    <main className="login">
      <form onSubmit={submit} className="card">
        <div className="brandmark" style={{ justifyContent: 'center', padding: '0 0 8px' }}><b>REGULENTA</b></div>
        <p className="muted" style={{ textAlign: 'center' }}>Compliance tracking for company secretaries, law firms and companies</p>
        <label>Email<input type="email" required value={email} onChange={e => setEmail(e.target.value)} autoComplete="email" /></label>
        {mode !== 'reset' && <label>Password<input type="password" required minLength={8} value={password} onChange={e => setPassword(e.target.value)} autoComplete={mode === 'in' ? 'current-password' : 'new-password'} /></label>}
        <button disabled={busy}>{mode === 'in' ? 'Sign in' : mode === 'up' ? 'Create account' : 'Send reset link'}</button>
        {msg && <p className="err">{msg}</p>}
        <div className="row">
          <button type="button" className="link" onClick={() => { setMode(mode === 'in' ? 'up' : 'in'); setMsg('') }}>
            {mode === 'in' ? 'New here? Create an account' : 'Have an account? Sign in'}
          </button>
          {mode === 'in' && <button type="button" className="link" onClick={() => { setMode('reset'); setMsg('') }}>Forgot password?</button>}
        </div>
      </form>
    </main>
  )
}
