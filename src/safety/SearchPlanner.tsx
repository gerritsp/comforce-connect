// Fictional, device-local search planning. Codex (GPT-6) implemented the form, map and report lifecycle.
import { useEffect, useState, type FormEvent } from 'react'
import geography from '../impact/milwaukee.json'
import water from '../impact/water.json'
import './searchPlanner.css'

type Area = keyof typeof geography.areas
type Travel = 'walk' | 'car'
type Report = {
  area: Area
  travel: Travel
  seen: number
  created: number
  missingPersonDescription?: string
  suspectedAbductorDescription?: string
}
const prefix = 'comforce.search-demo.v1.'
const lifetime = 48 * 60 * 60 * 1000
const descriptionLimit = 500
const speeds = { walk: 3, car: 30 }
const areas = Object.keys(geography.areas) as Area[]
const milesToMapUnits = 48.1 / 2 // Same two-mile scale as NeighborhoodMap.
const timeLabel = (time: number) => new Date(time).toLocaleString()

function localDate(time: number, dayOffset = 0) {
  const date = new Date(time)
  date.setDate(date.getDate() + dayOffset)
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${date.getFullYear()}-${month}-${day}`
}

function readReports(now: number) {
  const reports: Report[] = []
  for (const key of Object.keys(localStorage).filter(key => key.startsWith(prefix))) {
    let row: Report
    try { row = JSON.parse(localStorage.getItem(key) || 'null') } catch { continue }
    if (!row || !areas.includes(row.area) || !Object.hasOwn(speeds, row.travel)
      || !Number.isFinite(row.seen) || !Number.isFinite(row.created) || row.seen > row.created) continue
    if (now >= row.created + lifetime) localStorage.removeItem(key)
    else reports.push({
      ...row,
      missingPersonDescription: typeof row.missingPersonDescription === 'string'
        ? row.missingPersonDescription.slice(0, descriptionLimit) : undefined,
      suspectedAbductorDescription: typeof row.suspectedAbductorDescription === 'string'
        ? row.suspectedAbductorDescription.slice(0, descriptionLimit) : undefined,
    })
  }
  return reports.sort((a, b) => b.created - a.created)
}

export default function SearchPlanner() {
  const [reports, setReports] = useState<Report[]>([])
  const [selected, select] = useState<number>()
  const [now, setNow] = useState(Date.now)
  const [message, say] = useState('')
  const [storageError, setStorageError] = useState(false)
  function refresh() {
    const time = Date.now()
    setNow(time)
    try { setReports(readReports(time)); setStorageError(false) }
    catch { setStorageError(true); setReports([]) }
  }
  useEffect(() => {
    refresh()
    const timer = window.setInterval(refresh, 60000)
    window.addEventListener('storage', refresh)
    window.addEventListener('focus', refresh)
    return () => {
      clearInterval(timer)
      window.removeEventListener('storage', refresh)
      window.removeEventListener('focus', refresh)
    }
  }, [])
  function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const data = new FormData(event.currentTarget)
    const day = data.get('seenDay')
    const clock = data.get('seenTime')
    const created = Date.now()
    if (day !== localDate(created) && day !== localDate(created, -1)) {
      say('Choose today or yesterday.')
      refresh()
      return
    }
    const localTime = `${day}T${clock}`
    const seen = new Date(localTime).getTime()
    if (!Number.isFinite(seen) || seen > created) {
      say('Choose a last-seen time that has already passed.')
      return
    }
    const seenDate = new Date(seen)
    const actualTime = `${String(seenDate.getHours()).padStart(2, '0')}:${String(seenDate.getMinutes()).padStart(2, '0')}`
    if (clock !== actualTime) {
      say('Choose a valid time on that day.')
      return
    }
    const row = {
      area: data.get('area'), travel: data.get('travel'), seen, created,
      missingPersonDescription: String(data.get('missingPersonDescription') ?? '').trim().slice(0, descriptionLimit),
      suspectedAbductorDescription: String(data.get('suspectedAbductorDescription') ?? '').trim().slice(0, descriptionLimit),
    }
    try { localStorage.setItem(prefix + created, JSON.stringify(row)) }
    catch { say('This browser could not save the report.'); return }
    select(created)
    refresh()
    say('Demo report saved on this browser.')
  }
  function close(row: Report) {
    try { localStorage.removeItem(prefix + row.created) }
    catch { say('This browser could not close the report.'); return }
    refresh()
    say('Report closed.')
  }
  const row = reports.find(item => item.created === selected) ?? reports[0]
  const miles = row ? Math.max(0, now - row.seen) / 3600000 * speeds[row.travel] : 0
  const center = row && geography.areas[row.area]
  return <section className="search-planner" aria-label="Fictional missing-person reports">
    <div>
      <h2>Plan a search area</h2>
      <p>Use fictional details. Reports stay in this browser and expire 48 hours after creation. This demo sends no alert to responders.</p>
      <form onSubmit={save}>
        <label>Last-seen neighborhood<select name="area">{areas.map(area => <option key={area}>{area}</option>)}</select></label>
        <label>Last seen day (your local date)<select name="seenDay">
          <option value={localDate(now)}>Today</option>
          <option value={localDate(now, -1)}>Yesterday</option>
        </select></label>
        <label>Last seen time (your local time)<input required type="time" name="seenTime" /></label>
        <label>Travel assumption<select name="travel"><option value="walk">Walking · 3 mph</option><option value="car">Driving · 30 mph</option></select></label>
        <label>
          Missing person description (optional)
          <textarea name="missingPersonDescription" rows={3} maxLength={descriptionLimit}
            placeholder="Example: Green coat, black backpack, white sneakers" />
        </label>
        <label>
          Suspected abductor description (optional)
          <textarea name="suspectedAbductorDescription" rows={3} maxLength={descriptionLimit}
            placeholder="Example: Gray sweatshirt, driving a dark blue van" />
        </label>
        <button>Create demo report</button>
      </form>
      <p role="status">{storageError ? 'Browser storage is unavailable.' : message}</p>
      {reports.length > 0 && <label>Open reports<select value={row.created} onChange={event => select(Number(event.target.value))}>
        {reports.map(item => <option value={item.created} key={item.created}>{item.area} · {timeLabel(item.seen)} · {item.travel}</option>)}
      </select></label>}
    </div>
    <figure>
      <svg viewBox="0 0 340 470" role="img" aria-label={row ? 'Milwaukee map centered on the city with an estimated travel radius from ' + row.area : 'Milwaukee neighborhood map'}>
        <rect width="340" height="470" fill="#e8ecdf" />
        <path d={water.lake} fill="#99c6ce" />
        <path d={geography.context} fill="none" stroke="#aab7a7" />
        {areas.map(area => <path key={area} d={geography.areas[area].d} fill="#bdd5bf" stroke="#95af9b" />)}
        <path d={water.rivers} fill="none" stroke="#73aab6" />
        {center && <g><circle cx={center.x} cy={center.y} r={Math.min(700, miles * milesToMapUnits)} fill="#ecaa3a" fillOpacity=".24" stroke="#895708" strokeWidth="2"/>
          <circle cx={center.x} cy={center.y} r="4" fill="#513513" /></g>}
        <text x="240" y="130" fontSize="11">Lake Michigan</text>
        <path d="M16 445v5h48.1v-5" fill="none" stroke="#23372b"/><text x="16" y="441" fontSize="10">2 miles</text>
      </svg>
      <figcaption>{row ? <><strong>{row.area} · {miles.toLocaleString(undefined, {maximumFractionDigits: 1})} mi radius</strong>
        <p>From the neighborhood center, assuming continuous travel at {speeds[row.travel]} mph. Shading can extend beyond the city view. Roads, stops and direction are unknown. The circle is neither a location prediction nor a maximum distance.</p>
        <p>Updates every minute · Closes {timeLabel(row.created + lifetime)}</p>
        {row.missingPersonDescription && <p style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
          <strong>Missing person description</strong><br />{row.missingPersonDescription}
        </p>}
        {row.suspectedAbductorDescription && <p style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
          <strong>Suspected abductor description</strong><br />{row.suspectedAbductorDescription}
        </p>}
        <button type="button" onClick={() => close(row)}>Close this report</button></> : 'Create a fictional report to see its estimated travel radius.'}</figcaption>
    </figure>
  </section>
}
