// Busca el bug de "las ventas validas salian anuladas": la interfaz compara
// contra un valor de estado que esa tabla no admite. Nunca falla en ejecucion,
// simplemente muestra siempre cero.
//
// Separa dos niveles, porque no tienen el mismo riesgo:
//   CONSULTA  -> .eq("estado", "x") contra la base. Si el valor no existe, la
//                consulta devuelve vacio para siempre. Esto hay que revisarlo.
//   MEMORIA   -> comparaciones en JavaScript. Muchas son estados propios de la
//                interfaz (una fila de importacion "guardada", un año "sin
//                calendario") y no tienen por que estar en el esquema.
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

// Cualquier check sobre una columna cuyo nombre contenga "estado", venga en la
// definicion de la tabla o en un alter table posterior. La segunda forma es la
// de anulacion_stock_estado, que antes se escapaba.
const permitidos = new Set();
const RE_CHECKS = [
  /[a-z_]*estado[a-z_]*\s+text[^,;]*?check\s*\(([^;]*?)\)\s*[,)]/gi,
  /check\s*\(\s*[a-z_]*estado[a-z_]*\s+in\s*\(([\s\S]{0,600}?)\)/gi,
  /constraint\s+[a-z_]*estado[a-z_]*_check\s+check\s*\(([\s\S]{0,600}?)\)\s*;/gi,
  /[a-z_]*estado[a-z_]*\s+in\s*\(([\s\S]{0,400}?)\)/gi,
];
for (const re of RE_CHECKS) {
  for (const m of todoSql.matchAll(re)) {
    for (const v of m[1].matchAll(/'([a-z_]+)'/g)) permitidos.add(v[1]);
  }
}
// Los defaults tambien son valores validos aunque no aparezcan en el check.
for (const m of todoSql.matchAll(/[a-z_]*estado[a-z_]*\s+text[^,;]*?default\s+'([a-z_]+)'/gi)) {
  permitidos.add(m[1]);
}

const consultas = [], memoria = [];
const vistos = new Set();

for (const f of walk('app')) {
  const rel = f.split(path.sep).join('/');
  fs.readFileSync(f, 'utf8').split('\n').forEach((linea, i) => {
    const registrar = (valor, destino) => {
      if (permitidos.has(valor)) return;
      const clave = rel + ':' + (i + 1) + ':' + valor;
      if (vistos.has(clave)) return;
      vistos.add(clave);
      destino.push({ f: rel, n: i + 1, valor, linea: linea.trim().slice(0, 100) });
    };
    // Consulta contra la base.
    for (const m of linea.matchAll(/\.(eq|neq)\(\s*["'][a-z_]*estado[a-z_]*["']\s*,\s*["']([a-z_]+)["']/g)) {
      registrar(m[2], consultas);
    }
    for (const m of linea.matchAll(/\.in\(\s*["'][a-z_]*estado[a-z_]*["']\s*,\s*\[([^\]]*)\]/g)) {
      for (const v of m[1].matchAll(/["']([a-z_]+)["']/g)) registrar(v[1], consultas);
    }
    // Comparacion en memoria.
    for (const m of linea.matchAll(/\bestado\s*(?:===|!==|==|!=)\s*["']([a-z_]+)["']/g)) {
      registrar(m[1], memoria);
    }
  });
}

console.log('Valores de estado que el esquema admite: ' + permitidos.size);
console.log('');

if (!consultas.length) {
  console.log('CONSULTAS: ninguna filtra por un estado que el esquema no admita.');
} else {
  console.log('CONSULTAS CON ESTADO INEXISTENTE (devuelven vacio siempre):');
  for (const s of consultas) console.log('  ' + s.f + ':' + s.n + '  -> "' + s.valor + '"\n      ' + s.linea);
}

console.log('');
if (!memoria.length) {
  console.log('MEMORIA: sin comparaciones contra valores desconocidos.');
} else {
  console.log('COMPARACIONES EN MEMORIA con valores que no son del esquema');
  console.log('(normal si son estados propios de la interfaz; revisa solo los que');
  console.log('deberian venir de la base):');
  for (const s of memoria) console.log('  ' + s.f + ':' + s.n + '  -> "' + s.valor + '"');
}
