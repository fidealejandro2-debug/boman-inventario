// Corre los cinco verificadores en orden y resume al final.
// Uso: npm run verificar
const { execFileSync } = require('child_process');
const path = require('path');

const PASOS = [
  ['verificar-referencias.js', 'RPC y vistas que la interfaz usa y no existen'],
  ['verificar-revocadas.js', 'RPC revocadas que la interfaz sigue llamando'],
  ['verificar-parametros-rpc.js', 'parametros p_* que la funcion no declara'],
  ['verificar-pantallas-sin-datos.js', 'pantallas que dependen de una asignacion del perfil'],
  ['verificar-estados.js', 'estados comparados contra valores que el esquema no admite'],
];

let fallos = 0;
for (const [archivo, titulo] of PASOS) {
  console.log('\n' + '='.repeat(70));
  console.log(titulo.toUpperCase());
  console.log('='.repeat(70));
  try {
    const salida = execFileSync(process.execPath, [path.join(__dirname, archivo)], {
      cwd: process.cwd(),
      encoding: 'utf8',
    });
    process.stdout.write(salida);
  } catch (e) {
    fallos++;
    console.log('No se pudo ejecutar: ' + (e.message || e));
  }
}

console.log('\n' + '='.repeat(70));
console.log(
  fallos
    ? fallos + ' verificador(es) no pudieron ejecutarse.'
    : 'Los cinco verificadores corrieron. Revisa arriba lo que quedo marcado.'
);
console.log(
  'Los dos ultimos marcan candidatos, no culpables: un estado local de la\n' +
  'interfaz o un entidad_id dentro del nombre de una clave foranea son\n' +
  'falsos positivos normales.'
);
