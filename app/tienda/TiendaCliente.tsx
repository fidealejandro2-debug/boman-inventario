"use client";

// Panel unificado de tienda propia, mismo patrón que FranquiciaCliente.tsx
// (app/franquicia/FranquiciaCliente.tsx) pero para almacenes tipo='tienda'
// SIN fila en franquicias (ver sql/v71_caja_tienda_propia.sql). Antes solo
// existía la pestaña de Caja (CajaTiendaCliente, ahora integrada aquí); el
// resto vivía repartido en /ventas, /inventario, /conteos.
//
// Factura XML, Inventario y Conteo físico van como enlace a la pantalla
// general (no embebidas): esas 3 pantallas ya funcionan para el rol
// 'tienda' sin ningún cambio, y son grandes/probadas -duplicar su lógica
// aquí solo arriesgaría que las dos copias diverjan con el tiempo.

import Link from "next/link";
import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { RolUsuario } from "@/lib/permisos";
import { mensajeError } from "@/app/franquicia/lib";
import CajaFranquicia from "@/app/franquicia/CajaFranquicia";
import VentaRapidaTienda from "./VentaRapidaTienda";
import EgresosTienda from "./EgresosTienda";

type Tienda = { id: string; nombre: string; codigo: string };
type Pestana = "ventas" | "factura" | "egresos" | "caja" | "inventario" | "conteo";

export default function TiendaCliente({ rol, tiendaInicialId }: { rol: RolUsuario; tiendaInicialId?: string }) {
  const supabase = createClient();
  const [tienda, setTienda] = useState<Tienda | null>(null);
  const [tiendas, setTiendas] = useState<Tienda[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Pestana>("ventas");

  // Mismo criterio que en franquicias: quien supervisa no opera la caja/
  // ventas de un local ajeno, solo lo revisa. El titular de la tienda sí.
  const esRevision = ["admin", "control", "gerencia"].includes(rol);

  useEffect(() => {
    (async () => {
      if (esRevision) {
        const [almacenes, franquicias] = await Promise.all([
          supabase.from("almacenes").select("id, nombre, codigo").eq("tipo", "tienda").eq("activo", true).order("nombre"),
          supabase.from("franquicias").select("almacen_id").eq("activo", true),
        ]);
        if (almacenes.error || franquicias.error) {
          setError(mensajeError(almacenes.error ?? franquicias.error));
          setCargando(false);
          return;
        }
        const conFranquicia = new Set(((franquicias.data as { almacen_id: string }[]) ?? []).map((f) => f.almacen_id));
        const propias = ((almacenes.data as Tienda[]) ?? []).filter((a) => !conFranquicia.has(a.id));
        setTiendas(propias);
        setTienda(propias.find((t) => t.id === tiendaInicialId) ?? propias[0] ?? null);
        setCargando(false);
        return;
      }

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
        .from("almacenes").select("id, nombre, codigo").eq("id", fila.almacen_id).single();
      if (errAlmacen) setError(mensajeError(errAlmacen));
      else setTienda(almacen as Tienda);
      setCargando(false);
    })();
  }, [supabase, esRevision, tiendaInicialId]);

  if (cargando) return <p className="ayuda">Cargando tienda…</p>;
  if (error) return <p className="error">No se pudo abrir la tienda: {error}</p>;

  if (!tienda) {
    return (
      <div className="card">
        <h2>Tienda propia</h2>
        <p className="aviso">
          {esRevision
            ? "Todavía no hay ninguna tienda propia activa. Las tiendas propias son almacenes de tipo tienda sin franquicia asignada; créalas en Administración → Empresas y locales."
            : "Tu usuario no está asignado a ninguna tienda propia activa. La tienda sale del almacén que tengas asignado, así que pide en Administración que te vinculen al local correspondiente."}
        </p>
      </div>
    );
  }

  const pestanas: { id: Pestana; etiqueta: string }[] = [
    { id: "ventas", etiqueta: "Venta rápida" },
    { id: "factura", etiqueta: "Factura XML" },
    { id: "egresos", etiqueta: "Egresos" },
    { id: "caja", etiqueta: "Caja" },
    { id: "inventario", etiqueta: "Inventario" },
    { id: "conteo", etiqueta: "Conteo físico" },
  ];

  return (
    <div className="card">
      <div className="header-row">
        <h2>{tienda.nombre}</h2>
        {esRevision && tiendas.length > 1 && (
          <select value={tienda.id} onChange={(e) => setTienda(tiendas.find((t) => t.id === e.target.value) ?? tienda)}>
            {tiendas.map((t) => <option key={t.id} value={t.id}>{t.nombre}</option>)}
          </select>
        )}
      </div>
      <p className="ayuda">
        Tienda propia <strong>{tienda.codigo}</strong>. La caja es un control interno del
        negocio: <strong>no sustituye la contabilidad</strong> ni los registros tributarios.
      </p>

      <div className="tabs">
        {pestanas.map((p) => (
          <button key={p.id} className={`tab ${tab === p.id ? "activo" : ""}`} onClick={() => setTab(p.id)}>
            {p.etiqueta}
          </button>
        ))}
      </div>

      {tab === "ventas" && <VentaRapidaTienda almacenId={tienda.id} soloLectura={esRevision} />}

      {tab === "factura" && (
        <div className="card-interna">
          <h4>Factura XML</h4>
          <p className="ayuda">
            Las facturas XML que importes en Ventas entran solas como ingreso de caja, con la
            fecha en que las registras. Esta pantalla ya está lista para tu tienda: al entrar,
            el almacén queda preseleccionado.
          </p>
          <Link className="btn-enlace" href="/ventas">Ir a Ventas → Importar factura XML</Link>
        </div>
      )}

      {tab === "egresos" && <EgresosTienda almacenId={tienda.id} soloLectura={esRevision} />}

      {tab === "caja" && (
        <CajaFranquicia
          franquicia={{ almacen_id: tienda.id }}
          soloLectura={esRevision}
          esAdmin={rol === "admin"}
          puedeReabrir={rol === "admin"}
          puedeConciliar={["admin", "control"].includes(rol)}
        />
      )}

      {tab === "inventario" && (
        <div className="card-interna">
          <h4>Inventario</h4>
          <p className="ayuda">Stock, reposición y ajustes de tu local, en la pantalla general de inventario.</p>
          <Link className="btn-enlace" href="/inventario">Ir a Inventario</Link>
        </div>
      )}

      {tab === "conteo" && (
        <div className="card-interna">
          <h4>Conteo físico</h4>
          <p className="ayuda">Los conteos de tu tienda se registran y revisan en la pantalla general de conteos.</p>
          <Link className="btn-enlace" href="/conteos">Ir a Conteos</Link>
        </div>
      )}
    </div>
  );
}
