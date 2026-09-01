"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
// Desde lib/permisos y no desde lib/getPerfil: este es un componente cliente
// y getPerfil arrastra el cliente de servidor de Supabase, que usa next/headers.
import { tienePermiso, type PermisoCodigo, type RolUsuario } from "@/lib/permisos";
import VentasFranquicia from "./VentasFranquicia";
import CajaFranquicia from "./CajaFranquicia";
import InventarioFranquicia from "./InventarioFranquicia";
import FacturaXmlFranquicia from "./FacturaXmlFranquicia";

export type Franquicia = {
  id: string;
  nombre: string;
  codigo: string;
  ciudad: string | null;
  almacen_id: string;
  empresa_id: string;
};

type Pestana = "ventas" | "factura" | "caja" | "inventario";

export default function FranquiciaCliente({
  rol,
  permisos,
}: {
  rol: RolUsuario;
  permisos: PermisoCodigo[];
}) {
  const perfil = { rol, permisos };
  const supabase = createClient();
  const [franquicia, setFranquicia] = useState<Franquicia | null>(null);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Pestana>("ventas");

  const puedeVender = tienePermiso(perfil, "franquicia.ventas");
  const puedeCaja = tienePermiso(perfil, "franquicia.caja");
  const puedeInventario = tienePermiso(perfil, "franquicia.inventario");

  useEffect(() => {
    (async () => {
      // La franquicia sale del almacén asignado al perfil: el usuario no la
      // elige, así queda aislado de los demás locales del grupo.
      const { data: id, error: errId } = await supabase.rpc(
        "franquicia_usuario_actual_v42"
      );
      if (errId) {
        setError(errId.message);
        setCargando(false);
        return;
      }
      if (!id) {
        setCargando(false);
        return;
      }
      const { data, error } = await supabase
        .from("franquicias")
        .select("id, nombre, codigo, ciudad, almacen_id, empresa_id")
        .eq("id", id)
        .single();
      if (error) setError(error.message);
      else setFranquicia(data as Franquicia);
      setCargando(false);
    })();
  }, [supabase]);

  if (cargando) return <p className="ayuda">Cargando local…</p>;
  if (error) return <p className="error">No se pudo abrir el local: {error}</p>;

  if (!franquicia) {
    return (
      <div className="card">
        <h2>Franquicia</h2>
        <p className="aviso">
          Tu usuario no está asignado a ninguna franquicia activa. La franquicia se
          determina por el almacén que tengas asignado, así que pide en Administración
          que te vinculen al local correspondiente.
        </p>
      </div>
    );
  }

  const pestanas: { id: Pestana; etiqueta: string; visible: boolean }[] = [
    { id: "ventas", etiqueta: "Venta rápida", visible: puedeVender },
    { id: "factura", etiqueta: "Factura XML", visible: puedeVender },
    { id: "caja", etiqueta: "Caja", visible: puedeCaja },
    { id: "inventario", etiqueta: "Inventario", visible: puedeInventario },
  ];
  const visibles = pestanas.filter((p) => p.visible);

  return (
    <div className="card">
      <h2>{franquicia.nombre}</h2>
      <p className="ayuda">
        Local <strong>{franquicia.codigo}</strong>
        {franquicia.ciudad ? ` · ${franquicia.ciudad}` : ""}. Las ventas descuentan el
        stock del local automáticamente. La caja es un control interno del negocio: no
        sustituye la contabilidad ni los registros tributarios.
      </p>

      {!visibles.length ? (
        <p className="aviso">
          Tienes acceso al local pero sin permisos para operarlo. Pide que te habiliten
          ventas, caja o inventario en Administración → Permisos por rol.
        </p>
      ) : (
        <>
          <div className="tabs">
            {visibles.map((p) => (
              <button
                key={p.id}
                className={`tab ${tab === p.id ? "activo" : ""}`}
                onClick={() => setTab(p.id)}
              >
                {p.etiqueta}
              </button>
            ))}
          </div>

          {tab === "ventas" && puedeVender && (
            <VentasFranquicia franquicia={franquicia} />
          )}
          {tab === "factura" && puedeVender && (
            <FacturaXmlFranquicia franquicia={franquicia} />
          )}
          {tab === "caja" && puedeCaja && <CajaFranquicia franquicia={franquicia} />}
          {tab === "inventario" && puedeInventario && (
            <InventarioFranquicia franquicia={franquicia} />
          )}
        </>
      )}
    </div>
  );
}
