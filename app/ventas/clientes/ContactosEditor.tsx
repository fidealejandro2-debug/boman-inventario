"use client";

import type { ContactoCliente, DireccionCliente } from "@/lib/contactosCliente";
import estilos from "./Clientes.module.css";

export default function ContactosEditor({ contactos, direcciones, onContactos, onDirecciones }: {
  contactos: ContactoCliente[]; direcciones: DireccionCliente[];
  onContactos: (filas: ContactoCliente[]) => void; onDirecciones: (filas: DireccionCliente[]) => void;
}) {
  return <div className={estilos.ancho}>
    <div className={estilos.editorCabecera}><h3>Contactos</h3><button type="button" className="secondary" onClick={() => onContactos([...contactos, { tipo: "telefono", valor: "", etiqueta: "" }])}>+ Agregar contacto</button></div>
    {!contactos.length && <p className="ayuda">Agrega un teléfono, WhatsApp o correo para contactar al cliente.</p>}
    {contactos.map((contacto, indice) => <fieldset className={estilos.contactoFila} key={indice}>
      <legend>Contacto {indice + 1}</legend>
      <label>Tipo<select value={contacto.tipo} onChange={e => onContactos(contactos.map((fila, i) => i === indice ? { ...fila, tipo: e.target.value } : fila))}><option value="telefono">Teléfono</option><option value="whatsapp">WhatsApp</option><option value="email">Correo electrónico</option><option value="otro">Otro</option></select></label>
      <label>{contacto.tipo === "email" ? "Correo electrónico" : contacto.tipo === "otro" ? "Contacto" : "Número"} *<input type={contacto.tipo === "email" ? "email" : contacto.tipo === "otro" ? "text" : "tel"} value={contacto.valor} placeholder={contacto.tipo === "email" ? "nombre@empresa.com" : "Escribe el contacto"} onChange={e => onContactos(contactos.map((fila, i) => i === indice ? { ...fila, valor: e.target.value } : fila))}/></label>
      <label>Etiqueta<input value={contacto.etiqueta ?? ""} placeholder="Ej.: Compras" onChange={e => onContactos(contactos.map((fila, i) => i === indice ? { ...fila, etiqueta: e.target.value } : fila))}/></label>
      <label className={estilos.principal}><input type="checkbox" checked={Boolean(contacto.principal)} onChange={e => onContactos(contactos.map((fila, i) => i === indice ? { ...fila, principal: e.target.checked } : fila))}/> Principal</label>
      <button type="button" className="secondary" aria-label={`Quitar contacto ${indice + 1}`} onClick={() => onContactos(contactos.filter((_, i) => i !== indice))}>Quitar</button>
    </fieldset>)}
    <div className={estilos.editorCabecera}><h3>Direcciones</h3><button type="button" className="secondary" onClick={() => onDirecciones([...direcciones, { direccion: "", etiqueta: "" }])}>+ Agregar dirección</button></div>
    {!direcciones.length && <p className="ayuda">Puedes añadir una dirección de entrega o facturación.</p>}
    {direcciones.map((direccion, indice) => <fieldset className={`${estilos.contactoFila} ${estilos.direccionFila}`} key={indice}>
      <legend>Dirección {indice + 1}</legend>
      <label>Dirección completa *<input value={direccion.direccion} placeholder="Ciudad, calle y referencia" onChange={e => onDirecciones(direcciones.map((fila, i) => i === indice ? { ...fila, direccion: e.target.value } : fila))}/></label>
      <label>Etiqueta<input value={direccion.etiqueta ?? ""} placeholder="Ej.: Entregas" onChange={e => onDirecciones(direcciones.map((fila, i) => i === indice ? { ...fila, etiqueta: e.target.value } : fila))}/></label>
      <label className={estilos.principal}><input type="checkbox" checked={Boolean(direccion.principal)} onChange={e => onDirecciones(direcciones.map((fila, i) => i === indice ? { ...fila, principal: e.target.checked } : fila))}/> Principal</label>
      <button type="button" className="secondary" aria-label={`Quitar dirección ${indice + 1}`} onClick={() => onDirecciones(direcciones.filter((_, i) => i !== indice))}>Quitar</button>
    </fieldset>)}
  </div>;
}
