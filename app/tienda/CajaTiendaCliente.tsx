"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { RolUsuario } from "@/lib/permisos";
import CajaFranquicia from "@/app/franquicia/CajaFranquicia";
import { mensajeError } from "@/app/franquicia/lib";

type Tienda = {
  id: string;
  nombre: string;
  codigo: string;
};

export default function CajaTiendaCliente({
  rol,
  tiendaInicialId,
}: {
  rol: RolUsuario;
  tiendaInicialId?: string;
}) {
  const supabase = createClient();
  const [tienda, setTienda] = useState<Tienda | null>(null);
  const [tiendas, setTiendas] = useState<Tienda[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Mismo criterio que en franquicias: quien supervisa no opera la caja de un
  // local ajeno, solo la revisa. El titular de la tienda si la opera.
  const esRevision = ["admin", "control", "gerencia"].includes(rol);

  useEffect(() => {
    (async () => {
      if (esRevision) {
        // Una tienda propia es un almacen tipo 'tienda' SIN franquicia activa;
        // es la misma definicion que usa el consolidado (v64).
        const [almacenes, franquicias] = await Promise.all([
          supabase
            .from("almacenes")
            .select("id, nombre, codigo")
            .eq("tipo", "tienda")
            .eq("activo", true)
            .order("nombre"),
          supabase.from("franquicias").select("almacen_id").eq("activo", true),
        ]);
        if (almacenes.error || franquicias.error) {
          setError(mensajeError(almacenes.error ?? franquicias.error));
          setCargando(false);
          return;
        }
        const conFranquicia = new Set(
          ((franquicias.data as { almacen_id: string }[]) ?? []).map((f) => f.almacen_id)
        );
        const propias = ((almacenes.data as Tienda[]) ?? []).filter(
          (a) => !conFranquicia.has(a.id)
        );
        setTiendas(propias);
        setTienda(propias.find((t) => t.id === tiendaInicialId) ?? propias[0] ?? null);
        setCargando(false);
        return;
      }

      // Quien opera no elige local: sale del almacen asignado a su perfil, igual
      // que el franquiciado. El servidor es el que decide, no la interfaz.
      const { data, error: fallo } = await supabase.rpc("almacen_caja_operativo_v71");
      if (fallo) {
        setError(mensajeError(fallo));
        setCargando(false);
        return;
      }
      const fila = ((data as { almacen_id: string }[]) ?? [])[0];
      if (!fila?.almacen_id) {
        setCargando(false);
        return;
      }
      const { data: almacen, error: errAlmacen } = await supabase
        .from("almacenes")
        .select("id, nombre, codigo")
        .eq("id", fila.almacen_id)
        .single();
      if (errAlmacen) setError(mensajeError(errAlmacen));
      else setTienda(almacen as Tienda);
      setCargando(false);
    })();
  }, [supabase, esRevision, tiendaInicialId]);

  if (cargando) return <p className="ayuda">Cargando tienda…</p>;
  if (error) return <p className="error">No se pudo abrir la caja: {error}</p>;

  if (!tienda) {
    return (
      <div className="card">
        <h2>Caja de tienda</h2>
        <p className="aviso">
          {esRevision
            ? "Todavía no hay ninguna tienda propia activa. Las tiendas propias son almacenes de tipo tienda sin franquicia asignada; créalas en Administración → Empresas y locales."
            : "Tu usuario no está asignado a ninguna tienda propia activa. La tienda sale del almacén que tengas asignado, así que pide en Administración que te vinculen al local correspondiente."}
        </p>
      </div>
    );
  }

  return (
    <div className="card">
      <div className="header-row">
        <h2>{tienda.nombre}</h2>
        {esRevision && tiendas.length > 1 && (
          <select
            value={tienda.id}
            onChange={(e) =>
              setTienda(tiendas.find((t) => t.id === e.target.value) ?? tienda)
            }
          >
            {tiendas.map((t) => (
              <option key={t.id} value={t.id}>
                {t.nombre}
              </option>
            ))}
          </select>
        )}
      </div>
      <p className="ayuda">
        Tienda propia <strong>{tienda.codigo}</strong>. Las facturas que importes en
        Ventas entran solas como ingreso, con la fecha en que las registras (la fecha
        de emisión queda en la referencia, porque no siempre coincide con el cobro). La
        caja es un control interno del negocio: <strong>no sustituye la contabilidad</strong>
        {" "}ni los registros tributarios.
      </p>

      <CajaFranquicia
        franquicia={{ almacen_id: tienda.id }}
        soloLectura={esRevision}
        esAdmin={rol === "admin"}
        puedeConciliar={["admin", "control"].includes(rol)}
      />
    </div>
  );
}
