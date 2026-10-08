// The upload page: self-contained (no external scripts, fonts or images), so it works on a network without internet access.
let page = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RVTools Decks</title>
<style>
:root {
  --bg: #f6f7f9; --card: #ffffff; --text: #1b1f24; --muted: #5d6673; --line: #d9dee5;
  --accent: #1f6feb; --accent-text: #ffffff; --ok: #1a7f37; --bad: #cf222e; --drop: #eef4ff;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f1216; --card: #171b21; --text: #e6e9ed; --muted: #9aa4b1; --line: #2b323b;
    --accent: #4c8dff; --accent-text: #0b0d10; --ok: #3fb950; --bad: #ff6b6b; --drop: #16233a;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main { max-width: 620px; margin: 0 auto; padding: 40px 16px; }
h1 { font-size: 24px; margin: 0 0 4px; }
.sub { color: var(--muted); margin: 0 0 24px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 20px; }
label.field { display: block; font-weight: 600; margin: 0 0 6px; }
input[type=text], input[type=password] { width: 100%; padding: 9px 11px; border: 1px solid var(--line); border-radius: 8px; background: var(--bg); color: var(--text); font: inherit; }
.row { margin-bottom: 18px; }
.hint { color: var(--muted); font-size: 13px; margin-top: 4px; }
.decks label { display: flex; gap: 8px; align-items: center; padding: 4px 0; font-weight: 400; }
#drop { border: 2px dashed var(--line); border-radius: 10px; padding: 28px 16px; text-align: center; cursor: pointer; transition: background .15s, border-color .15s; }
#drop.over { background: var(--drop); border-color: var(--accent); }
#drop strong { display: block; margin-bottom: 4px; }
#files { color: var(--muted); font-size: 13px; margin-top: 8px; word-break: break-all; }
button { width: 100%; margin-top: 18px; padding: 11px; border: 0; border-radius: 8px; background: var(--accent); color: var(--accent-text); font: inherit; font-weight: 600; cursor: pointer; }
button:disabled { opacity: .5; cursor: default; }
#status { margin-top: 18px; }
#status ul { list-style: none; padding: 0; margin: 8px 0 0; }
#status li { padding: 3px 0; }
.ok { color: var(--ok); } .bad { color: var(--bad); }
footer { color: var(--muted); font-size: 13px; margin-top: 18px; text-align: center; }
</style>
</head>
<body>
<main>
  <h1 id="title">RVTools Decks</h1>
  <p class="sub">Upload an RVTools export and get the decks back as a .zip.</p>
  <div class="card">
    <div class="row">
      <label class="field" for="customer">Customer name <span class="hint">(optional)</span></label>
      <input type="text" id="customer" autocomplete="organization" placeholder="Shown on the title slide and in the file names">
    </div>
    <div class="row" id="passRow" hidden>
      <label class="field" for="passcode">Passcode</label>
      <input type="password" id="passcode" autocomplete="off">
    </div>
    <div class="row">
      <label class="field">Decks</label>
      <div class="decks" id="decks"></div>
    </div>
    <div id="drop" tabindex="0" role="button" aria-label="Choose RVTools exports">
      <strong>Drop the RVTools .xlsx export here</strong>
      <span class="hint">or click to choose. Add one export per vCenter to combine them.</span>
      <div id="files"></div>
    </div>
    <input type="file" id="picker" accept=".xlsx" multiple hidden>
    <button id="go" disabled>Make decks</button>
    <div id="status" aria-live="polite"></div>
  </div>
  <footer>The export is processed on this server and deleted once the decks are sent.</footer>
</main>
<script>
let files = [], config = null;
const $ = id => document.getElementById(id);

fetch('/config').then(r => r.json()).then(c => {
  config = c;
  $('title').textContent = c.title;
  document.title = c.title;
  $('passRow').hidden = !c.passcode;
  try { $('passcode').value = sessionStorage.getItem('passcode') || ''; } catch (e) {}
  for (const d of c.decks) {
    const l = document.createElement('label');
    const cb = document.createElement('input');
    cb.type = 'checkbox'; cb.checked = true; cb.value = d.id;
    cb.addEventListener('change', update);
    l.append(cb, document.createTextNode(d.name));
    $('decks').append(l);
  }
});

function chosenDecks() { return [...document.querySelectorAll('#decks input:checked')].map(c => c.value); }
function update() { $('go').disabled = !files.length || !chosenDecks().length; }
function setFiles(list) {
  files = [...list].filter(f => f.name.toLowerCase().endsWith('.xlsx'));
  const skipped = list.length - files.length;
  $('files').textContent = files.map(f => `${f.name} (${(f.size / 1048576).toFixed(1)} MB)`).join(', ')
    + (skipped ? ` — skipped ${skipped} file(s) that aren't .xlsx` : '');
  update();
}

const drop = $('drop');
drop.addEventListener('click', () => $('picker').click());
drop.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); $('picker').click(); } });
$('picker').addEventListener('change', e => setFiles(e.target.files));
['dragenter', 'dragover'].forEach(t => drop.addEventListener(t, e => { e.preventDefault(); drop.classList.add('over'); }));
['dragleave', 'drop'].forEach(t => drop.addEventListener(t, e => { e.preventDefault(); drop.classList.remove('over'); }));
drop.addEventListener('drop', e => setFiles(e.dataTransfer.files));

// Each file: [u32 name length][name][u32 size][bytes], big-endian.
async function pack(list) {
  const parts = [];
  for (const f of list) {
    const name = new TextEncoder().encode(f.name);
    const head = new DataView(new ArrayBuffer(4)); head.setUint32(0, name.length);
    const size = new DataView(new ArrayBuffer(4)); size.setUint32(0, f.size);
    parts.push(head, name, size, f);
  }
  return new Blob(parts);
}

function show(html) { $('status').innerHTML = html; }
function esc(s) { return String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

$('go').addEventListener('click', async () => {
  const total = files.reduce((a, f) => a + f.size, 0);
  if (config && total > config.maxMB * 1048576) { show(`<p class="bad">That's over the ${config.maxMB} MB limit.</p>`); return; }
  $('go').disabled = true;
  show('<p>Making decks…</p>');
  const pass = $('passcode').value.trim();
  try { sessionStorage.setItem('passcode', pass); } catch (e) {}
  try {
    const res = await fetch('/decks', {
      method: 'POST',
      headers: { 'X-Customer': encodeURIComponent($('customer').value.trim()), 'X-Decks': chosenDecks().join(','), 'X-Passcode': pass },
      body: await pack(files),
    });
    let results = [];
    try { results = JSON.parse(decodeURIComponent(res.headers.get('X-Deck-Results') || '[]')); } catch (e) {}
    const list = results.length ? '<ul>' + results.map(r => r.ok
      ? `<li class="ok">✓ ${esc(r.file)}</li>`
      : `<li class="bad">✗ ${esc(r.name)}: ${esc(r.error || 'failed')}</li>`).join('') + '</ul>' : '';
    if (!res.ok) { show(`<p class="bad">${esc(await res.text())}</p>${list}`); return; }
    const blob = await res.blob();
    const cd = res.headers.get('Content-Disposition') || '';
    const m = cd.match(/filename\*=UTF-8''([^;]+)/);
    const name = m ? decodeURIComponent(m[1]) : 'decks.zip';
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = name; document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    show(`<p>Downloaded <strong>${esc(name)}</strong>.</p>${list}`);
  } catch (e) {
    show(`<p class="bad">Couldn't reach the server: ${esc(e.message)}</p>`);
  } finally { update(); }
});
</script>
</body>
</html>
"""#
