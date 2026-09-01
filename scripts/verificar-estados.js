// Busca el bug de "las ventas validas salian anuladas": la interfaz compara
// contra un valor de estado que esa tabla no admite. Nunca falla en ejecucion,
// simplemente muestra siempre cero.
const fs = require('fs'), path = require('path');

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (!['node_modules', '.next'].includes(e.name)) walk(p, out); }
    else if (/\.tsx?$/.test(e.name)) out.push(p);
  }
  return out;
}

const todoSql = fs.readdirSync('sql').filter(f => f.endsWith('.sql'))
  .map(f => fs.readFileSync(path.join('sql', f), 'utf8')).join('\n');

// Todos los valores que alguna columna 'estado' admite en algun check del esquema.
const permitidos = new Set();
for (const m of todoSql.matchAll(/estado[a-z_]*\s+text[^,]*?check\s*\([^)]*?in\s*\(([^)]*)\)/gi)) {
  for (const v of m[1].matchAll(/'([a-z_]+)'/g)) permitidos.add(v[1]);
}
for (const m of todoSql.matchAll(/check\s*\(\s*estado[a-z_]*\s+in\s*\(([^)]*)\)/gi)) {
  for (const v of m[1].matchAll(/'([a-z_]+)'/g)) permitidos.add(v[1]);
}
// Los estados de documentos_inventario van en una lista multilinea aparte.
for (const m of todoSql.matchAll(/estado\s+text\s+not\s+null\s+check\s*\(estado\s+in\s*\(([\s\S]{0,400}?)\)/gi)) {
  for (const v of m[1].matchAll(/'([a-z_]+)'/g)) permitidos.add(v[1]);
}

const sospechosos = [];
for (const f of walk('app')) {
  const t = fs.readFileSync(f, 'utf8');
  const lineas = t.split('\n');
  lineas.forEach((linea, i) => {
    const patrones = [
      /\.eq\(\s*["']estado["']\s*,\s*["']([a-z_]+)["']/g,
      /estado\s*[!=]==\s*["']([a-z_]+)["']/g,
      /estado\s*===\s*["']([a-z_]+)["']/g,
    ];
    for (const p of patrones) {
      for (const m of linea.matchAll(p)) {
        const valor = m[1];
        if (!permitidos.has(valor)) {
          sospechosos.push({ f: f.replace(/\\/g, '/'), n: i + 1, valor, linea: linea.trim().slice(0, 110) });
        }
      }
    }
  });
}

console.log('Estados que el esquema admite (' + permitidos.size + '):');
console.log('  ' + [...permitidos].sort().join(', '));
console.log('');
if (!sospechosos.length) {
  console.log('Ninguna comparacion de estado en la interfaz usa un valor inexistente.');
} else {
  console.log('COMPARACIONES SOSPECHOSAS:');
  for (const s of sospechosos) {
    console.log(`  ${s.f}:${s.n}  ->  "${s.valor}"`);
    console.log(`      ${s.linea}`);
  }
}
