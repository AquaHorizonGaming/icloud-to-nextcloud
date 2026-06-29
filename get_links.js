/* ============================================================================
 * get_links.js  -- harvest iCloud "Photos Part N" download links in one shot
 * ----------------------------------------------------------------------------
 * The migration tool needs a parts.txt of "<num>  <url>" lines. Copying 21
 * links by hand is tedious; this grabs them all at once.
 *
 * HOW TO USE
 *   1. Log in to https://privacy.apple.com YOURSELF (Apple ID + 2FA). This step
 *      is never automated -- scripting Apple sign-in violates Apple's terms and
 *      can lock your account.
 *   2. Open the data-download page that lists your "iCloud Photos Part N of 21"
 *      files (the page where you'd click each Download button).
 *   3. Open DevTools (F12) -> Console, paste this whole file, press Enter.
 *   4. It prints the parts.txt lines AND copies them to your clipboard.
 *      Paste them into  ~/icloud_migration/parts.txt  on the server, then run
 *      `./icloud2nc.sh download`  IMMEDIATELY (Apple's links expire in minutes).
 *
 * It scrapes whatever download URLs are present in the page DOM. If Apple only
 * generates a signed URL when you click a button (so nothing is found), see the
 * fallback note printed at the bottom.
 * ========================================================================== */
(function () {
  const PART_RE = /Part\s+(\d+)\s+of\s+\d+/i;
  const URL_RE  = /https?:\/\/[^\s"'<>]*?(?:Part[+ ]\d+[+ ]of[+ ]\d+|icloud-content)[^\s"'<>]*/i;
  const found = new Map(); // partNum -> url

  const add = (numHint, url) => {
    if (!url) return;
    let m = url.match(/Part[+ ](\d+)[+ ]of/i);
    let num = m ? +m[1] : numHint;
    if (!num) return;
    if (!found.has(num)) found.set(num, url);
  };

  // 1) anchors with hrefs
  document.querySelectorAll('a[href]').forEach(a => {
    const h = a.href || '';
    if (/icloud-content|\.zip/i.test(h)) {
      const t = (a.textContent || '') + ' ' + (a.getAttribute('download') || '');
      const m = t.match(PART_RE);
      add(m ? +m[1] : null, h);
    }
  });

  // 2) any element text that pairs a "Part N" label with a nearby link
  document.querySelectorAll('*').forEach(el => {
    const t = el.textContent || '';
    const pm = t.match(PART_RE);
    if (!pm) return;
    const link = el.querySelector && el.querySelector('a[href]');
    if (link) add(+pm[1], link.href);
  });

  // 3) brute scan of the raw HTML for icloud-content URLs
  (document.documentElement.outerHTML.match(new RegExp(URL_RE.source, 'gi')) || [])
    .forEach(u => add(null, u));

  const lines = [...found.entries()].sort((a, b) => a[0] - b[0])
    .map(([n, u]) => `${n}  ${u}`);

  if (lines.length) {
    const out = lines.join('\n');
    console.log('%cparts.txt (' + lines.length + ' links):', 'font-weight:bold');
    console.log(out);
    try { copy(out); console.log('%c-> copied to clipboard', 'color:green'); } catch (e) {}
    try { navigator.clipboard && navigator.clipboard.writeText(out); } catch (e) {}
  } else {
    console.warn('No download URLs found in the DOM.');
    console.warn('Apple likely generates each signed URL only when you click "Download".');
    console.warn('Fallback: click each Download button; in DevTools -> Network, the request to');
    console.warn('cvws.icloud-content.com IS the link -- right-click -> Copy link address, or');
    console.warn('start each download then cancel and copy it from your browser\'s downloads list.');
  }
})();
