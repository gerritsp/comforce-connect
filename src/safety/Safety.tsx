import SearchPlanner from './SearchPlanner'
import CrimeHeatmap from './CrimeHeatmap'
import { crimeSources, neighborhoodSummary } from './crimeData'
import './safety.css'

const signed = new Intl.NumberFormat('en-US', { signDisplay: 'always', maximumFractionDigits: 1 })

export default function Safety() {
  return <main className="safety-page">
    <header className="safety-lead">
      <div>
        <p className="safety-location">Milwaukee public data</p>
        <h1>Neighborhood <em>context</em></h1>
      </div>
      <div className="safety-intro">
        <p>Explore reported MPD incidents in the six neighborhoods served by this demonstration. The animation uses aggregate public records and never displays individual addresses.</p>
        <p className="safety-period"><strong>Comparison period</strong><span>January 1–October 31 · 2025 and 2026</span></p>
      </div>
    </header>

    <details className="search-disclosure"><summary>Missing-person search map · fictional demo</summary><SearchPlanner /></details>

    <div className="safety-spread">
      <CrimeHeatmap />
      <aside className="standouts" aria-labelledby="standouts-title">
        <p className="safety-kicker">What stands out</p>
        <h2 id="standouts-title">A closer read</h2>
        <article><strong>−7.5%</strong><h3>Fewer incidents overall</h3><p>The six areas recorded 3,116 incidents, compared with 3,369 during the same 2025 period.</p></article>
        <article><strong>+6.1%</strong><h3>Riverwest moved differently</h3><p>Riverwest was the only selected neighborhood with an overall increase: 606 incidents, up from 571.</p></article>
        <article><strong>83 and 101</strong><h3>Vehicle theft fell sharply</h3><p>Bay View declined from 156 to 83 incidents; Walker’s Point declined from 180 to 101.</p></article>
        <article><strong>4 areas</strong><h3>Assault trends need context</h3><p>Aggravated-assault counts rose in Bay View, Harambee, Riverwest and Silver City even as overall totals fell in most areas.</p></article>
      </aside>
    </div>

    <section className="crime-table-section" aria-labelledby="crime-table-title">
      <div className="crime-table-heading">
        <div><p className="safety-kicker">Same-period comparison</p><h2 id="crime-table-title">Neighborhood detail</h2></div>
        <p>Unique incidents can contain more than one offense category, so category columns should not be added together.</p>
      </div>
      <div className="crime-table-scroll" tabIndex={0} role="region" aria-label="Scrollable neighborhood incident table">
        <table>
          <thead><tr><th scope="col">Neighborhood</th><th scope="col">2026 incidents</th><th scope="col">vs. 2025</th>
            <th scope="col">Aggravated assault</th><th scope="col">Robbery</th><th scope="col">Burglary</th>
            <th scope="col">Theft/larceny</th><th scope="col">Vehicle theft</th></tr></thead>
          <tbody>{neighborhoodSummary.map(row => <tr key={row.name}><th scope="row">{row.name}</th>
            <td>{row.incidents2026}</td><td className={row.change > 0 ? 'change-up' : 'change-down'}>{signed.format(row.change)}%</td>
            <td>{row.aggravatedAssault}</td><td>{row.robbery}</td><td>{row.burglary}</td><td>{row.theft}</td><td>{row.vehicleTheft}</td>
          </tr>)}</tbody>
        </table>
      </div>
    </section>

    <section className="safety-notes" aria-labelledby="safety-notes-title">
      <div><p className="safety-kicker">Read with care</p><h2 id="safety-notes-title">Reported incidents are not a safety score</h2></div>
      <div className="safety-note-copy">
        <p>These are raw counts, not population-adjusted rates. Neighborhoods differ in size, population and land use. MPD notes that records can be revised, may reflect where an incident was reported rather than where it occurred, and do not include every call for service.</p>
        <p>We counted each case number once per neighborhood, used the incident coordinates to join it to the City’s neighborhood polygons, and grouped selected offenses using FBI NIBRS codes. About 0.5% of applicable 2026 citywide records lacked coordinates and could not be assigned.</p>
        <ul>
          <li><a href={crimeSources.incidents}>Milwaukee NIBRS incident data</a></li>
          <li><a href={crimeSources.neighborhoods}>City neighborhood boundaries</a></li>
          <li><a href={crimeSources.codes}>FBI NIBRS code definitions</a></li>
          <li><a href={crimeSources.disclaimer}>Milwaukee crime-data disclaimer</a></li>
          <li><a href={crimeSources.calls}>MPD calls-for-service dashboard</a></li>
        </ul>
      </div>
    </section>
  </main>
}
