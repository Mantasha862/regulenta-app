import { supabase } from './supabase'
import { useLoad, must, fmtDateTime } from './lib.js'

// Staff view: aggregate delivery status and scheduler runs. Recipient addresses are never shown here.
export default function Health() {
  const d = useLoad(async () => ({
    summary: must(await supabase.rpc('delivery_health_summary', { p_days: 7 })),
    runs: must(await supabase.from('scheduler_runs').select('*').order('id', { ascending: false }).limit(20)),
  }), [])
  if (d.loading && !d.data) return <p className="muted">Loading…</p>
  if (d.error) return <p className="err">{d.error}</p>
  const last = d.data.runs[0]
  const stale = !last || (Date.now() - new Date(last.started_at).getTime()) > 26 * 3600 * 1000
  return (
    <section>
      <div className="row"><h2>Delivery and scheduler health</h2><button className="ghost" onClick={d.reload}>Refresh</button></div>
      {stale && <div className="warn">The reminder scheduler has not run in the last 26 hours. Check that the pg_cron job is scheduled (migration 005) and enabled.</div>}
      <h3>Deliveries, last 7 days</h3>
      <table className="tbl"><thead><tr><th>Channel</th><th>Status</th><th>Count</th><th>Organisations</th><th>Latest error</th></tr></thead>
        <tbody>{d.data.summary.map((r, i) => <tr key={i}><td>{r.channel}</td><td>{r.status}</td><td>{r.deliveries}</td><td>{r.organisations}</td><td className="small">{r.last_error}</td></tr>)}
          {!d.data.summary.length && <tr><td colSpan="5" className="muted">No deliveries in the last 7 days.</td></tr>}</tbody></table>
      <p className="muted small">"Accepted" means the email provider took the message; "delivered" is recorded only when the provider confirms delivery through the webhook.</p>
      <h3>Scheduler runs</h3>
      <table className="tbl"><thead><tr><th>Job</th><th>Started</th><th>Finished</th><th>Result</th></tr></thead>
        <tbody>{d.data.runs.map(r => <tr key={r.id}><td>{r.job}</td><td>{fmtDateTime(r.started_at)}</td><td>{fmtDateTime(r.finished_at)}</td><td className="small">{r.ok === false ? 'failed' : JSON.stringify(r.detail)}</td></tr>)}
          {!d.data.runs.length && <tr><td colSpan="4" className="muted">The scheduler has never run.</td></tr>}</tbody></table>
    </section>
  )
}
