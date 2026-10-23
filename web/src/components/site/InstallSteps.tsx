/**
 * How to install the unnotarized app, as four numbered steps: the post-download view (/install) and the FAQ show it.
 * Plain words, no hedging: macOS refuses the first open, and Open Anyway in Privacy & Security allows it, once. macOS
 * 15 and 14 (the oldest shepetal runs on) word the message differently, so the steps name what both share.
 */
export function InstallSteps({ headingLevel = 2 }: { headingLevel?: 2 | 3 }) {
  const H = headingLevel === 2 ? 'h2' : 'h3';
  return (
    <ol className="s-steps">
      <li>
        <H className="s-step-title">Drag shepetal into Applications.</H>
        <p>Open the downloaded DMG and drag shepetal onto the Applications folder.</p>
      </li>
      <li>
        <H className="s-step-title">Open it, then close the message.</H>
        <p>
          Open shepetal from Applications. macOS says it cannot open shepetal, or could not verify that it is free of
          malware, because shepetal is not notarized by Apple. Close the message: on macOS 15, click Done.
        </p>
      </li>
      <li>
        <H className="s-step-title">Allow it in Privacy &amp; Security.</H>
        <p>
          Open System Settings, then Privacy &amp; Security, and scroll down to the message that shepetal was blocked.
          Click Open Anyway, then confirm with your password. The button is there for about an hour after you tried to
          open shepetal. On macOS 14 you can also Control-click shepetal in Applications, choose Open, then click Open.
        </p>
        {/* A sketch of that row in System Settings: what to look for, not a screenshot. */}
        <div className="s-settings-row" aria-hidden="true">
          <span className="s-settings-text">“shepetal” was blocked …</span>
          <span className="s-settings-btn">Open Anyway</span>
        </div>
      </li>
      <li>
        <H className="s-step-title">That’s it. You do this once.</H>
        <p>From now on shepetal opens like any other app.</p>
      </li>
    </ol>
  );
}
