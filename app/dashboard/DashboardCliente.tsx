"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { fecha, ETIQUETA_TIPO } from "@/lib/utils";
import type { Perfil } from "@/lib/getPerfil";

export default function DashboardCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const [filas, setFilas] = useState<any[]>([]);
  const [movs, setMovs] = useState<any[]>([]);
  const [movimientosHoy, setMovimientosHoy] = useState(0);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const inicioHoy = new Date();
      inicioHoy.setHours(0, 0, 0, 0);
      const finHoy = new Date(inicioHoy);
      finHoy.setDate(finHoy.getDate() + 1);

      const [s, m, h] = await Promise.all([
        supabase.from("vista_stock_operativo").select("producto_id, stock_fisico, stock_disponible, transito_entrada, bajo_minimo, sugerido_reponer, almacen, producto, sku, categoria, subcategoria, talla, stock_minimo"),
        supabase.from("movimientos")
          .select("id, tipo, cantidad, created_at, anulado, productos(nombre, sku, categoria, subcategoria), almacenes!movimientos_entidad_id_fkey(nombre), almacen_destino:almacenes!movimientos_entidad_destino_id_fkey(nombre), perfiles!movimientos_usuario_id_fkey(nombre_completo)")
          .order("created_at", { ascending: false }).limit(10),
        supabase.from("movimientos")
          .select("id", { count: "exact", head: true })
          .eq("anulado", false)
          .gte("created_at", inicioHoy.toISOString())
          .lt("created_at", finHoy.toISOString()),
      ]);
      if (s.error || m.error || h.error) setError(s.error?.message ?? m.error?.message ?? h.error?.message ?? null);
      if (s.data) setFilas(s.data);
      if (m.data) setMovs(m.data);
      setMovimientosHoy(h.count ?? 0);
      setCargando(false);
    })();
  }, []);

  const totalUnidades = filas.reduce((a, f) => a + f.stock_fisico, 0);
  const totalDisponible = filas.reduce((a, f) => a + f.stock_disponible, 0);
  const totalTransito = filas.reduce((a, f) => a + f.transito_entrada, 0);
  const alertas = useMemo(() => filas.filter((f) => f.bajo_minimo).sort((a, b) => a.stock_disponible - b.stock_disponible), [filas]);
  const puedeVerReportes = ["admin", "control", "gerencia"].includes(perfil.rol);

  return (
    <>
      <h2 style={{ color: "#1f3864" }}>Hola, {perfil.nombre_completo.split(" ")[0]}</h2>

      {error && <div className="error">No se pudieron cargar los datos: {error}</div>}
      {cargando ? <div className="card"><div className="vacio">Cargando...</div></div> : (
        <>
          <div className="kpis">
            <div className="kpi"><div className="label">Unidades en stock</div><div className="valor">{totalUnidades.toLocaleString("es-EC")}</div></div>
            <div className="kpi"><div className="label">Stock disponible</div><div className="valor">{totalDisponible.toLocaleString("es-EC")}</div></div>
            <div className={`kpi ${alertas.length ? "alerta" : "ok"}`}><div className="label">Alertas de stock</div><div className="valor">{alertas.length}</div></div>
            <div className="kpi"><div className="label">En tránsito / movimientos hoy</div><div className="valor">{totalTransito.toLocaleString("es-EC")} <small>/ {movimientosHoy}</small></div></div>
          </div>

          <div className="acciones-rapidas" aria-label="Acciones rápidas">
            {['admin', 'bodega'].includes(perfil.rol) && (
              <Link href="/movimientos" className="accion-rapida">
                <span>↕</span><div><strong>Entrada o salida manual</strong><small>Con referencia obligatoria y trazabilidad</small></div>
              </Link>
            )}
            {perfil.rol !== 'gerencia' && (
              <Link href="/operaciones" className="accion-rapida">
                <span>⇄</span><div><strong>Solicitudes y transferencias</strong><small>Solicitar, preparar, despachar o recibir</small></div>
              </Link>
            )}
            {!['logistica', 'gerencia'].includes(perfil.rol) && (
              <Link href="/conteos" className="accion-rapida">
                <span>✓</span><div><strong>Conteos físicos</strong><small>Conteo ciego y aprobación de diferencias</small></div>
              </Link>
            )}
            {perfil.rol === 'admin' && (
              <Link href="/productos" className="accion-rapida">
                <span>＋</span><div><strong>Gestionar productos</strong><small>Catálogo, precios y categorías</small></div>
              </Link>
            )}
            {puedeVerReportes && (
              <Link href="/reportes" className="accion-rapida">
                <span>▥</span><div><strong>Ver reportes</strong><small>Stock, valor, alertas y kardex</small></div>
              </Link>
            )}
            {(perfil.rol === 'admin' || perfil.rol === 'control') && (
              <Link href="/control" className="accion-rapida">
                <span>⚑</span><div><strong>Centro de Control</strong><small>Aprobaciones, diferencias e incidencias</small></div>
              </Link>
            )}
          </div>

          {alertas.length > 0 && (
            <div className="card">
              <div className="header-row">
                <h3>⚠ Requieren reposición</h3>
                {puedeVerReportes && <Link href="/reportes" style={{ fontSize: 13, color: "#2e75b6" }}>Ver reporte completo →</Link>}
              </div>
              <table>
                <thead><tr><th>Producto</th><th>Talla</th><th>Almacén</th><th className="num">Actual</th><th className="num">Mínimo</th></tr></thead>
                <tbody>
                  {alertas.slice(0, 8).map((f, i) => (
                    <tr key={i} className="fila-alerta">
                      <td>
                        {f.producto}
                        <div style={{ fontSize: 12, color: "#991b1b" }}>{f.sku}</div>
                        <div style={{ fontSize: 11, color: "#6b7280" }}>
                          {f.categoria ?? "Sin categoría"}{f.subcategoria ? ` / ${f.subcategoria}` : ""}
                        </div>
                      </td>
                      <td>{f.talla ?? "-"}</td><td>{f.almacen}</td>
                      <td className="num">{f.stock_disponible}</td><td className="num">{f.stock_minimo}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {alertas.length > 8 && <p style={{ fontSize: 13, color: "#6b7280" }}>y {alertas.length - 8} más...</p>}
            </div>
          )}

          <div className="card">
            <div className="header-row">
              <h3>Actividad reciente</h3>
              <Link href="/movimientos" style={{ fontSize: 13, color: "#2e75b6" }}>Ver todo →</Link>
            </div>
            <table>
              <thead><tr><th>Fecha</th><th>Tipo</th><th>Producto</th><th>Almacén</th><th className="num">Cant.</th><th>Usuario</th></tr></thead>
              <tbody>
                {movs.map((m) => (
                  <tr key={m.id} className={m.anulado ? "fila-anulada" : ""}>
                    <td style={{ whiteSpace: "nowrap" }}>{fecha(m.created_at)}</td>
                    <td>
                      <span className={`badge ${m.tipo}`}>{ETIQUETA_TIPO[m.tipo] ?? m.tipo}</span>
                      {m.anulado && <span className="badge anulado" style={{ marginLeft: 4 }}>ANULADO</span>}
                    </td>
                    <td>
                      {m.productos?.nombre}
                      {(m.productos?.categoria || m.productos?.subcategoria) && (
                        <div style={{ fontSize: 11, color: "#6b7280" }}>
                          {m.productos?.categoria ?? "Sin categoría"}{m.productos?.subcategoria ? ` / ${m.productos.subcategoria}` : ""}
                        </div>
                      )}
                    </td>
                    <td>{m.almacenes?.nombre}{m.almacen_destino ? ` → ${m.almacen_destino.nombre}` : ""}</td>
                    <td className="num">{m.cantidad}</td>
                    <td>{m.perfiles?.nombre_completo}</td>
                  </tr>
                ))}
                {!movs.length && <tr><td colSpan={6} className="vacio">Sin movimientos registrados aún.</td></tr>}
              </tbody>
            </table>
          </div>
        </>
      )}
    </>
  );
}
