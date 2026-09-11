"use client";

import { useMemo, useState } from "react";
import { mostrarAvisoDialogo } from "@/components/Dialogo";
import { createClient } from "@/lib/supabase/client";

export type ColaboradorDiseno = {
  id: string; nombre: string; cargo: string; departamento: string;
  disenador: boolean; mockup: boolean; origen?: "nomina" | "externo";
};

export default function AgregarColaboradorDiseno({
  tipoInicial,
  onCreado,
}: {
  tipoInicial: "disenador" | "mockup";
  onCreado: (persona: ColaboradorDiseno) => void;
}) {
  const supabase = useMemo(() => createClient(), []);
  const [abierto, setAbierto] = useState(false);
  const [nombre, setNombre] = useState("");
  const [contacto, setContacto] = useState("");
  const [disenador, setDisenador] = useState(tipoInicial === "disenador");
  const [mockup, setMockup] = useState(tipoInicial === "mockup");
  const [motivo, setMotivo] = useState("");
  const [guardando, setGuardando] = useState(false);

  function cerrar() {
    if (!guardando) setAbierto(false);
  }

  async function guardar() {
    if (nombre.trim().length < 3) {
      await mostrarAvisoDialogo("Escribe el nombre completo del colaborador.", "Nombre incompleto", true);
      return;
    }
    if (!disenador && !mockup) {
      await mostrarAvisoDialogo("Selecciona si realiza diseño, mockups o ambas funciones.", "Función requerida", true);
      return;
    }
    if (motivo.trim().length < 10) {
      await mostrarAvisoDialogo("El motivo de registro debe tener al menos 10 caracteres.", "Motivo incompleto", true);
      return;
    }
    setGuardando(true);
    const { data, error } = await supabase.rpc("crear_colaborador_diseno_v128", {
      p_nombre: nombre.trim(),
      p_es_disenador: disenador,
      p_es_mockup: mockup,
      p_contacto: contacto.trim() || null,
      p_motivo: motivo.trim(),
      p_idempotency_key: crypto.randomUUID(),
    });
    setGuardando(false);
    if (error) {
      await mostrarAvisoDialogo(
        error.message.includes("crear_colaborador_diseno_v128") ? "Falta instalar v128 en Supabase." : error.message,
        "No se pudo agregar el colaborador",
        true,
      );
      return;
    }
    onCreado(data as ColaboradorDiseno);
    setAbierto(false);
    setNombre(""); setContacto(""); setMotivo("");
    await mostrarAvisoDialogo("Ya aparece en las listas de responsables de diseño.", "Colaborador externo agregado");
  }

  return <>
    <button type="button" className="secondary btn-mini" onClick={() => setAbierto(true)}>＋ Agregar externo</button>
    {abierto && <div className="dlg-fondo no-imprimir" role="dialog" aria-modal="true" onMouseDown={e => { if (e.target === e.currentTarget) cerrar() }}>
      <div className="dlg-caja" style={{ maxWidth: 560 }}>
        <div className="dlg-cabecera"><span className="dlg-marca">BOMAN</span><span className="dlg-titulo">Nuevo colaborador externo</span></div>
        <div className="dlg-cuerpo">
          <p className="dlg-texto">Regístralo una sola vez. Después podrás reutilizarlo en todos los contratos.</p>
          <div className="field"><label>Nombre completo *</label><input autoFocus value={nombre} onChange={e => setNombre(e.target.value)} placeholder="Ej. Andrea Pérez" /></div>
          <div className="field"><label>Contacto</label><input value={contacto} onChange={e => setContacto(e.target.value)} placeholder="Teléfono, correo o empresa" /></div>
          <div style={{ display: "flex", gap: 18, margin: "12px 0" }}>
            <label><input type="checkbox" checked={disenador} onChange={e => setDisenador(e.target.checked)} /> Diseñador</label>
            <label><input type="checkbox" checked={mockup} onChange={e => setMockup(e.target.checked)} /> Diseñador de mockups</label>
          </div>
          <div className="field"><label>Motivo del registro *</label><textarea rows={3} value={motivo} onChange={e => setMotivo(e.target.value)} placeholder="Ej. Apoyo externo contratado para diseños" /></div>
          <div className="dlg-contador">Quedará registrado con tu usuario y fecha.</div>
        </div>
        <div className="dlg-acciones"><button type="button" className="secondary" disabled={guardando} onClick={cerrar}>Cancelar</button><button type="button" disabled={guardando} onClick={() => void guardar()}>{guardando ? "Guardando…" : "Agregar colaborador"}</button></div>
      </div>
    </div>}
  </>;
}
