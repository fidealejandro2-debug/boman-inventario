"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import PersonalTab from "./PersonalTab";
import AusenciasTab from "./AusenciasTab";
import NovedadesTab from "./NovedadesTab";
import DescuentosTab from "./DescuentosTab";
import RolesTab from "./RolesTab";
import ReportesNominaTab from "./ReportesNominaTab";
import ParametrosTab from "./ParametrosTab";
import type { Empleado, Empresa } from "./lib";

type Pestana =
  | "personal"
  | "ausencias"
  | "novedades"
  | "descuentos"
  | "roles"
  | "reportes"
  | "parametros";

const PESTANAS: { id: Pestana; etiqueta: string }[] = [
  { id: "personal", etiqueta: "Personal" },
  { id: "ausencias", etiqueta: "Ausencias y vacaciones" },
  { id: "novedades", etiqueta: "Novedades" },
  { id: "descuentos", etiqueta: "Anticipos y descuentos" },
  { id: "roles", etiqueta: "Roles de pago" },
  { id: "reportes", etiqueta: "Reportes" },
  { id: "parametros", etiqueta: "Parámetros" },
];

export default function NominaCliente({ rol }: { rol: string }) {
  const supabase = createClient();
  const [tab, setTab] = useState<Pestana>("personal");
  const [empleados, setEmpleados] = useState<Empleado[]>([]);
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [grupoId, setGrupoId] = useState("");
  const [listo, setListo] = useState(false);

  // Gerencia consulta pero no escribe: mismo criterio que usuario_puede_nomina.
  const puedeEscribir = rol === "admin" || rol === "nomina";
  const esAdmin = rol === "admin";

  // Personas y empresas las usan casi todas las pestañas: se cargan una vez.
  async function cargarBase() {
    const [e, emp] = await Promise.all([
      supabase
        .from("vista_personal_vigente")
        .select(
          "empleado_id, identificacion, nombre_completo, cargo, estado, afiliado, empresa_afiliacion_id, empresa_pagadora_id"
        )
        .order("nombre_completo"),
      supabase
        .from("empresas")
        .select("id, razon_social, ruc, activo, grupo_id")
        .eq("activo", true)
        .order("razon_social"),
    ]);
    if (!e.error) setEmpleados((e.data as Empleado[]) ?? []);
    if (!emp.error) {
      const filas = (emp.data as (Empresa & { grupo_id: string })[]) ?? [];
      setEmpresas(filas);
      if (filas.length) setGrupoId(filas[0].grupo_id);
    }
    setListo(true);
  }

  useEffect(() => {
    cargarBase();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div className="card">
      <h2>Nómina</h2>
      <p className="ayuda">
        Personal de los tres RUC del grupo. El rol <strong>real</strong> es lo que la
        persona cobra; el <strong>declarado</strong> es lo que consta ante el IESS.
        {!puedeEscribir && " Tu perfil es de solo consulta."}
      </p>

      <div className="tabs">
        {PESTANAS.map((p) => (
          <button
            key={p.id}
            className={`tab ${tab === p.id ? "activo" : ""}`}
            onClick={() => setTab(p.id)}
          >
            {p.etiqueta}
          </button>
        ))}
      </div>

      {!listo ? (
        <p className="ayuda">Cargando…</p>
      ) : (
        <>
          {tab === "personal" && (
            <PersonalTab
              puedeEscribir={puedeEscribir}
              empresas={empresas}
              grupoId={grupoId}
              onCambio={cargarBase}
            />
          )}
          {tab === "ausencias" && (
            <AusenciasTab puedeEscribir={puedeEscribir} empleados={empleados} />
          )}
          {tab === "novedades" && (
            <NovedadesTab
              puedeEscribir={puedeEscribir}
              esAdmin={esAdmin}
              empleados={empleados}
              empresas={empresas}
            />
          )}
          {tab === "descuentos" && (
            <DescuentosTab
              puedeEscribir={puedeEscribir}
              empleados={empleados}
              empresas={empresas}
            />
          )}
          {tab === "roles" && <RolesTab />}
          {tab === "reportes" && <ReportesNominaTab />}
          {tab === "parametros" && <ParametrosTab esAdmin={esAdmin} />}
        </>
      )}
    </div>
  );
}
