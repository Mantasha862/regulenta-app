import { useEffect, useState } from 'react'
import { supabase } from './supabase'

// Public page: a company contact opens the link from the verification email.
export default function VerifyEmail({ token }) {
  const [state, setState] = useState('checking')
  useEffect(() => {
    supabase.rpc('confirm_contact_email', { p_token: token }).then(({ data, error }) =>
      setState(error ? 'error' : data ? 'ok' : 'invalid'))
  }, [token])
  return (
    <main className="login">
      <div className="card">
        <h1 className="brand">REGULENTA</h1>
        {state === 'checking' && <p>Confirming your email address…</p>}
        {state === 'ok' && <p>Thank you. Your email address is confirmed. You will receive the compliance reminders your organisation has set up for you.</p>}
        {state === 'invalid' && <p className="err">This link is invalid or has expired (links are valid for 7 days). Ask the administrator to send a new one.</p>}
        {state === 'error' && <p className="err">Something went wrong. Please try again later.</p>}
      </div>
    </main>
  )
}
