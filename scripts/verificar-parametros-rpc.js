// Cruza los parametros que la interfaz manda en cada .rpc(...) contra los que
// la funcion declara en el SQL. Un nombre de mas o de menos hace que Postgres
// responda "function does not exist", que en el navegador se ve como un error
// generico y cuesta rastrear.
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

const archivosSql = fs.readdirSync('sql').filter(f => f.endsWith('.sql'));
// La ultima definicion de cada funcion gana, igual que al ejecutar en orden.
function orden(f) {
  const m = f.match(/^v(\d+)/);
  return m ? parseInt(m[1], 10) : 0;
}
archivosSql.sort((a, b) => orden(a) - orden(b));

const definiciones = new Map(); // nombre -> Set(parametros)
for (const f of archivosSql) {
  const t = fs.readFileSync(path.join('sql', f), 'utf8');
  for (const m of t.matchAll(/create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?([a-z0-9_]+)\s*\(([\s\S]*?)\)\s*returns/gi)) {
    const params = new Set();
    for (const p of m[2].matchAll(/\b(p_[a-z0-9_]+)\s+/g)) params.add(p[1]);
    definiciones.set(m[1], params);
  }
}

const problemas = [];
for (const f of walk('app')) {
  const t = fs.readFileSync(f, 'utf8');
  for (const m of t.matchAll(/\.rpc\(\s*["'`]([a-z0-9_]+)["'`]\s*,\s*\{([\s\S]{0,900}?)\}\s*\)/g)) {
    const nombre = m[1];
    const decl = definiciones.get(nombre);
    if (!decl) continue;
    if (decl.size === 0) continue;
    const enviados = [...m[2].matchAll(/(?:^|[\s,{])(p_[a-z0-9_]+)\s*:/g)].map(x => x[1]);
    const sobran = enviados.filter(p => !decl.has(p));
    if (sobran.length) {
      problemas.push({
        f: f.replace(/\\/g, '/'), nombre, sobran,
        declara: [...decl].join(', '),
      });
    }
  }
}

console.log('Funciones con parametros conocidos: ' + definiciones.size);
console.log('');
if (!problemas.length) {
  console.log('Todas las llamadas .rpc() usan parametros que la funcion declara.');
} else {
  for (const p of problemas) {
    console.log('  ' + p.nombre + '  (' + p.f + ')');
    console.log('      manda y no existe: ' + p.sobran.join(', '));
    console.log('      declara: ' + p.declara);
    console.log('');
  }
}
