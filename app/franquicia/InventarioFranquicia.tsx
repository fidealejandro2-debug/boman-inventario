"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { exportarCSV } from "@/lib/utils";
import Aviso from "@/components/Aviso";
import type { Franquicia } from "./FranquiciaCliente";
import { dinero, hoyLocalISO, mensajeError } from "./lib";

type Fila = {
  producto_id: string;
  sku: string;
  producto: string;
  talla: string | null;
  color: string | null;
  precio: number;
  stock_fisico: number;
  stock_disponible: number;
  transito_entrada: number;
  stock_minimo: number;
  stock_maximo: number | null;
  punto_reposicion: number;
  bajo_minimo: boolean;
  sugerido_reponer: number;
};

type LineaAjuste = {
  producto_id: string;
  sku: string;
  nombre: string;
  cantidad: number;
  stock: number;
};

type AbreviaturaSku = { nombre: string; codigo: string };
type CategoriaProducto = { id: string; nombre: string; activo: boolean };
type SubcategoriaProducto = { id: string; categoria_id: string; nombre: string; activo: boolean };

export default function InventarioFranquicia({
  franquicia,
  soloLectura = false,
  puedeCrearProducto = false,
}: {
  franquicia: Franquicia;
  /** Admin y Control revisan el stock del local; ajustarlo es del titular. */
  soloLectura?: boolean;
  /** productos.crear: por defecto solo franquiciado/vendedor_franquicia. */
  puedeCrearProducto?: boolean;
}) {
  const supabase = createClient();
  const [stock, setStock] = useState<Fila[]>([]);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [tituloAviso, setTituloAviso] = useState("Listo");

  /** El encabezado dice QUE paso; el detalle, que significa. */
  function confirmar(titulo: string, texto: string) {
    setTituloAviso(titulo);
    setAviso(texto);
  }
  const [busqueda, setBusqueda] = useState("");
  // El local ve el catalogo completo porque producto_almacen_config se siembra
  // para todas las prendas al crear el almacen. Para vender, lo unico que
  // importa es lo que hay; el catalogo entero se consulta a proposito.
  const [vista, setVista] = useState<"con_stock" | "bajo_minimo" | "todo">("con_stock");

  const [mostrarAjuste, setMostrarAjuste] = useState(false);
  const [tipo, setTipo] = useState<"entrada" | "salida">("salida");
  const [motivo, setMotivo] = useState("");
  const [fechaAjuste, setFechaAjuste] = useState(hoyLocalISO());
  const [lineas, setLineas] = useState<LineaAjuste[]>([]);
  const [buscarAjuste, setBuscarAjuste] = useState("");
  const [editandoMinimos, setEditandoMinimos] = useState(false);
  const [minimos, setMinimos] = useState<
    Record<string, { stock_minimo: string; stock_maximo: string }>
  >({});

  // Crear producto nuevo (v109): SKU sugerido con las mismas abreviaturas que
  // ya usa administracion (BS-IN-PR-03), nunca texto libre.
  const [mostrarCrearProducto, setMostrarCrearProducto] = useState(false);
  const [categoriasCatalogo, setCategoriasCatalogo] = useState<CategoriaProducto[]>([]);
  const [subcategoriasCatalogo, setSubcategoriasCatalogo] = useState<SubcategoriaProducto[]>([]);
  const [abreviaturas, setAbreviaturas] = useState<{ categoria: AbreviaturaSku[]; entidad: AbreviaturaSku[]; variante: AbreviaturaSku[] }>({ categoria: [], entidad: [], variante: [] });
  const [nuevoProducto, setNuevoProducto] = useState({
    nombre: "", categoria_id: "", subcategoria_id: "", talla: "", color: "",
    categoria_codigo: "", entidad_codigo: "", variante_codigo: "",
    anio_codigo: String(new Date().getFullYear()).slice(-2), talla_codigo: "",
  });
  const [creandoProducto, setCreandoProducto] = useState(false);

  useEffect(() => {
    if (!puedeCrearProducto) return;
    Promise.all([
      supabase.from("categorias_productos").select("id, nombre, activo").order("nombre"),
      supabase.from("subcategorias_productos").select("id, categoria_id, nombre, activo").order("nombre"),
      supabase.rpc("sku_abreviaturas_disponibles_v109"),
    ]).then(([cat, sub, abr]) => {
      if (cat.data) setCategoriasCatalogo(cat.data as CategoriaProducto[]);
      if (sub.data) setSubcategoriasCatalogo(sub.data as SubcategoriaProducto[]);
      if (abr.data) setAbreviaturas(abr.data as typeof abreviaturas);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [puedeCrearProducto]);

  const esContrato = nuevoProducto.categoria_codigo === "CTR";
  const skuPreview = nuevoProducto.categoria_codigo && nuevoProducto.entidad_codigo
    ? esContrato
      ? `${nuevoProducto.categoria_codigo}-${nuevoProducto.entidad_codigo}-UN`
      : nuevoProducto.variante_codigo && nuevoProducto.anio_codigo
        ? `${nuevoProducto.categoria_codigo}-${nuevoProducto.entidad_codigo}-${nuevoProducto.variante_codigo}-${nuevoProducto.anio_codigo}`
          + (nuevoProducto.talla_codigo ? `-${nuevoProducto.talla_codigo.toUpperCase()}` : "")
        : ""
    : "";

  async function crearProducto() {
    if (!nuevoProducto.nombre.trim()) return setError("El nombre del producto es obligatorio.");
    if (!nuevoProducto.categoria_id) return setError("Selecciona una categoría del catálogo.");
    if (!skuPreview) return setError("Completa categoría, entidad y variante para armar el código SKU.");
    setCreandoProducto(true);
    setError(null);
    const { data, error } = await supabase.rpc("crear_producto_franquicia_v109", {
      p_producto: {
        nombre: nuevoProducto.nombre.trim(),
        categoria_id: nuevoProducto.categoria_id,
        subcategoria_id: nuevoProducto.subcategoria_id || null,
        talla: nuevoProducto.talla.trim() || null,
        color: nuevoProducto.color.trim() || null,
        categoria_codigo: nuevoProducto.categoria_codigo,
        entidad_codigo: nuevoProducto.entidad_codigo,
        variante_codigo: nuevoProducto.variante_codigo,
        anio_codigo: nuevoProducto.anio_codigo,
        talla_codigo: nuevoProducto.talla_codigo,
      },
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setCreandoProducto(false);
    if (error) return setError(mensajeError(error));
    const resultado = data as { sku?: string } | null;
    confirmar("Producto creado", `Se creó con el código ${resultado?.sku ?? ""}. Administración recibió un aviso para revisarlo.`);
    setNuevoProducto({
      nombre: "", categoria_id: "", subcategoria_id: "", talla: "", color: "",
      categoria_codigo: "", entidad_codigo: "", variante_codigo: "",
      anio_codigo: String(new Date().getFullYear()).slice(-2), talla_codigo: "",
    });
    setMostrarCrearProducto(false);
  }

  async function cargar() {
    setCargando(true);
    const { data, error } = await supabase
      .from("vista_stock_operativo")
      .select(
        "producto_id, sku, producto, talla, color, precio, stock_fisico, stock_disponible, transito_entrada, stock_minimo, stock_maximo, punto_reposicion, bajo_minimo, sugerido_reponer"
      )
      .eq("almacen_id", franquicia.almacen_id)
      .order("producto");
    if (error) setError(error.message);
    else setStock((data as Fila[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [franquicia.id]);

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return stock.filter((p) => {
      // Buscar por codigo o nombre atraviesa la vista: si el vendedor escribe un
      // SKU concreto quiere verlo aunque este en cero.
      if (q) {
        return p.sku.toLowerCase().includes(q) || p.producto.toLowerCase().includes(q);
      }
      if (vista === "con_stock") return p.stock_disponible > 0 || (p.transito_entrada ?? 0) > 0;
      if (vista === "bajo_minimo") return p.bajo_minimo;
      return true;
    });
  }, [stock, busqueda, vista]);

  const conStock = stock.filter(
    (p) => p.stock_disponible > 0 || (p.transito_entrada ?? 0) > 0
  ).length;

  const candidatos = useMemo(() => {
    const q = buscarAjuste.trim().toLowerCase();
    if (!q) return [];
    return stock
      .filter(
        (p) => p.sku.toLowerCase().includes(q) || p.producto.toLowerCase().includes(q)
      )
      .slice(0, 10);
  }, [stock, buscarAjuste]);

  function agregar(p: Fila) {
    if (lineas.some((l) => l.producto_id === p.producto_id)) return setBuscarAjuste("");
    setLineas([
      ...lineas,
      {
        producto_id: p.producto_id,
        sku: p.sku,
        nombre: `${p.producto}${p.talla ? ` · ${p.talla}` : ""}`,
        cantidad: 1,
        stock: p.stock_disponible,
      },
    ]);
    setBuscarAjuste("");
  }

  // En una salida no se puede sacar más de lo que hay: la base lo rechaza.
  const excedidas = lineas.filter((l) => tipo === "salida" && l.cantidad > l.stock);

  async function registrarAjuste() {
    if (!lineas.length) return setError("Agrega al menos un producto.");
    if (motivo.trim().length < 5)
      return setError("Explica el motivo del ajuste (mínimo 5 caracteres).");
    if (excedidas.length)
      return setError(`${excedidas[0].sku}: solo hay ${excedidas[0].stock} en el local.`);

    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("registrar_ajuste_franquicia_v42", {
      p_fecha: fechaAjuste,
      p_tipo: tipo,
      p_items: lineas.map((l) => ({
        producto_id: l.producto_id,
        cantidad: l.cantidad,
      })),
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    confirmar(
      tipo === "entrada" ? "Entrada registrada" : "Salida registrada",
      tipo === "entrada"
        ? "El stock del local subió."
        : "El stock del local bajó."
    );
    setLineas([]);
    setMotivo("");
    setMostrarAjuste(false);
    cargar();
  }

  function editarMinimo(p: Fila, campo: "stock_minimo" | "stock_maximo", valor: string) {
    setMinimos({
      ...minimos,
      [p.producto_id]: {
        stock_minimo: minimos[p.producto_id]?.stock_minimo ?? String(p.stock_minimo ?? 0),
        stock_maximo:
          minimos[p.producto_id]?.stock_maximo ??
          String(p.stock_maximo ?? Math.max(p.stock_minimo ?? 0, p.stock_disponible)),
        [campo]: valor,
      },
    });
  }

  async function guardarMinimos() {
    const items = Object.entries(minimos).map(([producto_id, limites]) => ({
      producto_id,
      stock_minimo: Number(limites.stock_minimo),
      stock_maximo: Number(limites.stock_maximo),
    }));
    if (!items.length) return setError("No has modificado ningun limite.");
    const invalido = items.find(
      (i) =>
        !Number.isInteger(i.stock_minimo) ||
        !Number.isInteger(i.stock_maximo) ||
        i.stock_minimo < 0 ||
        i.stock_maximo < i.stock_minimo
    );
    if (invalido) return setError("El maximo debe ser un entero igual o mayor al minimo.");
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("guardar_minimos_franquicia_v47", {
      p_items: items,
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    confirmar("Límites guardados", `${items.length} producto(s) actualizados.`);
    setMinimos({});
    setEditandoMinimos(false);
    cargar();
  }

  async function solicitarSugerido() {
    if (sugerido <= 0) return setError("No hay productos que requieran reposicion.");
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("crear_reposicion_sugerida_franquicia_v47", {
      p_nota: "Solicitud automatica segun minimos y mercaderia en transito",
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    confirmar("Solicitud creada", "Puedes seguirla en Operaciones.");
    cargar();
  }

  const valorInventario = stock.reduce(
    (s, p) => s + Number(p.precio ?? 0) * p.stock_fisico,
    0
  );
  const sinStock = stock.filter((p) => p.stock_disponible <= 0).length;
  const enTransito = stock.reduce((s, p) => s + (p.transito_entrada ?? 0), 0);
  const bajoMinimo = stock.filter((p) => p.bajo_minimo).length;
  const sugerido = stock.reduce((s, p) => s + Number(p.sugerido_reponer ?? 0), 0);

  if (cargando) return <p className="ayuda">Cargando inventario del local…</p>;

  return (
    <>
      <Aviso
        error={error}
        aviso={aviso}
        titulo={tituloAviso}
        onCerrar={(cual) => (cual === "error" ? setError(null) : setAviso(null))}
      />

      <div className="kpis">
        <div className="kpi">
          <span className="valor">{conStock}</span>
          <span className="label">Productos disponibles</span>
        </div>
        <div className="kpi">
          <span className="valor">{dinero(valorInventario)}</span>
          <span className="label">Valor del inventario</span>
        </div>
        <div className={`kpi ${sinStock ? "alerta" : ""}`}>
          <span className="valor">{sinStock}</span>
          <span className="label">Sin stock</span>
        </div>
        <div className="kpi">
          <span className="valor">{enTransito}</span>
          <span className="label">Unidades en tránsito</span>
        </div>
        <div className={`kpi ${bajoMinimo ? "alerta" : ""}`}>
          <span className="valor">{bajoMinimo}</span>
          <span className="label">Productos bajo minimo</span>
        </div>
        <div className={`kpi ${sugerido ? "alerta" : ""}`}>
          <span className="valor">{sugerido}</span>
          <span className="label">Unidades sugeridas</span>
        </div>
      </div>

      <p className="ayuda">
        Para pedir mercadería usa <Link href="/operaciones">Operaciones</Link>: ahí se
        crea la solicitud de reposición y se confirma la recepción. Los ajustes de aquí
        son para corregir el stock por daño, pérdida o consumo interno, y quedan
        registrados con su motivo.
      </p>

      <div className="filtros">
        <button disabled={soloLectura} onClick={() => setMostrarAjuste(!mostrarAjuste)}>
          {mostrarAjuste ? "Cancelar ajuste" : "Registrar ajuste"}
        </button>
        <button className="secondary" disabled={soloLectura} onClick={() => setEditandoMinimos(!editandoMinimos)}>
          {editandoMinimos ? "Cancelar minimos" : "Configurar minimos"}
        </button>
        <button onClick={solicitarSugerido} disabled={guardando || soloLectura || sugerido <= 0}>
          Solicitar reposicion sugerida ({sugerido})
        </button>
        {puedeCrearProducto && (
          <button className="secondary" onClick={() => setMostrarCrearProducto(!mostrarCrearProducto)}>
            {mostrarCrearProducto ? "Cancelar producto nuevo" : "Crear producto nuevo"}
          </button>
        )}
        <input
          type="search"
          placeholder="Buscar por código o nombre…"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
        />
        <div className="tabs" style={{ margin: 0 }}>
          <button
            className={`tab ${vista === "con_stock" ? "activo" : ""}`}
            onClick={() => setVista("con_stock")}
          >
            Con stock ({conStock})
          </button>
          <button
            className={`tab ${vista === "bajo_minimo" ? "activo" : ""}`}
            onClick={() => setVista("bajo_minimo")}
          >
            Bajo mínimo ({bajoMinimo})
          </button>
          <button
            className={`tab ${vista === "todo" ? "activo" : ""}`}
            onClick={() => setVista("todo")}
          >
            Todo el catálogo ({stock.length})
          </button>
        </div>
        <button
          className="secondary"
          onClick={() => exportarCSV("inventario_franquicia", visibles)}
          disabled={!visibles.length}
        >
          Exportar
        </button>
      </div>

      {mostrarAjuste && (
        <div className="card-interna">
          <h4>Ajuste de inventario</h4>
          <div className="form-grid">
            <label>
              Tipo
              <select
                value={tipo}
                onChange={(e) => setTipo(e.target.value as "entrada" | "salida")}
              >
                <option value="salida">Salida (daño, pérdida, consumo)</option>
                <option value="entrada">Entrada (hallazgo, devolución)</option>
              </select>
            </label>
            <label>
              Fecha
              <input
                type="date"
                value={fechaAjuste}
                max={hoyLocalISO()}
                onChange={(e) => setFechaAjuste(e.target.value)}
              />
            </label>
            <label className="ancho-total">
              Motivo
              <input
                type="text"
                placeholder="Ej. Prenda dañada por humedad en bodega del local"
                value={motivo}
                onChange={(e) => setMotivo(e.target.value)}
              />
              <small>Mínimo 5 caracteres. Queda en el registro del movimiento.</small>
            </label>
            <label className="ancho-total">
              Agregar producto
              <input
                type="search"
                placeholder="Buscar por código o nombre…"
                value={buscarAjuste}
                onChange={(e) => setBuscarAjuste(e.target.value)}
              />
            </label>
          </div>

          {candidatos.length > 0 && (
            <div className="fq-resultados">
              {candidatos.map((p) => (
                <button
                  key={p.producto_id}
                  className="fq-resultado"
                  onClick={() => agregar(p)}
                >
                  <span className="fq-sku">{p.sku}</span>
                  <span className="fq-nom">{p.producto}</span>
                  <span className="fq-datos">{p.stock_disponible} disp.</span>
                </button>
              ))}
            </div>
          )}

          {lineas.length > 0 && (
            <div className="tabla-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Producto</th>
                    <th className="num">En local</th>
                    <th className="num">Cantidad</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {lineas.map((l) => (
                    <tr key={l.producto_id}>
                      <td>
                        <strong>{l.sku}</strong> · {l.nombre}
                      </td>
                      <td className="num">{l.stock}</td>
                      <td className="num">
                        <input
                          type="number"
                          min="1"
                          value={l.cantidad}
                          onChange={(e) =>
                            setLineas(
                              lineas.map((x) =>
                                x.producto_id === l.producto_id
                                  ? { ...x, cantidad: Number(e.target.value) }
                                  : x
                              )
                            )
                          }
                        />
                        {tipo === "salida" && l.cantidad > l.stock && (
                          <div className="fq-alerta">solo {l.stock}</div>
                        )}
                      </td>
                      <td>
                        <button
                          className="btn-mini secondary"
                          onClick={() =>
                            setLineas(
                              lineas.filter((x) => x.producto_id !== l.producto_id)
                            )
                          }
                        >
                          Quitar
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          <button
            onClick={registrarAjuste}
            disabled={guardando || !lineas.length || excedidas.length > 0}
          >
            {guardando ? "Registrando…" : `Registrar ${tipo}`}
          </button>
        </div>
      )}

      {editandoMinimos && (
        <div className="card-interna">
          <h4>Stock minimo y objetivo</h4>
          <p className="ayuda">
            Cuando disponible mas transito llega al minimo, el sistema sugiere pedir
            hasta completar el maximo. Solo se guardan los productos modificados.
          </p>
          <button onClick={guardarMinimos} disabled={guardando || !Object.keys(minimos).length}>
            {guardando ? "Guardando..." : `Guardar cambios (${Object.keys(minimos).length})`}
          </button>
        </div>
      )}

      {mostrarCrearProducto && (
        <div className="card-interna">
          <h4>Crear producto nuevo</h4>
          <p className="ayuda">
            El código se arma solo, con las mismas abreviaturas que usa administración
            (categoría-entidad-variante-año). Si no encuentras la abreviatura que
            necesitas, créalo igual con la más parecida: administración recibe un
            aviso para revisarlo y corregirlo si hace falta.
          </p>
          <div className="form-grid">
            <label className="ancho-total">
              Nombre del producto
              <input
                type="text"
                value={nuevoProducto.nombre}
                onChange={(e) => setNuevoProducto({ ...nuevoProducto, nombre: e.target.value })}
              />
            </label>
            <label>
              Categoría
              <select
                value={nuevoProducto.categoria_id}
                onChange={(e) => setNuevoProducto({ ...nuevoProducto, categoria_id: e.target.value, subcategoria_id: "" })}
              >
                <option value="">Selecciona…</option>
                {categoriasCatalogo.filter((c) => c.activo).map((c) => (
                  <option key={c.id} value={c.id}>{c.nombre}</option>
                ))}
              </select>
            </label>
            <label>
              Subcategoría (opcional)
              <select
                value={nuevoProducto.subcategoria_id}
                onChange={(e) => setNuevoProducto({ ...nuevoProducto, subcategoria_id: e.target.value })}
              >
                <option value="">Sin subcategoría</option>
                {subcategoriasCatalogo.filter((s) => s.activo && s.categoria_id === nuevoProducto.categoria_id).map((s) => (
                  <option key={s.id} value={s.id}>{s.nombre}</option>
                ))}
              </select>
            </label>
            <label>
              Talla (opcional)
              <input type="text" value={nuevoProducto.talla} onChange={(e) => setNuevoProducto({ ...nuevoProducto, talla: e.target.value })} />
            </label>
            <label>
              Color (opcional)
              <input type="text" value={nuevoProducto.color} onChange={(e) => setNuevoProducto({ ...nuevoProducto, color: e.target.value })} />
            </label>
          </div>

          <h4 style={{ marginTop: 12 }}>Código SKU</h4>
          <div className="form-grid">
            <label>
              Categoría SKU
              <select
                value={nuevoProducto.categoria_codigo}
                onChange={(e) => setNuevoProducto({ ...nuevoProducto, categoria_codigo: e.target.value })}
              >
                <option value="">Selecciona…</option>
                {abreviaturas.categoria.map((a) => (
                  <option key={a.codigo} value={a.codigo}>{a.nombre} ({a.codigo})</option>
                ))}
              </select>
            </label>
            <label>
              Entidad/marca SKU
              <select
                value={nuevoProducto.entidad_codigo}
                onChange={(e) => setNuevoProducto({ ...nuevoProducto, entidad_codigo: e.target.value })}
              >
                <option value="">Selecciona…</option>
                {abreviaturas.entidad.map((a) => (
                  <option key={a.codigo} value={a.codigo}>{a.nombre} ({a.codigo})</option>
                ))}
              </select>
            </label>
            {!esContrato && (
              <>
                <label>
                  Variante SKU
                  <select
                    value={nuevoProducto.variante_codigo}
                    onChange={(e) => setNuevoProducto({ ...nuevoProducto, variante_codigo: e.target.value })}
                  >
                    <option value="">Selecciona…</option>
                    {abreviaturas.variante.map((a) => (
                      <option key={a.codigo} value={a.codigo}>{a.nombre} ({a.codigo})</option>
                    ))}
                  </select>
                </label>
                <label>
                  Año (2 dígitos)
                  <input
                    type="text"
                    maxLength={2}
                    value={nuevoProducto.anio_codigo}
                    onChange={(e) => setNuevoProducto({ ...nuevoProducto, anio_codigo: e.target.value.replace(/\D/g, "").slice(0, 2) })}
                  />
                </label>
                <label>
                  Talla del código (opcional)
                  <input
                    type="text"
                    maxLength={8}
                    value={nuevoProducto.talla_codigo}
                    onChange={(e) => setNuevoProducto({ ...nuevoProducto, talla_codigo: e.target.value.toUpperCase() })}
                  />
                </label>
              </>
            )}
          </div>

          <p className="ayuda">
            Código resultante: <strong>{skuPreview || "— completa los campos de arriba —"}</strong>
          </p>

          <button onClick={crearProducto} disabled={creandoProducto || !skuPreview}>
            {creandoProducto ? "Creando…" : "Crear producto"}
          </button>
        </div>
      )}

      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Código</th>
              <th>Producto</th>
              <th className="num">Físico</th>
              <th className="num">Disponible</th>
              <th className="num">En tránsito</th>
              <th className="num">Minimo</th>
              <th className="num">Maximo</th>
              <th className="num">Sugerido</th>
              <th className="num">Precio</th>
            </tr>
          </thead>
          <tbody>
            {visibles.map((p) => (
              <tr key={p.producto_id}>
                <td>{p.sku}</td>
                <td>
                  {p.producto}
                  {p.talla ? ` · ${p.talla}` : ""}
                  {p.color ? ` · ${p.color}` : ""}
                </td>
                <td className="num">{p.stock_fisico}</td>
                <td className="num">
                  {p.stock_disponible <= 0 ? (
                    <span className="badge cero">0</span>
                  ) : (
                    <strong>{p.stock_disponible}</strong>
                  )}
                </td>
                <td className="num">{p.transito_entrada || "—"}</td>
                <td className="num">
                  {editandoMinimos ? (
                    <input
                      type="number"
                      min="0"
                      value={minimos[p.producto_id]?.stock_minimo ?? String(p.stock_minimo ?? 0)}
                      onChange={(e) => editarMinimo(p, "stock_minimo", e.target.value)}
                    />
                  ) : p.stock_minimo}
                </td>
                <td className="num">
                  {editandoMinimos ? (
                    <input
                      type="number"
                      min="0"
                      value={
                        minimos[p.producto_id]?.stock_maximo ??
                        String(p.stock_maximo ?? Math.max(p.stock_minimo ?? 0, p.stock_disponible))
                      }
                      onChange={(e) => editarMinimo(p, "stock_maximo", e.target.value)}
                    />
                  ) : (p.stock_maximo ?? "--")}
                </td>
                <td className="num">
                  {p.sugerido_reponer > 0 ? (
                    <span className="badge alerta">{p.sugerido_reponer}</span>
                  ) : "--"}
                </td>
                <td className="num">{dinero(p.precio)}</td>
              </tr>
            ))}
            {!visibles.length && (
              <tr>
                <td colSpan={9} className="vacio">
                  {busqueda
                    ? "Ningún producto coincide con la búsqueda."
                    : vista === "con_stock"
                      ? "El local todavía no tiene stock. Mira «Todo el catálogo» para buscar una prenda y solicitar reposición."
                      : vista === "bajo_minimo"
                        ? "Ningún producto está bajo su mínimo."
                        : "Sin productos en el catálogo."}
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
