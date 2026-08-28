"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type Grupo = {
  id: string;
  codigo: string;
  nombre: string;
  moneda: string;
};

type Empresa = {
  id: string;
  grupo_id: string;
  codigo: string;
  ruc: string;
  razon_social: string;
  nombre_comercial: string | null;
  tipo: TipoEmpresa;
  obligado_contabilidad: boolean;
  activo: boolean;
};

type Resumen = Empresa & {
  empresa_id: string;
  almacenes_asignados: number;
  almacenes_principales: number;
  usuarios_asignados: number;
  facturas_xml: number;
  stock_fisico_operado: number;
};

type Almacen = {
  id: string;
  nombre: string;
  codigo: string;
  tipo: string;
  activo: boolean;
};

type VinculoAlmacen = {
  empresa_id: string;
  almacen_id: string;
  es_operadora_principal: boolean;
  permite_ventas: boolean;
  permite_compras: boolean;
  custodia_inventario: boolean;
};

type EstablecimientoEmpresa = {
  id: string;
  empresa_id: string;
  codigo: string;
  nombre: string;
  almacen_id: string | null;
  direccion: string | null;
  es_matriz: boolean;
  activo: boolean;
  puntos_emision: string[];
  equivalencias_xml: {
    id: string;
    establecimiento_xml: string;
    punto_emision_xml: string;
    punto_emision_oficial: string;
    motivo: string;
  }[];
};

type EstablecimientoFormulario = Omit<
  EstablecimientoEmpresa,
  "id" | "empresa_id" | "direccion" | "puntos_emision" | "equivalencias_xml"
> & {
  clave: string;
  direccion: string;
  puntos_emision_texto: string;
  equivalencias_xml_texto: string;
  motivo_equivalencia: string;
};

type Pendiente = {
  tipo: string;
  cantidad: number;
  detalle: string;
};

type TipoEmpresa = "cia_ltda" | "sas" | "persona_natural" | "establecimiento_individual" | "otro";

type Formulario = {
  id: string | null;
  codigo: string;
  ruc: string;
  razon_social: string;
  nombre_comercial: string;
  tipo: TipoEmpresa;
  obligado_contabilidad: boolean;
  activo: boolean;
  almacenes: Record<string, Omit<VinculoAlmacen, "empresa_id" | "almacen_id">>;
  establecimientos: EstablecimientoFormulario[];
};

const TIPOS: { valor: TipoEmpresa; etiqueta: string }[] = [
  { valor: "cia_ltda", etiqueta: "Compañía limitada" },
  { valor: "sas", etiqueta: "SAS" },
  { valor: "persona_natural", etiqueta: "Persona natural" },
  { valor: "establecimiento_individual", etiqueta: "RUC independiente de tienda" },
  { valor: "otro", etiqueta: "Otra figura legal" },
];

const FORMULARIO_VACIO: Formulario = {
  id: null,
  codigo: "",
  ruc: "",
  razon_social: "",
  nombre_comercial: "",
  tipo: "cia_ltda",
  obligado_contabilidad: false,
  activo: true,
  almacenes: {},
  establecimientos: [],
};

const CONFIG_ALMACEN = {
  es_operadora_principal: false,
  permite_ventas: true,
  permite_compras: true,
  custodia_inventario: true,
};

function numero(valor: unknown) {
  const convertido = Number(valor);
  return Number.isFinite(convertido) ? convertido : 0;
}

function separarPuntosEmision(valor: string) {
  return valor.split(",").map((punto) => punto.trim()).filter(Boolean);
}

function separarEquivalenciasXml(valor: string) {
  return valor.split(",").map((item) => item.trim()).filter(Boolean).flatMap((item) => {
    const partes = item.match(/^(\d{3})-(\d{3})>(\d{3})$/);
    return partes ? [{
      establecimiento_xml: partes[1],
      punto_emision_xml: partes[2],
      punto_emision_oficial: partes[3],
    }] : [];
  });
}

export default function EmpresasCliente() {
  const supabase = createClient();
  const [grupo, setGrupo] = useState<Grupo | null>(null);
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [resumenes, setResumenes] = useState<Resumen[]>([]);
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [vinculos, setVinculos] = useState<VinculoAlmacen[]>([]);
  const [establecimientos, setEstablecimientos] = useState<EstablecimientoEmpresa[]>([]);
  const [pendientes, setPendientes] = useState<Pendiente[]>([]);
  const [formulario, setFormulario] = useState<Formulario | null>(null);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);

  async function cargar() {
    setCargando(true);
    setMsg(null);
    const [grupoRes, empresasRes, resumenRes, almacenesRes, vinculosRes, establecimientosRes, pendientesRes] = await Promise.all([
      supabase.from("grupos_economicos").select("id,codigo,nombre,moneda").eq("activo", true).limit(1).maybeSingle(),
      supabase.from("empresas").select("id,grupo_id,codigo,ruc,razon_social,nombre_comercial,tipo,obligado_contabilidad,activo").order("razon_social"),
      supabase.from("vista_resumen_multiempresa").select("*").order("razon_social"),
      supabase.from("almacenes").select("id,nombre,codigo,tipo,activo").eq("activo", true).order("nombre"),
      supabase.from("empresa_almacenes").select("empresa_id,almacen_id,es_operadora_principal,permite_ventas,permite_compras,custodia_inventario"),
      supabase.from("vista_establecimientos_empresa").select("id,empresa_id,codigo,nombre,almacen_id,direccion,es_matriz,activo,puntos_emision,equivalencias_xml").order("codigo"),
      supabase.from("vista_pendientes_multiempresa").select("tipo,cantidad,detalle").order("tipo"),
    ]);

    const error = grupoRes.error ?? empresasRes.error ?? resumenRes.error ?? almacenesRes.error ?? vinculosRes.error ?? establecimientosRes.error ?? pendientesRes.error;
    if (error) {
      setMsg({
        tipo: "error",
        texto: `No se pudo cargar el módulo multiempresa. Ejecuta las migraciones v18 y v19: ${error.message}`,
      });
    } else {
      setGrupo((grupoRes.data as Grupo | null) ?? null);
      setEmpresas((empresasRes.data ?? []) as Empresa[]);
      setResumenes(((resumenRes.data ?? []) as Resumen[]).map((fila) => ({
        ...fila,
        almacenes_asignados: numero(fila.almacenes_asignados),
        almacenes_principales: numero(fila.almacenes_principales),
        usuarios_asignados: numero(fila.usuarios_asignados),
        facturas_xml: numero(fila.facturas_xml),
        stock_fisico_operado: numero(fila.stock_fisico_operado),
      })));
      setAlmacenes((almacenesRes.data ?? []) as Almacen[]);
      setVinculos((vinculosRes.data ?? []) as VinculoAlmacen[]);
      setEstablecimientos((establecimientosRes.data ?? []) as EstablecimientoEmpresa[]);
      setPendientes(((pendientesRes.data ?? []) as Pendiente[]).map((fila) => ({ ...fila, cantidad: numero(fila.cantidad) })));
    }
    setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const totalPendiente = useMemo(
    () => pendientes.reduce((total, pendiente) => total + pendiente.cantidad, 0),
    [pendientes]
  );

  function nuevaEmpresa() {
    setFormulario({ ...FORMULARIO_VACIO, almacenes: {}, establecimientos: [] });
    setMsg(null);
  }

  function editarEmpresa(empresa: Empresa) {
    const asignados: Formulario["almacenes"] = {};
    vinculos.filter((vinculo) => vinculo.empresa_id === empresa.id).forEach((vinculo) => {
      asignados[vinculo.almacen_id] = {
        es_operadora_principal: vinculo.es_operadora_principal,
        permite_ventas: vinculo.permite_ventas,
        permite_compras: vinculo.permite_compras,
        custodia_inventario: vinculo.custodia_inventario,
      };
    });
    const establecimientosEmpresa = establecimientos
      .filter((establecimiento) => establecimiento.empresa_id === empresa.id)
      .map((establecimiento) => ({
        clave: establecimiento.id,
        codigo: establecimiento.codigo,
        nombre: establecimiento.nombre,
        almacen_id: establecimiento.almacen_id,
        direccion: establecimiento.direccion ?? "",
        es_matriz: establecimiento.es_matriz,
        activo: establecimiento.activo,
        puntos_emision_texto: (establecimiento.puntos_emision ?? []).join(", "),
        equivalencias_xml_texto: (establecimiento.equivalencias_xml ?? []).map((equivalencia) =>
          `${equivalencia.establecimiento_xml}-${equivalencia.punto_emision_xml}>${equivalencia.punto_emision_oficial}`
        ).join(", "),
        motivo_equivalencia: establecimiento.equivalencias_xml?.[0]?.motivo ?? "",
      }));
    setFormulario({
      id: empresa.id,
      codigo: empresa.codigo,
      ruc: empresa.ruc,
      razon_social: empresa.razon_social,
      nombre_comercial: empresa.nombre_comercial ?? "",
      tipo: empresa.tipo,
      obligado_contabilidad: empresa.obligado_contabilidad,
      activo: empresa.activo,
      almacenes: asignados,
      establecimientos: establecimientosEmpresa,
    });
    setMsg(null);
  }

  function alternarAlmacen(almacenId: string, activo: boolean) {
    if (!formulario) return;
    const siguiente = { ...formulario.almacenes };
    if (activo) siguiente[almacenId] = { ...CONFIG_ALMACEN };
    else delete siguiente[almacenId];
    setFormulario({
      ...formulario,
      almacenes: siguiente,
      establecimientos: activo
        ? formulario.establecimientos
        : formulario.establecimientos.map((establecimiento) =>
          establecimiento.almacen_id === almacenId
            ? { ...establecimiento, almacen_id: null }
            : establecimiento
        ),
    });
  }

  function cambiarAlmacen(almacenId: string, cambio: Partial<typeof CONFIG_ALMACEN>) {
    if (!formulario || !formulario.almacenes[almacenId]) return;
    setFormulario({
      ...formulario,
      almacenes: {
        ...formulario.almacenes,
        [almacenId]: { ...formulario.almacenes[almacenId], ...cambio },
      },
    });
  }

  function agregarEstablecimiento() {
    if (!formulario) return;
    setFormulario({
      ...formulario,
      establecimientos: [
        ...formulario.establecimientos,
        {
          clave: crypto.randomUUID(), codigo: "", nombre: "", almacen_id: null,
          direccion: "", es_matriz: formulario.establecimientos.length === 0,
          activo: true, puntos_emision_texto: "001",
          equivalencias_xml_texto: "", motivo_equivalencia: "",
        },
      ],
    });
  }

  function cambiarEstablecimiento(indice: number, cambio: Partial<EstablecimientoFormulario>) {
    if (!formulario) return;
    const siguientes = formulario.establecimientos.map((establecimiento, posicion) => {
      if (posicion === indice) return { ...establecimiento, ...cambio };
      if (cambio.es_matriz) return { ...establecimiento, es_matriz: false };
      return establecimiento;
    });
    setFormulario({ ...formulario, establecimientos: siguientes });
  }

  function quitarEstablecimiento(indice: number) {
    if (!formulario) return;
    setFormulario({
      ...formulario,
      establecimientos: formulario.establecimientos.filter((_, posicion) => posicion !== indice),
    });
  }

  async function guardar(evento: React.FormEvent) {
    evento.preventDefault();
    if (!formulario || !grupo) return;
    if (!/^\d{13}$/.test(formulario.ruc)) {
      setMsg({ tipo: "error", texto: "El RUC debe contener exactamente 13 dígitos." });
      return;
    }
    if (formulario.establecimientos.some((establecimiento) =>
      !/^\d{3}$/.test(establecimiento.codigo) || !establecimiento.nombre.trim()
      || separarPuntosEmision(establecimiento.puntos_emision_texto).some((punto) => !/^\d{3}$/.test(punto))
    )) {
      setMsg({ tipo: "error", texto: "Revisa los códigos de establecimiento y puntos de emisión: deben tener tres dígitos." });
      return;
    }
    if (formulario.establecimientos.filter((establecimiento) => establecimiento.activo && establecimiento.es_matriz).length > 1) {
      setMsg({ tipo: "error", texto: "Solo puede existir un establecimiento matriz activo por RUC." });
      return;
    }
    if (formulario.establecimientos.some((establecimiento) => {
      const entradas = establecimiento.equivalencias_xml_texto.split(",").map((item) => item.trim()).filter(Boolean);
      const equivalencias = separarEquivalenciasXml(establecimiento.equivalencias_xml_texto);
      const puntos = separarPuntosEmision(establecimiento.puntos_emision_texto);
      return entradas.length !== equivalencias.length
        || equivalencias.some((equivalencia) => !puntos.includes(equivalencia.punto_emision_oficial))
        || (equivalencias.length > 0 && !establecimiento.motivo_equivalencia.trim());
    })) {
      setMsg({
        tipo: "error",
        texto: "Revisa las equivalencias XML. Usa el formato 001-006>100, apunta a un punto oficial y escribe el motivo.",
      });
      return;
    }

    setGuardando(true);
    setMsg(null);
    const items = Object.entries(formulario.almacenes).map(([almacen_id, configuracion]) => ({
      almacen_id,
      ...configuracion,
    }));
    const { error } = await supabase.rpc("admin_guardar_empresa_completa_v19", {
      p_empresa_id: formulario.id,
      p_grupo_id: grupo.id,
      p_codigo: formulario.codigo,
      p_ruc: formulario.ruc,
      p_razon_social: formulario.razon_social,
      p_nombre_comercial: formulario.nombre_comercial || null,
      p_tipo: formulario.tipo,
      p_obligado_contabilidad: formulario.obligado_contabilidad,
      p_activo: formulario.activo,
      p_almacenes: items,
      p_establecimientos: formulario.establecimientos.map((establecimiento) => ({
        codigo: establecimiento.codigo,
        nombre: establecimiento.nombre,
        almacen_id: establecimiento.almacen_id,
        direccion: establecimiento.direccion || null,
        es_matriz: establecimiento.es_matriz,
        activo: establecimiento.activo,
        puntos_emision: Array.from(new Set(separarPuntosEmision(establecimiento.puntos_emision_texto))),
        equivalencias_xml: separarEquivalenciasXml(establecimiento.equivalencias_xml_texto).map((equivalencia) => ({
          ...equivalencia,
          motivo: establecimiento.motivo_equivalencia.trim(),
        })),
      })),
    });
    setGuardando(false);
    if (error) {
      setMsg({ tipo: "error", texto: error.message });
      return;
    }

    setFormulario(null);
    setMsg({ tipo: "ok", texto: "Empresa, establecimientos y unidades operativas guardados con trazabilidad." });
    await cargar();
  }

  const resumenPorEmpresa = new Map(resumenes.map((resumen) => [resumen.empresa_id, resumen]));

  return (
    <>
      <div className="header-row">
        <div>
          <h2 style={{ color: "#1f3864", margin: 0 }}>Grupo económico y empresas</h2>
          <p className="conteo" style={{ marginTop: 4 }}>
            {grupo ? `${grupo.nombre} · ${empresas.length} RUC registrado(s)` : "Configuración multiempresa"}
          </p>
        </div>
        <button onClick={nuevaEmpresa}>+ Registrar empresa / RUC</button>
      </div>

      <div className="info-box" style={{ marginBottom: 14 }}>
        <strong>Modelo consolidado:</strong> el catálogo y el stock físico siguen compartidos por todo el grupo.
        Cada factura, documento y movimiento queda identificado con el RUC responsable. Cada RUC puede tener
        varios establecimientos SRI vinculados a sus tiendas o bodegas físicas. La empresa predeterminada de una
        ubicación solo clasifica operaciones ambiguas y no declara la propiedad contable de sus unidades.
      </div>

      {msg && <div className={msg.tipo === "error" ? "error" : "success"} style={{ marginBottom: 14 }}>{msg.texto}</div>}

      {!cargando && pendientes.length > 0 && (
        <div className="card" style={{ marginBottom: 14 }}>
          <div className="header-row">
            <div>
              <h3 style={{ margin: 0 }}>Pendientes de clasificación</h3>
              <span className="conteo">No detienen la operación actual, pero deben resolverse antes de activar contabilidad por empresa.</span>
            </div>
            <span className={`badge ${totalPendiente ? "alerta" : "ok"}`}>{totalPendiente} pendientes</span>
          </div>
          <div className="grid-2" style={{ marginTop: 12 }}>
            {pendientes.map((pendiente) => (
              <div className="info-box" key={pendiente.tipo} style={{ margin: 0 }}>
                <strong>{pendiente.cantidad}</strong> · {pendiente.detalle}
              </div>
            ))}
          </div>
        </div>
      )}

      {formulario && (
        <form className="card" onSubmit={guardar} style={{ marginBottom: 14 }}>
          <div className="header-row">
            <div>
              <h3 style={{ margin: 0 }}>{formulario.id ? "Editar empresa" : "Registrar empresa o RUC"}</h3>
              <span className="conteo">Los cambios quedan registrados en la auditoría multiempresa.</span>
            </div>
            <button type="button" className="chip-limpiar" onClick={() => setFormulario(null)}>Cerrar</button>
          </div>

          <div className="grid-2" style={{ marginTop: 14 }}>
            <div className="field">
              <label>Código interno</label>
              <input required maxLength={20} value={formulario.codigo}
                onChange={(e) => setFormulario({ ...formulario, codigo: e.target.value.toUpperCase() })}
                placeholder="CIA, SAS, PN, FABRICA..." />
            </div>
            <div className="field">
              <label>RUC</label>
              <input required inputMode="numeric" maxLength={13} value={formulario.ruc}
                onChange={(e) => setFormulario({ ...formulario, ruc: e.target.value.replace(/\D/g, "").slice(0, 13) })}
                placeholder="13 dígitos" />
            </div>
            <div className="field">
              <label>Razón social</label>
              <input required value={formulario.razon_social}
                onChange={(e) => setFormulario({ ...formulario, razon_social: e.target.value })} />
            </div>
            <div className="field">
              <label>Nombre comercial</label>
              <input value={formulario.nombre_comercial}
                onChange={(e) => setFormulario({ ...formulario, nombre_comercial: e.target.value })} />
            </div>
            <div className="field">
              <label>Figura legal</label>
              <select value={formulario.tipo}
                onChange={(e) => setFormulario({ ...formulario, tipo: e.target.value as TipoEmpresa })}>
                {TIPOS.map((tipo) => <option key={tipo.valor} value={tipo.valor}>{tipo.etiqueta}</option>)}
              </select>
            </div>
            <div className="field" style={{ display: "flex", gap: 18, alignItems: "end", paddingBottom: 8 }}>
              <label><input type="checkbox" checked={formulario.obligado_contabilidad}
                onChange={(e) => setFormulario({ ...formulario, obligado_contabilidad: e.target.checked })} /> Obligado a llevar contabilidad</label>
              <label><input type="checkbox" checked={formulario.activo}
                onChange={(e) => setFormulario({ ...formulario, activo: e.target.checked })} /> Activo</label>
            </div>
          </div>

          <h4 style={{ marginBottom: 8 }}>Tiendas y bodegas relacionadas</h4>
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr><th>Asignar</th><th>Unidad operativa</th><th>Empresa predeterminada</th><th>Ventas</th><th>Compras</th><th>Custodia stock</th></tr>
              </thead>
              <tbody>
                {almacenes.map((almacen) => {
                  const configuracion = formulario.almacenes[almacen.id];
                  return (
                    <tr key={almacen.id}>
                      <td><input type="checkbox" checked={Boolean(configuracion)} onChange={(e) => alternarAlmacen(almacen.id, e.target.checked)} /></td>
                      <td><strong>{almacen.nombre}</strong><div className="conteo">{almacen.codigo} · {almacen.tipo}</div></td>
                      <td><input type="checkbox" disabled={!configuracion} checked={configuracion?.es_operadora_principal ?? false} onChange={(e) => cambiarAlmacen(almacen.id, { es_operadora_principal: e.target.checked })} /></td>
                      <td><input type="checkbox" disabled={!configuracion} checked={configuracion?.permite_ventas ?? false} onChange={(e) => cambiarAlmacen(almacen.id, { permite_ventas: e.target.checked })} /></td>
                      <td><input type="checkbox" disabled={!configuracion} checked={configuracion?.permite_compras ?? false} onChange={(e) => cambiarAlmacen(almacen.id, { permite_compras: e.target.checked })} /></td>
                      <td><input type="checkbox" disabled={!configuracion} checked={configuracion?.custodia_inventario ?? false} onChange={(e) => cambiarAlmacen(almacen.id, { custodia_inventario: e.target.checked })} /></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          <div className="header-row" style={{ marginTop: 18 }}>
            <div>
              <h4 style={{ margin: 0 }}>Establecimientos del RUC</h4>
              <span className="conteo">Usa los códigos legales del SRI. Si el XML llega incorrectamente como 001-006 pero corresponde a 006-100, registra la equivalencia 001-006&gt;100.</span>
            </div>
            <button type="button" className="secondary" onClick={agregarEstablecimiento}>+ Agregar establecimiento</button>
          </div>
          <div className="tabla-scroll" style={{ marginTop: 10 }}>
            <table>
              <thead>
                <tr><th>Código SRI</th><th>Nombre</th><th>Ubicación física</th><th>Dirección</th><th>Matriz</th><th>Puntos oficiales</th><th>Equivalencias XML</th><th>Motivo</th><th>Estado</th><th></th></tr>
              </thead>
              <tbody>
                {formulario.establecimientos.map((establecimiento, indice) => (
                  <tr key={establecimiento.clave}>
                    <td><input required inputMode="numeric" maxLength={3} style={{ width: 72 }} value={establecimiento.codigo}
                      onChange={(e) => cambiarEstablecimiento(indice, { codigo: e.target.value.replace(/\D/g, "").slice(0, 3) })} placeholder="001" /></td>
                    <td><input required value={establecimiento.nombre}
                      onChange={(e) => cambiarEstablecimiento(indice, { nombre: e.target.value })} placeholder="Puyo" /></td>
                    <td><select value={establecimiento.almacen_id ?? ""}
                      onChange={(e) => cambiarEstablecimiento(indice, { almacen_id: e.target.value || null })}>
                      <option value="">Sin vincular</option>
                      {almacenes.filter((almacen) => Boolean(formulario.almacenes[almacen.id])).map((almacen) =>
                        <option key={almacen.id} value={almacen.id}>{almacen.nombre}</option>)}
                    </select></td>
                    <td><input value={establecimiento.direccion}
                      onChange={(e) => cambiarEstablecimiento(indice, { direccion: e.target.value })} placeholder="Dirección registrada" /></td>
                    <td><input type="checkbox" checked={establecimiento.es_matriz}
                      onChange={(e) => cambiarEstablecimiento(indice, { es_matriz: e.target.checked })} /></td>
                    <td><input value={establecimiento.puntos_emision_texto}
                      onChange={(e) => cambiarEstablecimiento(indice, { puntos_emision_texto: e.target.value })}
                      placeholder="001, 002" /></td>
                    <td><input value={establecimiento.equivalencias_xml_texto}
                      onChange={(e) => cambiarEstablecimiento(indice, { equivalencias_xml_texto: e.target.value.replace(/\s/g, "") })}
                      placeholder="001-006>100" title="XML establecimiento-punto > punto oficial" /></td>
                    <td><input value={establecimiento.motivo_equivalencia}
                      onChange={(e) => cambiarEstablecimiento(indice, { motivo_equivalencia: e.target.value })}
                      placeholder="Limitación temporal del facturador" /></td>
                    <td><label style={{ whiteSpace: "nowrap" }}><input type="checkbox" checked={establecimiento.activo}
                      onChange={(e) => cambiarEstablecimiento(indice, { activo: e.target.checked })} /> Activo</label></td>
                    <td><button type="button" className="chip-limpiar" onClick={() => quitarEstablecimiento(indice)}>Quitar</button></td>
                  </tr>
                ))}
                {!formulario.establecimientos.length && <tr><td colSpan={10} className="vacio">Agrega los establecimientos registrados bajo este RUC.</td></tr>}
              </tbody>
            </table>
          </div>

          <div style={{ marginTop: 14, display: "flex", gap: 8 }}>
            <button type="submit" disabled={guardando}>{guardando ? "Guardando..." : "Guardar empresa"}</button>
            <button type="button" className="secondary" onClick={() => setFormulario(null)}>Cancelar</button>
          </div>
        </form>
      )}

      <div className="card">
        <div className="header-row">
          <h3 style={{ margin: 0 }}>Estructura legal del grupo</h3>
          {cargando && <span className="conteo">Cargando...</span>}
        </div>
        <div className="tabla-scroll" style={{ marginTop: 12 }}>
          <table>
            <thead>
              <tr><th>Empresa / RUC</th><th>Figura</th><th>Establecimientos / unidades</th><th>Operación consolidada</th><th>Estado</th><th>Acciones</th></tr>
            </thead>
            <tbody>
              {empresas.map((empresa) => {
                const resumen = resumenPorEmpresa.get(empresa.id);
                const asignados = vinculos.filter((vinculo) => vinculo.empresa_id === empresa.id);
                const establecimientosEmpresa = establecimientos.filter((item) => item.empresa_id === empresa.id && item.activo);
                return (
                  <tr key={empresa.id}>
                    <td><strong>{empresa.codigo} · {empresa.razon_social}</strong><div>{empresa.nombre_comercial}</div><small>RUC {empresa.ruc}</small></td>
                    <td>{TIPOS.find((tipo) => tipo.valor === empresa.tipo)?.etiqueta}<div className="conteo">{empresa.obligado_contabilidad ? "Obligado a llevar contabilidad" : "No marcado como obligado"}</div></td>
                    <td>
                      {establecimientosEmpresa.map((establecimiento) => {
                        const almacen = almacenes.find((item) => item.id === establecimiento.almacen_id);
                        return <div key={establecimiento.id}>
                          <strong>{establecimiento.codigo} · {establecimiento.nombre}</strong>
                          {establecimiento.es_matriz ? " · matriz" : ""}
                          <div className="conteo">{almacen ? `Ubicación: ${almacen.nombre}` : "Sin ubicación física"} · PE {establecimiento.puntos_emision.join(", ") || "sin registrar"}</div>
                        </div>;
                      })}
                      {!establecimientosEmpresa.length && asignados.map((vinculo) => {
                        const almacen = almacenes.find((item) => item.id === vinculo.almacen_id);
                        return <div key={vinculo.almacen_id}>{almacen?.nombre ?? vinculo.almacen_id}{vinculo.es_operadora_principal ? " · predeterminada" : " · compartida"}</div>;
                      })}
                      {!establecimientosEmpresa.length && !asignados.length && <span className="conteo">Sin asignar</span>}
                    </td>
                    <td><strong>{resumen?.stock_fisico_operado ?? 0}</strong> unidades físicas operadas<div className="conteo">{resumen?.facturas_xml ?? 0} factura(s) XML · {resumen?.usuarios_asignados ?? 0} usuario(s)</div></td>
                    <td><span className={`badge ${empresa.activo ? "ok" : "cero"}`}>{empresa.activo ? "Activa" : "Inactiva"}</span></td>
                    <td><button className="secondary" onClick={() => editarEmpresa(empresa)}>Editar</button></td>
                  </tr>
                );
              })}
              {!empresas.length && !cargando && <tr><td colSpan={6} className="vacio">Registra primero la CIA, SAS, persona natural y los demás RUC del grupo.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
