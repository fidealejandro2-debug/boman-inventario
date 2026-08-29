"use client";

import { useEffect, useMemo, useState } from "react";
import LineasDocumentoEditor, {
  type LineaDocumentoEdicion,
  type ProductoDocumento,
} from "@/components/LineasDocumentoEditor";
import type { Perfil } from "@/lib/getPerfil";
import { createClient } from "@/lib/supabase/client";

type Grupo = { id: string; codigo: string; nombre: string };
type Empresa = { id: string; grupo_id: string; codigo: string; razon_social: string };
type Unidad = { codigo: string; nombre: string; simbolo: string; familia: string };
type TipoInventario = "producto_terminado" | "materia_prima" | "insumo" | "empaque" | "subproducto";
type Producto = ProductoDocumento & {
  categoria: string | null; tipo_inventario: TipoInventario;
  unidad_medida: string; costo_estandar: number | null;
};
type Componente = {
  id: string; producto_id: string; cantidad_base: number; merma_porcentaje: number;
  observacion: string | null; producto: Producto | null;
};
type Formula = {
  id: string; grupo_id: string; codigo: string; producto_resultado_id: string;
  version: number; rendimiento_base: number; costo_mano_obra_lote: number;
  costo_indirecto_lote: number; estado: "borrador" | "activa" | "inactiva";
  nota: string | null; created_at: string;
  producto: Producto | null; creador: { nombre_completo: string } | null;
  aprobador: { nombre_completo: string } | null; componentes: Componente[];
};
type CostoFormula = {
  formula_id: string; empresa_id: string; formula_codigo: string; version: number;
  estado: string; resultado_sku: string; resultado_producto: string;
  resultado_unidad: string; rendimiento_base: number; costo_materiales_lote: number;
  costo_mano_obra_lote: number; costo_indirecto_lote: number;
  costo_unitario_estimado: number; componentes: number; componentes_sin_costo: number;
};
type CostoProducto = {
  empresa_id: string; producto_id: string; sku: string; producto: string;
  tipo_inventario: TipoInventario; unidad_medida: string;
  costo_estandar: number | null; costo_promedio_compras: number | null;
  costo_referencia: number; fuente_costo: string;
};
type EdicionProducto = { tipo_inventario: TipoInventario; unidad_medida: string; costo_estandar: string };
type FormularioFormula = {
  id: string | null; grupo_id: string; codigo: string; producto_resultado_id: string;
  producto_resultado_texto: string; resultado_bloqueado: boolean; rendimiento_base: number;
  costo_mano_obra_lote: number; costo_indirecto_lote: number; nota: string;
  componentes: LineaDocumentoEdicion[]; mermas: Record<string, number>;
};

const TIPOS: { valor: TipoInventario; etiqueta: string }[] = [
  { valor: "producto_terminado", etiqueta: "Producto terminado" },
  { valor: "materia_prima", etiqueta: "Materia prima" },
  { valor: "insumo", etiqueta: "Insumo" },
  { valor: "empaque", etiqueta: "Empaque" },
  { valor: "subproducto", etiqueta: "Subproducto" },
];
const ETIQUETA_TIPO = Object.fromEntries(TIPOS.map((tipo) => [tipo.valor, tipo.etiqueta]));
const ETIQUETA_ESTADO: Record<string, string> = {
  borrador: "Borrador", activa: "Activa", inactiva: "Inactiva",
};
const dinero = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 4 });

function normalizar(valor: string) {
  return valor.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();
}

export default function ProduccionCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const [tab, setTab] = useState<"formulas" | "maestro" | "costos">("formulas");
  const [grupos, setGrupos] = useState<Grupo[]>([]);
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [unidades, setUnidades] = useState<Unidad[]>([]);
  const [productos, setProductos] = useState<Producto[]>([]);
  const [formulas, setFormulas] = useState<Formula[]>([]);
  const [costosFormulas, setCostosFormulas] = useState<CostoFormula[]>([]);
  const [costosProductos, setCostosProductos] = useState<CostoProducto[]>([]);
  const [empresaId, setEmpresaId] = useState("");
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);
  const [busquedaMaestro, setBusquedaMaestro] = useState("");
  const [tipoMaestro, setTipoMaestro] = useState("");
  const [ediciones, setEdiciones] = useState<Record<string, EdicionProducto>>({});
  const [motivoMaestro, setMotivoMaestro] = useState("");
  const [formulario, setFormulario] = useState<FormularioFormula | null>(null);
  const [busquedaResultado, setBusquedaResultado] = useState("");
  const [busquedaCosto, setBusquedaCosto] = useState("");

  const puedeEditar = ["admin", "control"].includes(perfil.rol);

  async function cargar() {
    setCargando(true);
    const [g, e, u, p, f, cf, cp] = await Promise.all([
      supabase.from("grupos_economicos").select("id,codigo,nombre").eq("activo", true).order("nombre"),
      supabase.from("empresas").select("id,grupo_id,codigo,razon_social").eq("activo", true).order("razon_social"),
      supabase.from("unidades_medida_produccion").select("codigo,nombre,simbolo,familia").eq("activo", true).order("familia").order("nombre"),
      supabase.from("productos").select("id,sku,nombre,talla,color,categoria,tipo_inventario,unidad_medida,costo_estandar").eq("activo", true).order("sku"),
      supabase.from("formulas_produccion").select(`
        id,grupo_id,codigo,producto_resultado_id,version,rendimiento_base,
        costo_mano_obra_lote,costo_indirecto_lote,estado,nota,created_at,
        producto:productos!formulas_produccion_producto_resultado_id_fkey(id,sku,nombre,talla,color,categoria,tipo_inventario,unidad_medida,costo_estandar),
        creador:perfiles!formulas_produccion_creado_por_fkey(nombre_completo),
        aprobador:perfiles!formulas_produccion_aprobado_por_fkey(nombre_completo),
        componentes:formula_produccion_componentes(id,producto_id,cantidad_base,merma_porcentaje,observacion,
          producto:productos!formula_produccion_componentes_producto_id_fkey(id,sku,nombre,talla,color,categoria,tipo_inventario,unidad_medida,costo_estandar))
      `).order("created_at", { ascending: false }),
      supabase.from("vista_formula_costos_empresa_v23").select("*"),
      supabase.from("vista_costos_producto_empresa_v23").select("empresa_id,producto_id,sku,producto,tipo_inventario,unidad_medida,costo_estandar,costo_promedio_compras,costo_referencia,fuente_costo"),
    ]);
    const error = g.error ?? e.error ?? u.error ?? p.error ?? f.error ?? cf.error ?? cp.error;
    if (error) setMsg({ tipo: "error", texto: `No se pudo cargar Producción. Verifica la migración v23: ${error.message}` });
    const empresasData = (e.data ?? []) as Empresa[];
    setGrupos((g.data ?? []) as Grupo[]); setEmpresas(empresasData);
    setUnidades((u.data ?? []) as Unidad[]); setProductos((p.data ?? []) as Producto[]);
    setFormulas((f.data ?? []) as any as Formula[]);
    setCostosFormulas((cf.data ?? []) as CostoFormula[]);
    setCostosProductos((cp.data ?? []) as CostoProducto[]);
    if (!empresaId && empresasData.length) setEmpresaId(empresasData[0].id);
    setEdiciones({}); setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const productosMaestro = useMemo(() => {
    const q = normalizar(busquedaMaestro);
    return productos.filter((producto) => {
      const coincide = !q || normalizar([
        producto.sku, producto.nombre, producto.talla ?? "", producto.color ?? "", producto.categoria ?? "",
      ].join(" ")).includes(q);
      return coincide && (!tipoMaestro || producto.tipo_inventario === tipoMaestro);
    }).slice(0, 300);
  }, [busquedaMaestro, productos, tipoMaestro]);

  const resultadosSugeridos = useMemo(() => {
    const q = normalizar(busquedaResultado);
    if (!q || formulario?.producto_resultado_id) return [];
    return productos.filter((producto) =>
      ["producto_terminado", "subproducto"].includes(producto.tipo_inventario)
      && normalizar(`${producto.sku} ${producto.nombre} ${producto.talla ?? ""}`).includes(q)
    ).slice(0, 12);
  }, [busquedaResultado, formulario?.producto_resultado_id, productos]);

  const costosFormulaEmpresa = costosFormulas.filter((costo) => costo.empresa_id === empresaId);
  const costosProductoEmpresa = useMemo(() => {
    const q = normalizar(busquedaCosto);
    return costosProductos.filter((costo) => costo.empresa_id === empresaId
      && (!q || normalizar(`${costo.sku} ${costo.producto} ${ETIQUETA_TIPO[costo.tipo_inventario]}`).includes(q)))
      .sort((a, b) => Number(a.costo_referencia === 0) - Number(b.costo_referencia === 0) || a.sku.localeCompare(b.sku))
      .slice(0, 400);
  }, [busquedaCosto, costosProductos, empresaId]);

  function valorEdicion(producto: Producto): EdicionProducto {
    return ediciones[producto.id] ?? {
      tipo_inventario: producto.tipo_inventario,
      unidad_medida: producto.unidad_medida,
      costo_estandar: producto.costo_estandar == null ? "" : String(producto.costo_estandar),
    };
  }

  function editarProducto(producto: Producto, cambio: Partial<EdicionProducto>) {
    setEdiciones({ ...ediciones, [producto.id]: { ...valorEdicion(producto), ...cambio } });
  }

  async function guardarMaestro() {
    const items = Object.entries(ediciones).map(([producto_id, valor]) => ({
      producto_id, tipo_inventario: valor.tipo_inventario,
      unidad_medida: valor.unidad_medida,
      costo_estandar: valor.costo_estandar === "" ? null : Number(valor.costo_estandar),
    }));
    if (!items.length) { setMsg({ tipo: "error", texto: "No hay cambios en el maestro productivo." }); return; }
    if (items.some((item) => item.costo_estandar != null && (!Number.isFinite(item.costo_estandar) || item.costo_estandar < 0))) {
      setMsg({ tipo: "error", texto: "Revisa los costos estándar." }); return;
    }
    setProcesando(true); setMsg(null);
    const { data, error } = await supabase.rpc("clasificar_productos_produccion_v23", {
      p_items: items, p_motivo: motivoMaestro,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: `${data ?? 0} producto(s) actualizados con auditoría.` });
    setMotivoMaestro(""); await cargar();
  }

  function nuevaFormula() {
    setFormulario({
      id: null, grupo_id: grupos[0]?.id ?? "", codigo: "", producto_resultado_id: "",
      producto_resultado_texto: "", resultado_bloqueado: false,
      rendimiento_base: 1, costo_mano_obra_lote: 0,
      costo_indirecto_lote: 0, nota: "", componentes: [], mermas: {},
    });
    setBusquedaResultado(""); setMsg(null);
  }

  function editarFormula(formula: Formula, nuevaVersion = false) {
    setFormulario({
      id: nuevaVersion ? null : formula.id,
      grupo_id: formula.grupo_id, codigo: formula.codigo,
      producto_resultado_id: formula.producto_resultado_id,
      producto_resultado_texto: `${formula.producto?.sku ?? ""} · ${formula.producto?.nombre ?? ""}`,
      resultado_bloqueado: true,
      rendimiento_base: formula.rendimiento_base,
      costo_mano_obra_lote: formula.costo_mano_obra_lote,
      costo_indirecto_lote: formula.costo_indirecto_lote,
      nota: nuevaVersion ? `Nueva versión basada en v${formula.version}` : formula.nota ?? "",
      componentes: formula.componentes.map((componente) => ({
        producto_id: componente.producto_id, cantidad: componente.cantidad_base,
        observacion: componente.observacion ?? "",
      })),
      mermas: Object.fromEntries(formula.componentes.map((componente) => [componente.producto_id, componente.merma_porcentaje])),
    });
    setBusquedaResultado(""); setMsg(null); window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function cambiarComponentes(componentes: LineaDocumentoEdicion[]) {
    if (!formulario) return;
    const ids = new Set(componentes.map((componente) => componente.producto_id));
    setFormulario({
      ...formulario, componentes,
      mermas: Object.fromEntries(Object.entries(formulario.mermas).filter(([id]) => ids.has(id))),
    });
  }

  async function guardarFormula(evento: React.FormEvent) {
    evento.preventDefault();
    if (!formulario || !formulario.grupo_id || !formulario.producto_resultado_id || !formulario.componentes.length) {
      setMsg({ tipo: "error", texto: "Selecciona resultado y al menos un componente." }); return;
    }
    if (formulario.componentes.some((componente) => componente.cantidad <= 0
      || (formulario.mermas[componente.producto_id] ?? 0) < 0
      || (formulario.mermas[componente.producto_id] ?? 0) > 100)) {
      setMsg({ tipo: "error", texto: "Revisa cantidades y porcentajes de merma." }); return;
    }
    setProcesando(true); setMsg(null);
    const { error } = await supabase.rpc("guardar_formula_produccion_v23", {
      p_formula_id: formulario.id, p_grupo_id: formulario.grupo_id,
      p_codigo: formulario.codigo, p_producto_resultado_id: formulario.producto_resultado_id,
      p_rendimiento_base: formulario.rendimiento_base,
      p_costo_mano_obra_lote: formulario.costo_mano_obra_lote,
      p_costo_indirecto_lote: formulario.costo_indirecto_lote,
      p_nota: formulario.nota || null,
      p_componentes: formulario.componentes.map((componente) => ({
        producto_id: componente.producto_id, cantidad_base: componente.cantidad,
        merma_porcentaje: formulario.mermas[componente.producto_id] ?? 0,
        observacion: componente.observacion || null,
      })),
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setFormulario(null); setMsg({ tipo: "ok", texto: "Fórmula guardada como borrador para revisión." });
    await cargar();
  }

  async function resolverFormula(formula: Formula, activar: boolean) {
    const nota = window.prompt(activar ? "Evidencia de revisión para activar la fórmula:" : "Motivo para inactivar la fórmula:")?.trim();
    if (!nota) return;
    setProcesando(true); setMsg(null);
    const { error } = await supabase.rpc("resolver_formula_produccion_v23", {
      p_formula_id: formula.id, p_activar: activar, p_nota: nota,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: activar ? "Fórmula activada y lista para planificación." : "Fórmula inactivada." });
    await cargar();
  }

  if (cargando) return <div className="card"><div className="vacio">Cargando maestro de producción...</div></div>;

  return <>
    <div className="header-row"><div><h2 style={{ color: "#1f3864", margin: 0 }}>Producción y costos</h2><p className="conteo">Maestro productivo, fórmulas versionadas y costo teórico por RUC.</p></div>{puedeEditar && tab === "formulas" && <button onClick={nuevaFormula}>+ Nueva fórmula</button>}</div>
    {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}
    <div className="info-box"><strong>V23 prepara y valida el proceso.</strong> Todavía no consume materiales ni ingresa producto terminado; la ejecución controlada se habilitará en V24 sobre fórmulas activas.</div>
    <div className="tabs"><button className={`tab ${tab === "formulas" ? "activo" : ""}`} onClick={() => setTab("formulas")}>Fórmulas / BOM</button><button className={`tab ${tab === "maestro" ? "activo" : ""}`} onClick={() => setTab("maestro")}>Maestro productivo</button><button className={`tab ${tab === "costos" ? "activo" : ""}`} onClick={() => setTab("costos")}>Costos estimados</button></div>

    {tab === "formulas" && <>
      {formulario && <form className="card" onSubmit={guardarFormula} style={{ marginBottom: 14 }}><div className="header-row"><div><h3 style={{ margin: 0 }}>{formulario.id ? "Editar borrador" : "Nueva versión de fórmula"}</h3><p className="conteo">Las versiones activas son inmutables; para cambiar una, crea una nueva versión.</p></div><button type="button" className="chip-limpiar" onClick={() => setFormulario(null)}>Cerrar</button></div><div className="grid-form"><div className="field"><label>Grupo económico *</label><select required value={formulario.grupo_id} disabled={Boolean(formulario.id) || formulario.resultado_bloqueado} onChange={(e) => setFormulario({ ...formulario, grupo_id: e.target.value })}><option value="">Seleccionar...</option>{grupos.map((grupo) => <option key={grupo.id} value={grupo.id}>{grupo.codigo} · {grupo.nombre}</option>)}</select></div><div className="field"><label>Código de fórmula *</label><input required value={formulario.codigo} onChange={(e) => setFormulario({ ...formulario, codigo: e.target.value.toUpperCase() })} placeholder="Ej.: BOM-CAMISETA" /></div><div className="field buscador-producto-documento"><label>Producto resultado *</label><div className="buscador-producto-caja"><input value={formulario.producto_resultado_texto || busquedaResultado} disabled={Boolean(formulario.id) || Boolean(formulario.producto_resultado_id)} onChange={(e) => setBusquedaResultado(e.target.value)} placeholder="Buscar producto terminado..." />{formulario.producto_resultado_id && !formulario.resultado_bloqueado && <button type="button" className="chip-limpiar" onClick={() => setFormulario({ ...formulario, producto_resultado_id: "", producto_resultado_texto: "" })}>Cambiar resultado</button>}{resultadosSugeridos.length > 0 && <div className="sugerencias-documento">{resultadosSugeridos.map((producto) => <button type="button" key={producto.id} onClick={() => { setFormulario({ ...formulario, producto_resultado_id: producto.id, producto_resultado_texto: `${producto.sku} · ${producto.nombre}` }); setBusquedaResultado(""); }}><strong>{producto.sku}</strong><span>{producto.nombre} {producto.talla ?? ""}</span></button>)}</div>}</div></div><div className="field"><label>Rendimiento del lote *</label><input type="number" min={0.000001} step="any" required value={formulario.rendimiento_base} onChange={(e) => setFormulario({ ...formulario, rendimiento_base: Number(e.target.value) || 0 })} /></div><div className="field"><label>Mano de obra por lote</label><input type="number" min={0} step="0.0001" value={formulario.costo_mano_obra_lote} onChange={(e) => setFormulario({ ...formulario, costo_mano_obra_lote: Number(e.target.value) || 0 })} /></div><div className="field"><label>Costos indirectos por lote</label><input type="number" min={0} step="0.0001" value={formulario.costo_indirecto_lote} onChange={(e) => setFormulario({ ...formulario, costo_indirecto_lote: Number(e.target.value) || 0 })} /></div></div><h4>Componentes requeridos</h4><LineasDocumentoEditor productos={productos.filter((producto) => producto.id !== formulario.producto_resultado_id)} lineas={formulario.componentes} onChange={cambiarComponentes} permitirDecimales />{formulario.componentes.length > 0 && <div className="tabla-scroll"><table><thead><tr><th>Componente</th><th>Unidad</th><th className="num">Cantidad base</th><th className="num">Merma técnica %</th></tr></thead><tbody>{formulario.componentes.map((componente) => { const producto = productos.find((item) => item.id === componente.producto_id); return <tr key={componente.producto_id}><td><strong>{producto?.sku}</strong> · {producto?.nombre}</td><td>{producto?.unidad_medida}</td><td className="num">{componente.cantidad}</td><td className="num"><input type="number" min={0} max={100} step="0.0001" value={formulario.mermas[componente.producto_id] ?? 0} onChange={(e) => setFormulario({ ...formulario, mermas: { ...formulario.mermas, [componente.producto_id]: Number(e.target.value) || 0 } })} style={{ width: 90 }} /></td></tr>; })}</tbody></table></div>}<div className="field"><label>Nota técnica</label><textarea rows={3} value={formulario.nota} onChange={(e) => setFormulario({ ...formulario, nota: e.target.value })} /></div><div className="acciones-documento"><button disabled={procesando}>{procesando ? "Guardando..." : "Guardar borrador"}</button><button type="button" className="secondary" onClick={() => setFormulario(null)}>Cancelar</button></div></form>}
      <div className="documentos-grid">{formulas.map((formula) => <article className="card documento-card" key={formula.id}><div className="header-row"><div><strong>{formula.codigo} · v{formula.version}</strong><div>{formula.producto?.sku} · {formula.producto?.nombre}</div></div><span className={`badge ${formula.estado === "activa" ? "ok" : formula.estado === "borrador" ? "estado-pendiente_revision" : "cero"}`}>{ETIQUETA_ESTADO[formula.estado]}</span></div><div className="documento-meta"><span>Rendimiento: <b>{formula.rendimiento_base} {formula.producto?.unidad_medida}</b></span><span>Componentes: <b>{formula.componentes.length}</b></span><span>Preparó: <b>{formula.creador?.nombre_completo}</b></span></div><details><summary>Ver componentes</summary>{formula.componentes.map((componente) => <div className="pendiente-control" key={componente.id}><span><strong>{componente.producto?.sku}</strong><small>{componente.producto?.nombre}</small></span><b>{componente.cantidad_base} {componente.producto?.unidad_medida}{componente.merma_porcentaje ? ` + ${componente.merma_porcentaje}%` : ""}</b></div>)}</details>{formula.nota && <p className="conteo">{formula.nota}</p>}<div className="acciones-documento">{puedeEditar && formula.estado === "borrador" && <><button className="secondary" onClick={() => editarFormula(formula)}>Editar</button><button onClick={() => resolverFormula(formula, true)}>Revisar y activar</button></>}{puedeEditar && formula.estado === "activa" && <><button className="secondary" onClick={() => editarFormula(formula, true)}>Nueva versión</button><button className="peligro" onClick={() => resolverFormula(formula, false)}>Inactivar</button></>}</div></article>)}{!formulas.length && <div className="card"><div className="vacio">Aún no existen fórmulas de producción.</div></div>}</div>
    </>}

    {tab === "maestro" && <div className="card"><div className="header-row"><div><h3 style={{ margin: 0 }}>Clasificación del catálogo</h3><p className="conteo">Define qué se fabrica, qué se consume y en qué unidad se controla.</p></div><span className="badge estado-pendiente_revision">{Object.keys(ediciones).length} cambios</span></div><div className="grid-2"><div className="field"><label>Buscar producto</label><input value={busquedaMaestro} onChange={(e) => setBusquedaMaestro(e.target.value)} placeholder="SKU, nombre, talla, color o categoría" /></div><div className="field"><label>Filtrar tipo</label><select value={tipoMaestro} onChange={(e) => setTipoMaestro(e.target.value)}><option value="">Todos</option>{TIPOS.map((tipo) => <option key={tipo.valor} value={tipo.valor}>{tipo.etiqueta}</option>)}</select></div></div><div className="tabla-scroll"><table><thead><tr><th>SKU / producto</th><th>Categoría</th><th>Tipo productivo</th><th>Unidad de control</th><th className="num">Costo estándar</th></tr></thead><tbody>{productosMaestro.map((producto) => { const valor = valorEdicion(producto); return <tr key={producto.id} className={ediciones[producto.id] ? "fila-alerta" : ""}><td><strong>{producto.sku}</strong><div>{producto.nombre} {producto.talla ?? ""}</div></td><td>{producto.categoria ?? "-"}</td><td><select disabled={!puedeEditar} value={valor.tipo_inventario} onChange={(e) => editarProducto(producto, { tipo_inventario: e.target.value as TipoInventario })}>{TIPOS.map((tipo) => <option key={tipo.valor} value={tipo.valor}>{tipo.etiqueta}</option>)}</select></td><td><select disabled={!puedeEditar} value={valor.unidad_medida} onChange={(e) => editarProducto(producto, { unidad_medida: e.target.value })}>{unidades.map((unidad) => <option key={unidad.codigo} value={unidad.codigo}>{unidad.nombre} ({unidad.simbolo})</option>)}</select></td><td className="num"><input disabled={!puedeEditar} type="number" min={0} step="0.000001" value={valor.costo_estandar} onChange={(e) => editarProducto(producto, { costo_estandar: e.target.value })} placeholder="Opcional" style={{ width: 110 }} /></td></tr>; })}</tbody></table></div>{puedeEditar && <div className="grid-2" style={{ marginTop: 12 }}><div className="field"><label>Motivo de los cambios *</label><input value={motivoMaestro} onChange={(e) => setMotivoMaestro(e.target.value)} placeholder="Ej.: clasificación inicial de materia prima" /></div><div className="acciones-documento"><button disabled={procesando || !Object.keys(ediciones).length} onClick={guardarMaestro}>Guardar cambios auditados</button><button className="secondary" onClick={() => setEdiciones({})}>Descartar</button></div></div>}</div>}

    {tab === "costos" && <><div className="card"><div className="header-row"><div><h3 style={{ margin: 0 }}>Costo teórico de fórmulas</h3><p className="conteo">Promedio de compras del RUC; cuando no existe, utiliza el costo estándar.</p></div><select value={empresaId} onChange={(e) => setEmpresaId(e.target.value)}><option value="">Seleccionar RUC...</option>{empresas.map((empresa) => <option key={empresa.id} value={empresa.id}>{empresa.codigo} · {empresa.razon_social}</option>)}</select></div><div className="tabla-scroll"><table><thead><tr><th>Fórmula</th><th>Resultado</th><th className="num">Materiales/lote</th><th className="num">Mano de obra</th><th className="num">Indirectos</th><th className="num">Costo unitario</th><th>Calidad del costo</th></tr></thead><tbody>{costosFormulaEmpresa.map((costo) => <tr key={costo.formula_id} className={costo.componentes_sin_costo ? "fila-alerta" : ""}><td><strong>{costo.formula_codigo}</strong> · v{costo.version}<div><span className={`badge ${costo.estado === "activa" ? "ok" : "cero"}`}>{ETIQUETA_ESTADO[costo.estado]}</span></div></td><td><strong>{costo.resultado_sku}</strong><div>{costo.resultado_producto}</div></td><td className="num">{dinero.format(costo.costo_materiales_lote)}</td><td className="num">{dinero.format(costo.costo_mano_obra_lote)}</td><td className="num">{dinero.format(costo.costo_indirecto_lote)}</td><td className="num"><strong>{dinero.format(costo.costo_unitario_estimado)}</strong></td><td>{costo.componentes_sin_costo ? <span className="badge bajo">{costo.componentes_sin_costo} componente(s) sin costo</span> : <span className="badge ok">Completo</span>}</td></tr>)}{!costosFormulaEmpresa.length && <tr><td colSpan={7} className="vacio">No existen fórmulas visibles para este RUC.</td></tr>}</tbody></table></div></div><div className="card"><div className="header-row"><div><h3 style={{ margin: 0 }}>Costo de referencia por producto</h3><p className="conteo">Sirve como insumo del costo teórico; no constituye todavía valoración contable del inventario compartido.</p></div><input value={busquedaCosto} onChange={(e) => setBusquedaCosto(e.target.value)} placeholder="Buscar producto..." /></div><div className="tabla-scroll"><table><thead><tr><th>SKU / producto</th><th>Tipo</th><th>Unidad</th><th className="num">Promedio compras</th><th className="num">Estándar</th><th className="num">Referencia</th><th>Fuente</th></tr></thead><tbody>{costosProductoEmpresa.map((costo) => <tr key={costo.producto_id} className={!costo.costo_referencia ? "fila-alerta" : ""}><td><strong>{costo.sku}</strong><div>{costo.producto}</div></td><td>{ETIQUETA_TIPO[costo.tipo_inventario]}</td><td>{costo.unidad_medida}</td><td className="num">{costo.costo_promedio_compras == null ? "-" : dinero.format(costo.costo_promedio_compras)}</td><td className="num">{costo.costo_estandar == null ? "-" : dinero.format(costo.costo_estandar)}</td><td className="num"><strong>{dinero.format(costo.costo_referencia)}</strong></td><td><span className={`badge ${costo.fuente_costo === "sin_costo" ? "bajo" : "ok"}`}>{costo.fuente_costo.replace("_", " ")}</span></td></tr>)}</tbody></table></div></div></>}
  </>;
}
