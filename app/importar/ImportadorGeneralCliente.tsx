"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { tienePermiso, type Perfil } from "@/lib/permisos";
import ImportarCatalogo from "@/app/productos/ImportarCatalogo";
import ImportarStockGeneral from "./ImportarStockGeneral";

type Vista = "inicio" | "stock" | "catalogo";
type ProductoActual = { sku: string; nombre: string };

export default function ImportadorGeneralCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const [vista, setVista] = useState<Vista>("inicio");
  const [productos, setProductos] = useState<ProductoActual[]>([]);

  async function cargarProductos() {
    const { data } = await supabase
      .from("productos")
      .select("sku, nombre")
      .eq("activo", true)
      .order("sku");
    setProductos((data ?? []) as ProductoActual[]);
  }

  useEffect(() => { cargarProductos(); }, []);

  const puedeStock = ["admin", "control", "bodega", "tienda", "franquiciado"].includes(perfil.rol);
  const puedeCatalogo = perfil.rol === "admin";
  const puedeVentas = tienePermiso(perfil, "ventas.acceder") || tienePermiso(perfil, "franquicia.ventas");
  const puedeNomina = tienePermiso(perfil, "nomina.editar");

  return (
    <div className="import-page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">DATOS Y MIGRACIONES</span>
          <h1>Centro de importaciones</h1>
          <p>Carga archivos con vista previa, validación e historial dentro del flujo responsable de cada módulo.</p>
        </div>
        {vista !== "inicio" && <button type="button" className="secondary" onClick={() => setVista("inicio")}>Volver al centro</button>}
      </header>

      <div className="import-seguridad">
        <strong>Importación controlada</strong>
        <span>El archivo nunca escribe tablas libremente: cada opción usa permisos, idempotencia y auditoría del proceso correspondiente.</span>
      </div>

      {vista === "inicio" && (
        <section className="import-grid" aria-label="Tipos de importación">
          {puedeStock && (
            <button type="button" className="import-opcion" onClick={() => setVista("stock")}>
              <span className="import-opcion-icono">▦</span>
              <span><strong>Conteo físico de existencias</strong><small>SKU y cantidad desde Excel o CSV. Queda pendiente de revisión por Control.</small></span>
              <b>Importar</b>
            </button>
          )}
          {puedeCatalogo && (
            <button type="button" className="import-opcion" onClick={() => setVista("catalogo")}>
              <span className="import-opcion-icono">◇</span>
              <span><strong>Catálogo de productos</strong><small>Crea o actualiza SKU, descripción, categoría, precio y mínimo sin alterar stock.</small></span>
              <b>Importar</b>
            </button>
          )}
          {puedeVentas && (
            <Link className="import-opcion" href={tienePermiso(perfil, "franquicia.ventas") && !tienePermiso(perfil, "ventas.acceder") ? "/franquicia" : "/ventas"}>
              <span className="import-opcion-icono">XML</span>
              <span><strong>Facturas de venta</strong><small>Procesa comprobantes XML, concilia productos y aplica la salida segura de inventario.</small></span>
              <b>Abrir módulo</b>
            </Link>
          )}
          {puedeNomina && (
            <Link className="import-opcion" href="/nomina">
              <span className="import-opcion-icono">TH</span>
              <span><strong>Novedades de nómina</strong><small>Carga masiva de atrasos, ausencias, descuentos y anticipos para el período.</small></span>
              <b>Abrir módulo</b>
            </Link>
          )}
        </section>
      )}

      {vista === "stock" && puedeStock && <ImportarStockGeneral perfil={perfil} />}
      {vista === "catalogo" && puedeCatalogo && (
        <ImportarCatalogo
          productos={productos}
          alCompletar={cargarProductos}
          alCerrar={() => setVista("inicio")}
        />
      )}
    </div>
  );
}
