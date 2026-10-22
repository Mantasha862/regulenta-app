import { useEffect, useState } from 'react'
import LOGO_LIGHT from './logo-light.txt?raw'
import LOGO_DARK from './logo-dark.txt?raw'

function Ic({ name, className = '' }) {
  return <i className={`ic i-${name} ${className}`} aria-hidden="true" />
}

export function Logo({ size = 48, shimDelay = '1.6s' }) {
  return (
    <div className="logo" style={{ '--s': `${size}px`, '--sd': shimDelay }}>
      <img className="l" src={LOGO_LIGHT} alt="REGULENTA logo" />
      <img className="d" src={LOGO_DARK} alt="" />
      <div className="sheen"></div>
      <div className="star"></div>
    </div>
  )
}

export function Brandmark({ size = 34 }) {
  return (
    <div className="brandmark" style={{ padding: '6px 8px 14px' }}>
      <Logo size={size} />
      <b>REGULENTA</b>
    </div>
  )
}

export default function Splash({ onEnter }) {
  const [ready, setReady] = useState(false)

  useEffect(() => {
    const t = setTimeout(() => setReady(true), 3800)
    return () => clearTimeout(t)
  }, [])

  const letters = 'REGULENTA'.split('').map((c, i) => (
    <span key={i} className="lt" style={{ '--i': i }}>{c}</span>
  ))

  return (
    <div className="splash">
      <div className="ledger"></div>
      <div className="bar-prog"></div>

      <div className="row g8" style={{ position: 'absolute', top: 20, right: 20, zIndex: 3 }}>
        <button className="btn sm" onClick={onEnter}>
          Skip intro <Ic name="right" />
        </button>
      </div>

      <div style={{ position: 'relative', zIndex: 2, display: 'flex', flexDirection: 'column', alignItems: 'center' }}>
        <div style={{ position: 'relative', width: 260, height: 300, display: 'grid', placeItems: 'center' }}>
          <div className="glowdisc"></div>
          <div className="ring" style={{ '--r': 0 }}></div>
          <div className="ring" style={{ '--r': 1 }}></div>
          <div className="ring" style={{ '--r': 2 }}></div>
          <div style={{ animation: 'logoin 1.2s cubic-bezier(.2,.8,.2,1) both', animationDelay: '.15s' }}>
            <Logo size={230} shimDelay="-1.5s" />
          </div>
        </div>

        <h1 className="t-display" style={{
          fontWeight: 800,
          fontSize: 'clamp(40px,9vw,76px)',
          letterSpacing: '.03em',
          marginTop: 18,
          display: 'flex',
          overflow: 'hidden',
          paddingBottom: 6
        }}>
          {letters}
        </h1>

        <div className="t-display popin" style={{ '--d': '1.75s', fontSize: 30, letterSpacing: '.3em', color: 'var(--teal)', paddingLeft: '.3em' }}>
          AI
        </div>

        <p className="t-display line-in" style={{
          '--d': '2.15s',
          marginTop: 22,
          fontSize: 'clamp(11px,2.4vw,15px)',
          fontWeight: 600,
          letterSpacing: '.14em',
          textTransform: 'uppercase',
          color: 'var(--ink2)'
        }}>
          Navigate the complexity. Ensure compliance.
        </p>

        <div className="row g12 wrap" style={{ marginTop: 30, justifyContent: 'center' }}>
          <div className="chip info rise" style={{ '--d': '2.8s', height: 32, fontSize: 13.5 }}>
            <Ic name="book" />Every rule cited to an official source
          </div>
          <div className="chip ok rise" style={{ '--d': '3s', height: 32, fontSize: 13.5 }}>
            <Ic name="check" />Approved by a named human before it goes live
          </div>
          <div className="chip done rise" style={{ '--d': '3.2s', height: 32, fontSize: 13.5 }}>
            <Ic name="lock" />The AI never activates a rule on its own
          </div>
        </div>

        <button className="btn primary rise" style={{ '--d': '3.6s', marginTop: 28 }} onClick={onEnter}>
          Enter the app <Ic name="right" />
        </button>
      </div>
    </div>
  )
}
