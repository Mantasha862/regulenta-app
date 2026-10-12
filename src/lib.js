// Shared helpers for the REGULENTA app.
import { useCallback, useEffect, useState } from 'react'

export const STAGES = ['initiated', 'preparing', 'in_review', 'approved', 'executed', 'filed', 'evidence_pending', 'closed', 'cancelled', 'not_applicable']
export const STAGE_LABEL = {
  initiated: 'Not started', preparing: 'Preparing', in_review: 'In review', approved: 'Approved', executed: 'Executed',
  filed: 'Filed', evidence_pending: 'Evidence pending', closed: 'Closed', cancelled: 'Cancelled', not_applicable: 'Not applicable',
}
export const OPEN = s => !['closed', 'cancelled', 'not_applicable'].includes(s)

// Mirrors transition_obligation() in the database (the database is the authority; this only decides which buttons to show).
export function nextSteps(o, isAdmin) {
  const s = o.stage, out = []
  const add = (to, label, opts = {}) => out.push({ to, label, ...opts })
  if (s === 'initiated') add('preparing', 'Start preparing')
  if (s === 'preparing') {
    if (o.requires_approval) add('in_review', 'Submit for review')
    else { add('executed', 'Mark executed'); add('filed', 'Record filing', { needsRef: true }) }
  }
  if (s === 'in_review') { if (isAdmin) add('approved', 'Approve'); add('preparing', 'Return for changes', { needsNote: true }) }
  if (s === 'approved') { add('executed', 'Mark executed'); add('filed', 'Record filing', { needsRef: true }); add('preparing', 'Return for changes', { needsNote: true }) }
  if (s === 'executed') add('filed', 'Record filing', { needsRef: true })
  if (s === 'filed') { add('evidence_pending', 'Awaiting acknowledgement'); add('closed', 'Close') }
  if (s === 'evidence_pending') add('closed', 'Close')
  if (['filed', 'evidence_pending', 'closed', 'cancelled', 'not_applicable'].includes(s)) add('preparing', 'Reopen', { needsNote: true })
  if (OPEN(s) && isAdmin) { add('cancelled', 'Cancel', { needsNote: true, danger: true }); add('not_applicable', 'Not applicable', { needsNote: true, danger: true }) }
  return out
}

export const today = () => new Date().toISOString().slice(0, 10)
export function addDays(iso, n) { const d = new Date(iso + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10) }
export function fmtDate(iso) {
  if (!iso) return '—'
  const d = new Date(iso.length === 10 ? iso + 'T00:00:00Z' : iso)
  return d.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric', timeZone: 'Asia/Kolkata' })
}
export function fmtDateTime(iso) {
  return iso ? new Date(iso).toLocaleString('en-IN', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Kolkata' }) : '—'
}
export function daysUntil(iso) { return Math.round((new Date(iso + 'T00:00:00Z') - new Date(today() + 'T00:00:00Z')) / 86400000) }

// small data hook: load(), plus data/error/loading
export function useLoad(fn, deps) {
  const [state, set] = useState({ data: null, error: '', loading: true })
  const load = useCallback(async () => {
    set(s => ({ ...s, loading: true }))
    try { set({ data: await fn(), error: '', loading: false }) } catch (e) { set({ data: null, error: e.message || String(e), loading: false }) }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
  useEffect(() => { load() }, [load])
  return { ...state, reload: load }
}
export function must({ data, error }) { if (error) throw new Error(error.message); return data }

export function humanError(msg) {
  if (!msg) return ''
  if (/row-level security/i.test(msg)) return 'You do not have permission to do that.'
  return msg
}
