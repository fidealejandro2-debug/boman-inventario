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
  const [cargando, setCargando] = useState(true);

  useEffect(() => {
    (async () => {
      const [s, m] = await Promise.all([
        supabase.from("vista_stock").select("producto_id, cantidad, bajo_minimo, almacen, producto, sku, talla, stock_minimo"),
        supabase.from("movimientos")
          .select("id, tipo, cantidad, created_at, productos(nombre, sku), almacenes(nombre), almacen_destino:entidad_destino_id(nombre), perfiles(nombre_completo)")
          .order("created_at", { ascending: false }).limit(10),
      ]);
      if (s.data) setFilas(s.data);
      if (m.data) setMovs(m.data);
      setCargando(false);
    })();
  }, []);

  const totalUnidades = filas.reduce((a, f) => a + f.cantidad, 0);
  const skusConStock = new Set(filas.filter((f) => f.cantidad > 0).map((f) => f.producto_id)).size;
  const alertas = useMemo(() => filas.filter((f) => f.bajo_minimo).sort((a, b) => a.cantidad - b.cantidad), [filas]);
  const hoy = movs.filter((m) => new Date(m.created_at).toDateString() === new Date().toDateString()).length;

  const puedeVerReportes = perfil.rol === "admin" || perfil.rol === "gerencia";

  return (
    <>
      <h2 style={{ color: "#1f3864" }}>Hola, {perfil.nombre_completo.split(" ")[0]}</h2>

      {cargando ? <div className="card"><div className="vacio">Cargando...</div></div> : (
        <>
          <div className="kpis">
            <div className="kpi"><div className="label">Unidades en stock</div><div className="valor">{totalUnidades.toLocaleString("es-EC")}</div></div>
            <div className="kpi"><div className="label">SKUs con stock</div><div className="valor">{skusConStock}</div></div>
            <div className={`kpi ${alertas.length ? "alerta" : "ok"}`}><div className="label">Alertas de stock</div><div className="valor">{alertas.length}</div></div>
            <div className="kpi"><div className="label">Movimientos hoy</div><div className="valor">{hoy}</div></div>
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
                      <td>{f.producto}<div style={{ fontSize: 12, color: "#991b1b" }}>{f.sku}</div></td>
                      <td>{f.talla ?? "-"}</td><td>{f.almacen}</td>
                      <td className="num">{f.cantidad}</td><td className="num">{f.stock_minimo}</td>
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
                  <tr key={m.id}>
                    <td style={{ whiteSpace: "nowrap" }}>{fecha(m.created_at)}</td>
                    <td><span className={`badge ${m.tipo}`}>{ETIQUETA_TIPO[m.tipo] ?? m.tipo}</span></td>
                    <td>{m.productos?.nombre}</td>
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
