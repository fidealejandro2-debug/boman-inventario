export type EstadoConsulta = Record<string, string | number | boolean>;

export function leerConsulta<T extends EstadoConsulta>(consulta: string, inicial: T): T {
  const parametros = new URLSearchParams(consulta);
  const estado = { ...inicial };
  for (const clave of Object.keys(inicial) as (keyof T & string)[]) {
    const valor = parametros.get(clave);
    if (valor === null) continue;
    const base = inicial[clave];
    const convertido = typeof base === "boolean" ? (valor === "1" ? true : valor === "0" ? false : base)
      : typeof base === "number" ? (/^\d+$/.test(valor) && Number.isSafeInteger(Number(valor)) && Number(valor) > 0 ? Number(valor) : base)
      : valor;
    estado[clave] = convertido as T[typeof clave];
  }
  return estado;
}

export function escribirConsulta<T extends EstadoConsulta>(consulta: string, estado: T, inicial: T): string {
  const parametros = new URLSearchParams(consulta);
  for (const clave of Object.keys(inicial)) {
    const valor = estado[clave];
    if (valor === inicial[clave]) parametros.delete(clave);
    else parametros.set(clave, typeof valor === "boolean" ? (valor ? "1" : "0") : String(valor));
  }
  const resultado = parametros.toString();
  return resultado ? `?${resultado}` : "";
}
