"use client";

import { useState } from "react";
import PersonalTab from "./PersonalTab";
import RolesTab from "./RolesTab";
import ReportesNominaTab from "./ReportesNominaTab";

type Pestana = "personal" | "roles" | "reportes";

export default function NominaCliente({ rol }: { rol: string }) {
  const [tab, setTab] = useState<Pestana>("personal");
  // Gerencia consulta pero no escribe: mismo criterio que usuario_puede_nomina.
  const puedeEscribir = rol === "admin" || rol === "nomina";

  return (
    <div className="card">
      <h2>Nómina</h2>
      <p className="ayuda">
        Personal de los tres RUC del grupo. El rol <strong>real</strong> es lo que la
        persona cobra; el <strong>declarado</strong> es lo que consta ante el IESS.
        {!puedeEscribir && " Tu perfil es de solo consulta."}
      </p>

      <div className="tabs">
        <button
          className={`tab ${tab === "personal" ? "activo" : ""}`}
          onClick={() => setTab("personal")}
        >
          Personal
        </button>
        <button
          className={`tab ${tab === "roles" ? "activo" : ""}`}
          onClick={() => setTab("roles")}
        >
          Roles de pago
        </button>
        <button
          className={`tab ${tab === "reportes" ? "activo" : ""}`}
          onClick={() => setTab("reportes")}
        >
          Reportes
        </button>
      </div>

      {tab === "personal" && <PersonalTab puedeEscribir={puedeEscribir} />}
      {tab === "roles" && <RolesTab />}
      {tab === "reportes" && <ReportesNominaTab />}
    </div>
  );
}
