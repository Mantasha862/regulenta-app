import { useState } from 'react'
import { supabase } from './supabase'
import { useLoad, must, daysUntil, OPEN, fmtDate, today, addDays } from './lib.js'

function Ic({ name, className = '' }) {
  return <i className={`ic i-${name} ${className}`} aria-hidden="true" />
}

const LAWS = [['all', 'All laws'], ['companies', 'Companies Act'], ['sebi', 'SEBI'], ['gst', 'GST'], ['labour', 'Labour']]

export default function Dashboard({ org, isAdmin, go }) {
  const [law, setLaw] = useState('all')
  const [status, setStatus] = useState('all')
  const [viewMode, setViewMode] = useState('list')

  const { data, error, loading, reload } = useLoad(async () => {
    const obs = must(await supabase.from('obligations')
      .select('id,due_date,stage,lifecycle,requires_evidence,period_label,clients(name),rule_versions(rules(form,title))')
      .eq('org_id', org.id).order('due_date'))
    const docs = new Set(must(await supabase.from('documents').select('obligation_id').eq('org_id', org.id).not('obligation_id', 'is', null)).map(d => d.obligation_id))
    const clientCount = (await supabase.from('clients').select('id', { count: 'exact', head: true }).eq('org_id', org.id)).count || 0
    return { obs, docs, clientCount }
  }, [org.id, isAdmin])

  if (loading && !data) return <p className="muted">Loading…</p>
  if (error) return <p className="err">{error}</p>

  const active = data.obs.filter(o => o.lifecycle === 'active')
  const open = active.filter(o => OPEN(o.stage))
  const notFiled = o => ['initiated', 'preparing', 'in_review', 'approved', 'executed'].includes(o.stage)
  const overdue = open.filter(o => notFiled(o) && daysUntil(o.due_date) < 0)
  const due30 = open.filter(o => notFiled(o) && daysUntil(o.due_date) >= 0 && daysUntil(o.due_date) <= 30)
  const filed = open.filter(o => o.stage === 'filed')
  const later = open.filter(o => notFiled(o) && daysUntil(o.due_date) > 30)

  // Apply filters
  const filterOb = o => {
    if (law !== 'all') {
      const form = (o.rule_versions?.rules?.form || '').toLowerCase()
      if (law === 'companies' && !form.includes('companies')) return false
      if (law === 'sebi' && !form.includes('sebi')) return false
      if (law === 'gst' && !form.includes('gst')) return false
      if (law === 'labour' && !form.includes('labour')) return false
    }
    if (status === 'overdue' && !(notFiled(o) && daysUntil(o.due_date) < 0)) return false
    if (status === 'upcoming' && !(notFiled(o) && daysUntil(o.due_date) >= 0)) return false
    return true
  }

  const filtered = open.filter(filterOb)
  const fOverdue = filtered.filter(o => notFiled(o) && daysUntil(o.due_date) < 0)
  const fDue30 = filtered.filter(o => notFiled(o) && daysUntil(o.due_date) >= 0 && daysUntil(o.due_date) <= 30)
  const fLater = filtered.filter(o => notFiled(o) && daysUntil(o.due_date) > 30)
  const fFiled = filtered.filter(o => o.stage === 'filed')

  function ObRow({ o, i }) {
    const d = daysUntil(o.due_date)
    const dd = new Date(o.due_date)
    const day = dd.getDate()
    const mon = dd.toLocaleString('en', { month: 'short' }).toUpperCase()
    const isOverdue = d < 0 && notFiled(o)

    let chipClass = 'chip'
    let chipText = ''
    if (o.stage === 'filed') { chipClass += ' done'; chipText = 'Filed' }
    else if (d < 0) { chipClass += ' over'; chipText = `${-d}d overdue` }
    else if (d <= 7) { chipClass += ' due'; chipText = `Due in ${d}d` }
    else { chipClass += ' info'; chipText = fmtDate(o.due_date) }

    return (
      <a className={`obl ${isOverdue ? 'over' : ''}`} style={{ '--d': `${i * 70}ms` }}
        onClick={() => go('compliance', { obligation: o.id })}>
        <div className="dt">
          <b>{day}</b>
          <span>{mon}</span>
        </div>
        <div>
          <div className="ttl">{o.rule_versions?.rules?.form || o.rule_versions?.rules?.title}</div>
          <div className="sub">{o.clients?.name} · {o.period_label || ''}</div>
        </div>
        <div className="chips row g8">
          <span className={chipClass}>{chipText}</span>
        </div>
        <Ic name="right" className="faint" />
      </a>
    )
  }

  function ObGroup({ label, items }) {
    if (!items.length) return null
    return (
      <div>
        <div className="grp">{label}<span className="mono faint" style={{ fontWeight: 400 }}>{items.length}</span></div>
        {items.map((o, i) => <ObRow key={o.id} o={o} i={i} />)}
      </div>
    )
  }

  const todayStr = new Date().toLocaleDateString('en-IN', { weekday: 'long', day: '2-digit', month: '2-digit', year: 'numeric' })

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
      {/* Stat tiles */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(min(160px, 100%), 1fr))', gap: 12 }}>
        <div className={`stat ${overdue.length ? 'bad' : ''}`} onClick={() => { setStatus('overdue'); setLaw('all') }} style={{ cursor: 'pointer' }}>
          <span className="t-sm" style={{ fontWeight: 600 }}><Ic name="alert" /> Overdue</span>
          <b>{overdue.length}</b>
        </div>
        <div className="stat" style={{ '--d': '70ms', cursor: 'pointer' }} onClick={() => { setStatus('upcoming'); setLaw('all') }}>
          <span className="t-sm muted" style={{ fontWeight: 600 }}><Ic name="clock" /> Due in 30 days</span>
          <b>{due30.length}</b>
        </div>
        <div className="stat" style={{ '--d': '140ms', cursor: 'pointer' }} onClick={() => { setStatus('all'); setLaw('all') }}>
          <span className="t-sm muted" style={{ fontWeight: 600 }}><Ic name="list" /> Open</span>
          <b>{open.length}</b>
        </div>
        <div className="stat" style={{ '--d': '210ms', cursor: 'pointer' }} onClick={() => go('companies')}>
          <span className="t-sm muted" style={{ fontWeight: 600 }}><Ic name="building" /> Clients</span>
          <b>{data.clientCount}</b>
        </div>
      </div>

      {/* Banner */}
      {!data.obs.length && (
        <div className="banner rise" style={{ '--d': '260ms' }}>
          <Ic name="info" className="ic-lg" />
          <span>No deadlines yet. Add a company, complete its profile, then generate deadlines from rules that reviewers have verified and approved.</span>
        </div>
      )}

      {/* Filter chips + segmented controls */}
      <div className="row sp wrap g12">
        <div className="row g8 wrap" role="group" aria-label="Filter by law">
          {LAWS.map(([k, l]) => (
            <button key={k} className="fchip" aria-pressed={law === k} onClick={() => setLaw(k)}>{l}</button>
          ))}
        </div>
        <div className="row g8 wrap">
          <div className="seg" role="group" aria-label="Status">
            {[['all', 'All'], ['overdue', 'Overdue'], ['upcoming', 'Upcoming']].map(([k, l]) => (
              <button key={k} aria-pressed={status === k} onClick={() => setStatus(k)}>{l}</button>
            ))}
          </div>
          <div className="seg" role="group" aria-label="View">
            <button aria-pressed={viewMode === 'list'} onClick={() => setViewMode('list')}><Ic name="list" />List</button>
            <button aria-pressed={viewMode === 'cal'} onClick={() => setViewMode('cal')}><Ic name="cal" />Calendar</button>
          </div>
        </div>
      </div>

      {/* Obligation list or Calendar */}
      {viewMode === 'list' ? (
        <div className="card" style={{ overflow: 'hidden', containerType: 'inline-size' }}>
          <ObGroup label="Overdue" items={fOverdue} />
          <ObGroup label="Next 30 days" items={fDue30} />
          <ObGroup label="Later" items={fLater} />
          <ObGroup label="Recently filed" items={fFiled} />
          {!filtered.length && (
            <div style={{ padding: '48px 20px', textAlign: 'center' }} className="col g8">
              <div className="t-h3">No obligations match these filters</div>
              <div><button className="btn sm" onClick={() => { setLaw('all'); setStatus('all') }}>Clear filters</button></div>
            </div>
          )}
        </div>
      ) : (
        <CalendarView obligations={filtered} go={go} />
      )}

      {/* Disclaimer footer */}
      <div className="row g12 t-sm muted">
        <Ic name="shield" className="ic-lg" />
        <span>Dates are computed from approved rules with primary-source evidence. A date is shown as approved only after a person approves its rule. Open any row to see how the date is worked out.</span>
      </div>
    </div>
  )
}

function CalendarView({ obligations, go }) {
  const now = new Date()
  const year = now.getFullYear()
  const month = now.getMonth()
  const firstDay = new Date(year, month, 1).getDay() // 0=Sun
  const daysInMonth = new Date(year, month + 1, 0).getDate()
  const startOffset = firstDay === 0 ? 6 : firstDay - 1 // Monday start
  const todayDate = now.getDate()
  const monthName = now.toLocaleString('en', { month: 'long', year: 'numeric' })

  const cells = []
  for (let i = 0; i < 35; i++) {
    const dn = i - startOffset + 1
    const inMonth = dn >= 1 && dn <= daysInMonth
    const evs = inMonth ? obligations.filter(o => {
      const dd = new Date(o.due_date)
      return dd.getDate() === dn && dd.getMonth() === month && dd.getFullYear() === year
    }) : []

    cells.push(
      <div key={i} className={`c ${inMonth ? '' : 'off'} ${dn === todayDate && inMonth ? 'today' : ''}`}>
        <div className="n">{inMonth ? dn : ''}</div>
        {evs.map(o => (
          <button key={o.id} className={`ev ${daysUntil(o.due_date) <= 14 ? 'due' : ''}`}
            title={`${o.rule_versions?.rules?.form}, ${o.clients?.name}`}
            onClick={() => go('compliance', { obligation: o.id })}>
            <span>{(o.rule_versions?.rules?.form || '').slice(0, 12)}</span>
          </button>
        ))}
      </div>
    )
  }

  return (
    <div className="col g12">
      <div className="row sp">
        <h2 className="t-h2">{monthName}</h2>
        <span className="t-sm faint">Statutory due dates</span>
      </div>
      <div className="cal rise">
        {['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map(w => <div key={w} className="h">{w}</div>)}
        {cells}
      </div>
    </div>
  )
}
