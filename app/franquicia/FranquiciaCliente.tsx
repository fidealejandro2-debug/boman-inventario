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
import AlertasFranquicia from "./AlertasFranquicia";
import MensualFranquicia from "./MensualFranquicia";

export type Franquicia = {
  id: string;
  nombre: string;
  codigo: string;
  ciudad: string | null;
  almacen_id: string;
  empresa_id: string;
};

type Pestana = "ventas" | "factura" | "caja" | "inventario" | "alertas" | "mensual";

export default function FranquiciaCliente({
  rol,
  permisos,
  franquiciaInicialId,
}: {
  rol: RolUsuario;
  permisos: PermisoCodigo[];
  franquiciaInicialId?: string;
}) {
  const perfil = { rol, permisos };
  const supabase = createClient();
  const [franquicia, setFranquicia] = useState<Franquicia | null>(null);
  const [locales, setLocales] = useState<Franquicia[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Pestana>("ventas");

  // Admin, Control y Gerencia no tienen local propio: entran a revisar
  // cualquiera. usuario_puede_franquicia_v42 ya les da lectura sobre todos, asi
  // que el panel solo tiene que dejarlos elegir y esconder lo que es de operacion.
  const esRevision = ["admin", "control", "gerencia"].includes(rol);

  const puedeVender = tienePermiso(perfil, "franquicia.ventas") && !esRevision;
  const puedeCaja = tienePermiso(perfil, "franquicia.caja") || esRevision;
  const puedePrecio = tienePermiso(perfil, "franquicia.precio_libre");
  const puedeDescuento = tienePermiso(perfil, "franquicia.descuento");
  const puedeInventario = tienePermiso(perfil, "franquicia.inventario") || esRevision;
  const puedeReposicion = tienePermiso(perfil, "franquicia.reposicion") || esRevision;

  useEffect(() => {
    (async () => {
      if (esRevision) {
        const { data, error } = await supabase
          .from("franquicias")
          .select("id, nombre, codigo, ciudad, almacen_id, empresa_id")
          .eq("activo", true)
          .order("nombre");
        if (error) setError(error.message);
        else {
          const lista = (data as Franquicia[]) ?? [];
          setLocales(lista);
          setFranquicia(
            lista.find((local) => local.id === franquiciaInicialId) ?? lista[0] ?? null
          );
        }
        setCargando(false);
        return;
      }

      // Para quien opera, la franquicia sale del almacén asignado al perfil: no
      // la elige, así queda aislado de los demás locales del grupo.
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
  }, [supabase, esRevision, franquiciaInicialId]);

  if (cargando) return <p className="ayuda">Cargando local…</p>;
  if (error) return <p className="error">No se pudo abrir el local: {error}</p>;

  if (!franquicia) {
    return (
      <div className="card">
        <h2>Franquicia</h2>
        <p className="aviso">
          {esRevision
            ? "Todavía no hay ningún local activo. Créalo en Administración → Franquicias."
            : "Tu usuario no está asignado a ninguna franquicia activa. La franquicia se determina por el almacén que tengas asignado, así que pide en Administración que te vinculen al local correspondiente."}
        </p>
      </div>
    );
  }

  const pestanas: { id: Pestana; etiqueta: string; visible: boolean }[] = [
    { id: "ventas", etiqueta: "Venta rápida", visible: puedeVender },
    { id: "factura", etiqueta: "Factura XML", visible: puedeVender },
    { id: "caja", etiqueta: "Caja", visible: puedeCaja },
    { id: "mensual", etiqueta: "Mensual", visible: puedeCaja },
    { id: "inventario", etiqueta: "Inventario", visible: puedeInventario },
    { id: "alertas", etiqueta: "Alertas", visible: puedeReposicion },
  ];
  const visibles = pestanas.filter((p) => p.visible);
  // Si Administracion deshabilita el permiso de la pestana que estaba activa,
  // abre la primera permitida en vez de dejar el panel aparentemente vacio.
  const tabActiva = visibles.some((p) => p.id === tab) ? tab : visibles[0]?.id;

  return (
    <div className="card">
      <div className="header-row">
        <h2>{franquicia.nombre}</h2>
        {esRevision && locales.length > 1 && (
          <select
            value={franquicia.id}
            onChange={(e) =>
              setFranquicia(locales.find((l) => l.id === e.target.value) ?? franquicia)
            }
          >
            {locales.map((l) => (
              <option key={l.id} value={l.id}>
                {l.nombre}
              </option>
            ))}
          </select>
        )}
      </div>
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
                className={`tab ${tabActiva === p.id ? "activo" : ""}`}
                onClick={() => setTab(p.id)}
              >
                {p.etiqueta}
              </button>
            ))}
          </div>

          {tabActiva === "ventas" && puedeVender && (
            <VentasFranquicia
              franquicia={franquicia}
              puedePrecio={puedePrecio}
              puedeDescuento={puedeDescuento}
            />
          )}
          {tabActiva === "factura" && puedeVender && (
            <FacturaXmlFranquicia franquicia={franquicia} />
          )}
          {tabActiva === "caja" && puedeCaja && <CajaFranquicia franquicia={franquicia} soloLectura={esRevision} />}
          {tabActiva === "inventario" && puedeInventario && (
            <InventarioFranquicia franquicia={franquicia} soloLectura={esRevision} />
          )}
          {tabActiva === "mensual" && puedeCaja && (
            <MensualFranquicia franquicia={franquicia} />
          )}
          {tabActiva === "alertas" && puedeReposicion && (
            <AlertasFranquicia franquicia={franquicia} />
          )}
        </>
      )}
    </div>
  );
}
