// Busca el patron del bug de franquicia: una pantalla a la que un rol entra
// por permiso, pero cuyos datos se resuelven por una asignacion que ese rol no
// tiene (almacen propio, entidad_id, franquicia del usuario). Resultado: la
// pantalla abre y no sirve para nada.
const fs = require('fs'), path = require('path');

const ROLES_GLOBALES = ['admin', 'control', 'gerencia'];

function paginas(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (!['node_modules', '.next', 'api'].includes(e.name)) paginas(p, out); }
    else if (e.name === 'page.tsx') out.push(p);
  }
  return out;
}

// Senales de "los datos dependen de una asignacion del perfil"
const SENALES = [
  { re: /perfil_almacenes/, nombre: 'filtra por perfil_almacenes' },
  { re: /entidad_id/, nombre: 'usa perfil.entidad_id' },
  { re: /franquicia_usuario_actual_v42/, nombre: 'resuelve franquicia por almacen asignado' },
  { re: /almacen_id.*perfil|perfil.*almacen_id/, nombre: 'cruza almacen con el perfil' },
];
// Senales de que SI contempla a los roles sin asignacion
const ESCAPES = [
  /rolGlobal/, /esRevision/, /"admin"[\s\S]{0,80}includes\(/,
  /\[\s*"admin"\s*,\s*"control"/, /rol === "admin"/, /rol\)\s*\)/,
];

const hallazgos = [];
for (const pag of paginas('app')) {
  const dir = path.dirname(pag);
  const t = fs.readFileSync(pag, 'utf8');
  const permiso = (t.match(/tienePermiso\(perfil,\s*["']([a-z._]+)["']\)/) || [])[1] || '(sin gate de permiso)';

  // clientes del mismo directorio
  const clientes = fs.readdirSync(dir)
    .filter(f => /\.tsx$/.test(f) && f !== 'page.tsx')
    .map(f => path.join(dir, f));
  if (!clientes.length) continue;

  // Los nombres de claves foraneas de PostgREST contienen 'entidad_id'
  // (almacenes!movimientos_entidad_id_fkey) sin que la pantalla dependa de la
  // asignacion del perfil. Se descartan antes de buscar senales, o reportes y
  // dashboard salen marcados para siempre y el reporte pierde credibilidad.
  const cuerpo = clientes
    .map(c => fs.readFileSync(c, 'utf8'))
    .join('\n')
    .replace(/[a-z_]*_fkey/g, '');
  const dependencias = SENALES.filter(s => s.re.test(cuerpo)).map(s => s.nombre);
  if (!dependencias.length) continue;

  const contempla = ESCAPES.some(r => r.test(cuerpo));
  hallazgos.push({
    ruta: pag.replace(/\\/g, '/'),
    permiso,
    dependencias,
    contempla,
  });
}

console.log('Pantallas cuyos datos dependen de una asignacion del perfil:\n');
for (const h of hallazgos) {
  const marca = h.contempla ? 'OK  ' : 'REVISAR';
  console.log(`${marca}  ${h.ruta}`);
  console.log(`         gate: ${h.permiso}`);
  console.log(`         depende de: ${h.dependencias.join('; ')}`);
  if (!h.contempla) console.log('         >> no se detecta manejo de roles sin almacen asignado');
  console.log('');
}
console.log(`Total: ${hallazgos.length} | a revisar: ${hallazgos.filter(h => !h.contempla).length}`);
