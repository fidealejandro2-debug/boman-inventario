const fs = require('fs'), path = require('path');

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== 'node_modules' && e.name !== '.next') walk(p, out); }
    else if (/\.(tsx|ts)$/.test(e.name)) out.push(p);
  }
  return out;
}

const sql = fs.readdirSync('sql').filter(f => f.endsWith('.sql'))
  .map(f => ({ f, t: fs.readFileSync(path.join('sql', f), 'utf8') }));
const todoSql = sql.map(x => x.t).join('\n');

const archivos = walk('app').concat(walk('lib')).concat(walk('components'));
const rpcs = new Map();
const tablas = new Map();
for (const a of archivos) {
  const t = fs.readFileSync(a, 'utf8');
  for (const m of t.matchAll(/\.rpc\(\s*["'`]([a-z0-9_]+)["'`]/g)) {
    if (!rpcs.has(m[1])) rpcs.set(m[1], []);
    rpcs.get(m[1]).push(a);
  }
  for (const m of t.matchAll(/\.from\(\s*["'`]([a-z0-9_]+)["'`]/g)) {
    if (!tablas.has(m[1])) tablas.set(m[1], []);
    tablas.get(m[1]).push(a);
  }
}

const problemas = [];

for (const [nombre, usos] of rpcs) {
  // El prefijo public. es opcional: el esquema original (v5 a v7) declara sus
  // funciones sin el, y exigirlo las marcaba a todas como inexistentes.
  const definida =
    new RegExp('create\\s+(or\\s+replace\\s+)?function\\s+(public\\.)?' + nombre + '\\s*\\(', 'i').test(todoSql);
  if (!definida) { problemas.push(['RPC INEXISTENTE', nombre, [...new Set(usos)].join(', ')]); continue; }

  let ultimoGrant = -1, ultimoRevoke = -1;
  sql.forEach((x, i) => {
    const g = new RegExp('grant\\s+execute\\s+on\\s+function\\s+public\\.' + nombre + '\\s*\\([^)]*\\)[^;]*authenticated', 'i');
    const r = new RegExp('revoke\\s+execute\\s+on\\s+function\\s+public\\.' + nombre + '\\s*\\([^)]*\\)[^;]*from[^;]*authenticated', 'i');
    if (g.test(x.t)) ultimoGrant = Math.max(ultimoGrant, i);
    if (r.test(x.t)) ultimoRevoke = Math.max(ultimoRevoke, i);
  });
  if (ultimoRevoke >= 0 && ultimoRevoke > ultimoGrant) {
    problemas.push(['RPC REVOCADA a authenticated', nombre,
      [...new Set(usos)].join(', ') + '  [revocada en ' + sql[ultimoRevoke].f + ']']);
  }
}

for (const [nombre, usos] of tablas) {
  const def = new RegExp('create\\s+(or\\s+replace\\s+view|table)\\s+(if\\s+not\\s+exists\\s+)?(public\\.)?' + nombre + '\\b', 'i').test(todoSql);
  if (!def) problemas.push(['TABLA/VISTA INEXISTENTE', nombre, [...new Set(usos)].join(', ')]);
}

console.log('RPCs usadas: ' + rpcs.size + ' | tablas y vistas usadas: ' + tablas.size);
console.log('');
if (!problemas.length) console.log('Sin problemas de referencias.');
for (const p of problemas) console.log('  [' + p[0] + '] ' + p[1] + '\n      ' + p[2]);
