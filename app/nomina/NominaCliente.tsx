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
import AuditoriaTab from "./AuditoriaTab";
import VinculosTab from "./VinculosTab";
import ExpedienteTab from "./ExpedienteTab";
import DepartamentosTab from "./DepartamentosTab";
import CargasFamiliaresTab from "./CargasFamiliaresTab";
import ImportacionNominaTab from "./ImportacionNominaTab";
import type { PermisoCodigo } from "@/lib/permisos";
import type { Departamento, Empleado, Empresa } from "./lib";

type Pestana =
  | "personal"
  | "departamentos"
  | "cargas"
  | "expediente"
  | "vinculos"
  | "ausencias"
  | "novedades"
  | "descuentos"
  | "importacion"
  | "roles"
  | "reportes"
  | "auditoria"
  | "parametros";

const PESTANAS: { id: Pestana; etiqueta: string }[] = [
  { id: "personal", etiqueta: "Personal" },
  { id: "departamentos", etiqueta: "Departamentos" },
  { id: "cargas", etiqueta: "Cargas familiares" },
  { id: "expediente", etiqueta: "Expediente" },
  { id: "vinculos", etiqueta: "Ingresos y salidas" },
  { id: "ausencias", etiqueta: "Ausencias y vacaciones" },
  { id: "novedades", etiqueta: "Novedades" },
  { id: "descuentos", etiqueta: "Anticipos y descuentos" },
  { id: "importacion", etiqueta: "Carga masiva" },
  { id: "roles", etiqueta: "Roles de pago" },
  { id: "reportes", etiqueta: "Reportes" },
  { id: "auditoria", etiqueta: "Auditoría" },
  { id: "parametros", etiqueta: "Parámetros" },
];

export default function NominaCliente({
  rol,
  permisos,
}: {
  rol: string;
  permisos: PermisoCodigo[];
}) {
  const supabase = createClient();
  const [tab, setTab] = useState<Pestana>("personal");
  const [empleados, setEmpleados] = useState<Empleado[]>([]);
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [departamentos, setDepartamentos] = useState<Departamento[]>([]);
  const [grupoId, setGrupoId] = useState("");
  const [listo, setListo] = useState(false);

  // Gerencia consulta pero no escribe: mismo criterio que usuario_puede_nomina.
  const puedeEscribir = rol === "admin" || permisos.includes("nomina.editar");
  const esAdmin = rol === "admin";

  // Personas y empresas las usan casi todas las pestañas: se cargan una vez.
  async function cargarBase() {
    const [e, emp, dep] = await Promise.all([
      supabase
        .from("vista_personal_vigente")
        .select(
          "empleado_id, identificacion, nombre_completo, cargo, departamento_id, departamento_nombre, estado, afiliado, empresa_afiliacion_id, empresa_pagadora_id"
        )
        .order("nombre_completo"),
      supabase
        .from("empresas")
        .select("id, razon_social, ruc, activo, grupo_id")
        .eq("activo", true)
        .order("razon_social"),
      supabase
        .from("vista_departamentos_nomina_v34")
        .select("*")
        .order("nombre"),
    ]);
    if (!e.error) setEmpleados((e.data as Empleado[]) ?? []);
    if (!dep.error) setDepartamentos((dep.data as Departamento[]) ?? []);
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
              departamentos={departamentos}
              grupoId={grupoId}
              onCambio={cargarBase}
            />
          )}
          {tab === "departamentos" && (
            <DepartamentosTab
              puedeEscribir={puedeEscribir}
              grupoId={grupoId}
              departamentos={departamentos}
              empleados={empleados}
              onCambio={cargarBase}
            />
          )}
          {tab === "cargas" && (
            <CargasFamiliaresTab
              puedeEscribir={puedeEscribir}
              empleados={empleados}
            />
          )}
          {tab === "expediente" && (
            <ExpedienteTab puedeEscribir={puedeEscribir} empleados={empleados} />
          )}
          {tab === "vinculos" && <VinculosTab puedeEscribir={puedeEscribir} />}
          {tab === "ausencias" && (
            <AusenciasTab
              puedeEscribir={puedeEscribir}
              empleados={empleados}
              grupoId={grupoId}
            />
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
          {tab === "importacion" && (
            <ImportacionNominaTab
              puedeEscribir={puedeEscribir}
              empleados={empleados}
              empresas={empresas}
            />
          )}
          {tab === "roles" && <RolesTab />}
          {tab === "reportes" && <ReportesNominaTab />}
          {tab === "auditoria" && <AuditoriaTab />}
          {tab === "parametros" && <ParametrosTab esAdmin={esAdmin} />}
        </>
      )}
    </div>
  );
}
