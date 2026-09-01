// Acepta grants y revokes con o sin el prefijo public., y respeta el orden de
// ejecucion de las migraciones: gana la ultima sentencia sobre esa funcion.
const fs = require('fs'), path = require('path');

function walk(d, o = []) {
  if (!fs.existsSync(d)) return o;
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) { if (!['node_modules', '.next'].includes(e.name)) walk(p, o); }
    else if (/\.tsx?$/.test(e.name)) o.push(p);
  }
  return o;
}

const orden = (f) => { const m = f.match(/^v(\d+)/); return m ? parseInt(m[1], 10) : 0; };
const archivos = fs.readdirSync('sql').filter((f) => f.endsWith('.sql')).sort((a, b) => orden(a) - orden(b));
const sql = archivos.map((f) => ({ f, t: fs.readFileSync(path.join('sql', f), 'utf8') }));

const usadas = new Map();
for (const a of walk('app')) {
  const t = fs.readFileSync(a, 'utf8');
  for (const m of t.matchAll(/\.rpc\(\s*["'`]([a-z0-9_]+)["'`]/g)) {
    if (!usadas.has(m[1])) usadas.set(m[1], new Set());
    usadas.get(m[1]).add(a.split(path.sep).join('/'));
  }
}

const malas = [];
for (const [n, us] of usadas) {
  let g = -1, r = -1;
  const P = '(?:public\\.)?' + n;
  sql.forEach((x, i) => {
    if (new RegExp('grant\\s+execute\\s+on\\s+function\\s+' + P + '\\s*\\([^;]*to[^;]*authenticated', 'i').test(x.t)) g = Math.max(g, i);
    if (new RegExp('revoke\\s+(execute|all)\\s+on\\s+function\\s+' + P + '\\s*\\([^;]*from[^;]*authenticated', 'i').test(x.t)) r = Math.max(r, i);
  });
  if (r >= 0 && r > g) malas.push({ n, archivo: sql[r].f, us: [...us].join(', ') });
}

console.log('RPC llamadas desde la interfaz: ' + usadas.size);
console.log('');
if (!malas.length) console.log('Ninguna interfaz llama una funcion revocada a authenticated.');
for (const m of malas) {
  console.log('  REVOCADA: ' + m.n + '   [ultimo revoke en ' + m.archivo + ']');
  console.log('      la llama: ' + m.us);
}
