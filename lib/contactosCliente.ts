export type ContactoCliente = { tipo: string; valor: string; etiqueta?: string | null; principal?: boolean };
export type DireccionCliente = { direccion: string; etiqueta?: string | null; principal?: boolean };

/** Las filas incompletas se corrigen explícitamente; nunca se descartan al enviar. */
export function validarContactosCliente(contactos: ContactoCliente[], direcciones: DireccionCliente[]): string | null {
  const vistos = new Set<string>();
  for (const [indice, contacto] of contactos.entries()) {
    const valor = contacto.valor.trim();
    if (valor.length < 3) return `Contacto ${indice + 1}: escribe al menos 3 caracteres o quita la fila si no la necesitas.`;
    if (!["telefono", "whatsapp", "email", "otro"].includes(contacto.tipo)) return `Contacto ${indice + 1}: selecciona un tipo válido.`;
    if (contacto.tipo === "email" && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(valor)) return `Contacto ${indice + 1}: revisa la dirección de correo electrónico.`;
    const clave = `${contacto.tipo}:${contacto.tipo === "email" ? valor.toLowerCase() : valor}`;
    if (vistos.has(clave)) return `Contacto ${indice + 1}: este contacto ya está en la lista.`;
    vistos.add(clave);
  }
  const direccionesVistas = new Set<string>();
  for (const [indice, direccion] of direcciones.entries()) {
    const valor = direccion.direccion.trim();
    if (valor.length < 5) return `Dirección ${indice + 1}: escribe al menos 5 caracteres o quita la fila si no la necesitas.`;
    if (direccionesVistas.has(valor)) return `Dirección ${indice + 1}: esta dirección ya está en la lista.`;
    direccionesVistas.add(valor);
  }
  return null;
}
