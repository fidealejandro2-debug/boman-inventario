"use client";

import { useEffect, useMemo, useState } from "react";
import { mostrarAvisoDialogo, pedirMotivoDialogo } from "@/components/Dialogo";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { tienePermiso, type Perfil } from "@/lib/permisos";
import { createClient } from "@/lib/supabase/client";
import { mensajeError } from "@/lib/errores";
import { fechaISOEcuador } from "@/lib/utils";

type Empresa = { id: string; codigo: string; razon_social: string };
type CuentaBanco = { id: string; empresa_titular_id: string; banco: string; numero_cuenta: string; alias: string; prefijo_importacion: string | null };
type Resumen = { cuenta_bancaria_id: string; empresa_pagadora_codigo: string; alias: string; saldo_disponible: number; comprometido_total: number; comprometido_30_dias: number; saldo_proyectado_total: number; cheques_pendientes: number };
type Instrumento = { id: string; empresa_pagadora_codigo: string; cuenta_alias: string | null; beneficiario: string; numero_instrumento: string | null; monto: number; fecha_compromiso: string; estado: string; origen: string; comprobante_estado?: string; comprobante_numero?: string | null };
type Proveedor = { id: string; razon_social: string };
type Importacion = { id: string; nombre_archivo: string; hoja_origen: string; fecha_corte: string; estado: string; filas_validas: number; filas_observadas: number; filas_migradas: number; monto_detectado: number };
type Linea = { id: string; fila_origen: number; fecha_compromiso: string | null; beneficiario: string | null; codigo_original: string | null; monto: number | null; cuenta_sugerida: string | null; errores: string[] };

const DINERO = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });

function fechaExcel(valor: unknown, XLSX: typeof import("xlsx")) {
  if (valor instanceof Date && !Number.isNaN(valor.getTime())) return `${valor.getFullYear()}-${String(valor.getMonth() + 1).padStart(2, "0")}-${String(valor.getDate()).padStart(2, "0")}`;
  if (typeof valor === "number") { const d = XLSX.SSF.parse_date_code(valor); return d ? `${d.y}-${String(d.m).padStart(2, "0")}-${String(d.d).padStart(2, "0")}` : null; }
  const t = String(valor ?? "").trim();
  let m = t.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/);
  if (m) return `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}`;
  m = t.match(/^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$/);
  return m ? `${m[3]}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}` : null;
}

export default function TesoreriaInstrumentosV104({ perfil }: { perfil: Perfil }) {
  const supabase = useMemo(() => createClient(), []);
  const puedeEditar = tienePermiso(perfil, "tesoreria.editar");
  const hoy = fechaISOEcuador();
  const [cuentas, setCuentas] = useState<CuentaBanco[]>([]);
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [resumen, setResumen] = useState<Resumen[]>([]);
  const [instrumentos, setInstrumentos] = useState<Instrumento[]>([]);
  const [importaciones, setImportaciones] = useState<Importacion[]>([]);
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [mensaje, setMensaje] = useState("");
  const [modal, setModal] = useState<"cuenta" | "saldo" | "cheque" | null>(null);
  const [proveedores, setProveedores] = useState<Proveedor[]>([]);
  // El cheque a un proveedor que no factura: beneficiario libre, sin cuenta por
  // pagar detras. `comprobante` decide si queda como gasto asumido o como deuda
  // documental pendiente -esa decision se toma al firmar, no despues.
  const [formCheque, setFormCheque] = useState({
    cuenta: "", proveedor: "", beneficiario: "", numero: "", monto: "",
    emision: hoy, compromiso: hoy, estado: "emitido", comprobante: "pendiente", nota: "",
  });
  const [archivo, setArchivo] = useState<File | null>(null);
  const [libro, setLibro] = useState<import("xlsx").WorkBook | null>(null);
  const [hoja, setHoja] = useState("");
  const [corte, setCorte] = useState(hoy);
  const [formCuenta, setFormCuenta] = useState({ empresa: "", banco: "", numero: "", alias: "", prefijo: "" });
  const [formSaldo, setFormSaldo] = useState({ cuenta: "", fecha: hoy, saldo: "", nota: "Saldo disponible verificado" });

  async function registrarCheque() {
    const monto = Number(formCheque.monto);
    if (!formCheque.cuenta) return void mostrarAvisoDialogo("Elige la cuenta bancaria del cheque.", "Falta la cuenta", true);
    if (formCheque.beneficiario.trim().length < 2) return void mostrarAvisoDialogo("Escribe a nombre de quién se emite el cheque.", "Falta el beneficiario", true);
    if (!formCheque.numero.trim()) return void mostrarAvisoDialogo("Escribe el número del cheque.", "Falta el número", true);
    if (!Number.isFinite(monto) || monto <= 0) return void mostrarAvisoDialogo("El monto debe ser mayor que cero.", "Monto inválido", true);
    if (formCheque.nota.trim().length < 5) return void mostrarAvisoDialogo("Escribe una referencia de al menos 5 caracteres: es lo único que explicará este pago dentro de seis meses.", "Falta la referencia", true);
    setProcesando(true);
    const { error } = await supabase.rpc("registrar_cheque_v104", {
      p_cuenta_bancaria_id: formCheque.cuenta,
      p_proveedor_id: formCheque.proveedor || null,
      p_beneficiario: formCheque.beneficiario,
      p_numero_cheque: formCheque.numero,
      p_monto: monto,
      p_fecha_emision: formCheque.emision || null,
      p_fecha_compromiso: formCheque.compromiso,
      p_estado: formCheque.estado,
      p_nota: formCheque.nota,
      p_idempotency_key: nuevaClaveIdempotencia(),
      p_comprobante_estado: formCheque.comprobante,
    });
    setProcesando(false);
    if (error) return void mostrarAvisoDialogo(mensajeError(error, "v133_cheques_sin_factura.sql"), "No se pudo registrar el cheque", true);
    setModal(null);
    setFormCheque((f) => ({ ...f, proveedor: "", beneficiario: "", numero: "", monto: "", nota: "" }));
    setMensaje("Cheque registrado. El efectivo ya queda comprometido.");
    await cargar(true);
  }

  async function regularizar(i: Instrumento) {
    const numero = await pedirMotivoDialogo(
      `Escribe el número del comprobante que respalda el cheque ${i.numero_instrumento ?? ""} de ${i.beneficiario} (formato 001-001-000000001).`,
      5, "Comprobante emitido");
    if (!numero) return;
    setProcesando(true);
    const { data: comp } = await supabase.from("comprobantes_compra").select("id").eq("numero_documento", numero.trim()).maybeSingle();
    if (!comp) {
      setProcesando(false);
      return void mostrarAvisoDialogo(`No existe un comprobante ${numero.trim()} cargado en el sistema. Regístralo en Compras antes de enlazarlo.`, "Comprobante no encontrado", true);
    }
    const { error } = await supabase.rpc("regularizar_cheque_v133", {
      p_instrumento_id: i.id, p_comprobante_id: comp.id,
      p_motivo: `Comprobante ${numero.trim()} emitido para el cheque ${i.numero_instrumento ?? ""}`,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (error) return void mostrarAvisoDialogo(mensajeError(error, "v133_cheques_sin_factura.sql"), "No se pudo regularizar", true);
    setMensaje("Cheque regularizado.");
    await cargar(true);
  }

  async function cargar(silencioso = false) {
    if (!silencioso) setCargando(true);
    const [cb, em, re, ins, imp, lin, prov] = await Promise.all([
      supabase.from("tesoreria_cuentas_bancarias").select("id,empresa_titular_id,banco,numero_cuenta,alias,prefijo_importacion").eq("activa", true).order("alias"),
      supabase.from("vista_empresas_tesoreria_v73").select("id,codigo,razon_social").order("codigo"),
      supabase.from("vista_resumen_compromisos_v104").select("*").order("empresa_pagadora_codigo"),
      supabase.from("vista_instrumentos_tesoreria_v104").select("id,empresa_pagadora_codigo,cuenta_alias,beneficiario,numero_instrumento,monto,fecha_compromiso,estado,origen,comprobante_estado,comprobante_numero").order("fecha_compromiso").limit(500),
      supabase.from("tesoreria_importaciones").select("id,nombre_archivo,hoja_origen,fecha_corte,estado,filas_validas,filas_observadas,filas_migradas,monto_detectado").order("created_at", { ascending: false }).limit(20),
      supabase.from("vista_importacion_cheques_v104").select("id,fila_origen,fecha_compromiso,beneficiario,codigo_original,monto,cuenta_sugerida,errores").in("estado", ["lista", "observada"]).order("created_at", { ascending: false }).limit(300),
      supabase.from("proveedores").select("id,razon_social").order("razon_social").limit(500),
    ]);
    setCargando(false);
    const fallo = cb.error ?? em.error ?? re.error ?? ins.error ?? imp.error ?? lin.error;
    if (fallo) return void mostrarAvisoDialogo(`Confirma que instalaste v104 y v105.\n\n${fallo.message}`, "Tesorería no disponible");
    const c = (cb.data ?? []) as CuentaBanco[], e = (em.data ?? []) as Empresa[];
    setCuentas(c); setEmpresas(e); setResumen((re.data ?? []) as Resumen[]); setInstrumentos((ins.data ?? []) as Instrumento[]); setImportaciones((imp.data ?? []) as Importacion[]); setLineas((lin.data ?? []) as Linea[]); setProveedores((prov.data ?? []) as Proveedor[]);
    setFormSaldo((f) => ({ ...f, cuenta: f.cuenta || c[0]?.id || "" }));
    setFormCheque((f) => ({ ...f, cuenta: f.cuenta || c[0]?.id || "" }));
    setFormCuenta((f) => ({ ...f, empresa: f.empresa || e[0]?.id || "" }));
  }

  const pendientesComprobante = useMemo(
    () => instrumentos.filter((i) => i.comprobante_estado === "pendiente").length,
    [instrumentos],
  );

  useEffect(() => { void cargar(); }, []);

  async function guardarCuenta(e: React.FormEvent) {
    e.preventDefault(); const motivo = await pedirMotivoDialogo("Motivo para registrar esta cuenta bancaria:"); if (!motivo) return;
    setProcesando(true);
    const { error } = await supabase.rpc("guardar_cuenta_bancaria_v104", { p_id: null, p_empresa_titular_id: formCuenta.empresa, p_banco: formCuenta.banco, p_numero_cuenta: formCuenta.numero, p_alias: formCuenta.alias, p_prefijo: formCuenta.prefijo, p_tipo_cuenta: "corriente", p_activa: true, p_motivo: motivo, p_idempotency_key: nuevaClaveIdempotencia() });
    setProcesando(false); if (error) return void mostrarAvisoDialogo(error.message, "No se pudo guardar la cuenta");
    setModal(null); setMensaje("Cuenta bancaria registrada."); await cargar(true);
  }

  async function guardarSaldo(e: React.FormEvent) {
    e.preventDefault();
    if (formSaldo.nota.trim().length < 5) return void mostrarAvisoDialogo("Escribe una referencia de al menos 5 caracteres.");
    setProcesando(true);
    const { error } = await supabase.rpc("registrar_saldo_bancario_v104", { p_cuenta_bancaria_id: formSaldo.cuenta, p_fecha: formSaldo.fecha, p_saldo: Number(formSaldo.saldo), p_fuente: "manual", p_nota: formSaldo.nota, p_idempotency_key: nuevaClaveIdempotencia() });
    setProcesando(false); if (error) return void mostrarAvisoDialogo(error.message, "No se pudo registrar el saldo");
    setModal(null); setMensaje("Saldo bancario actualizado."); await cargar(true);
  }

  async function leerArchivo(file: File | null) {
    setArchivo(file); setLibro(null); setHoja(""); if (!file) return;
    try { const XLSX = await import("xlsx"); const wb = XLSX.read(await file.arrayBuffer(), { type: "array", cellDates: true }); setLibro(wb); setHoja(wb.SheetNames.find((n) => n.toUpperCase().includes("AUSTRO TODOS")) ?? wb.SheetNames[0] ?? ""); }
    catch (e) { await mostrarAvisoDialogo(e instanceof Error ? e.message : String(e), "No se pudo leer el Excel"); }
  }

  async function importar() {
    if (!archivo || !libro || !hoja) return void mostrarAvisoDialogo("Selecciona el Excel y una hoja.");
    if (!cuentas.length) return void mostrarAvisoDialogo("Primero registra las cuentas bancarias con prefijo BM o IN.");
    setProcesando(true);
    try {
      const XLSX = await import("xlsx");
      const matriz = XLSX.utils.sheet_to_json<unknown[]>(libro.Sheets[hoja], { header: 1, raw: true, defval: "" });
      const filas = matriz.map((r, i) => { const fecha = fechaExcel(r[0], XLSX); const monto = Number(String(r[7] ?? "").replace(/[$\s]/g, "").replace(",", ".")); return { fila: i + 1, fecha, beneficiario: String(r[2] ?? "").trim(), codigo_cheque: String(r[6] ?? "").trim(), monto: Number.isFinite(monto) ? monto.toFixed(2) : "", observacion: String(r[8] ?? "").trim() }; }).filter((r) => r.fecha && r.fecha >= corte && r.beneficiario && r.beneficiario.toUpperCase() !== "TOTAL" && r.codigo_cheque && Number(r.monto) > 0);
      if (!filas.length) throw new Error("No se detectaron cheques válidos desde la fecha de corte.");
      if (filas.length > 2500) throw new Error("Hay más de 2500 cheques; divide la migración en dos archivos.");
      const { error } = await supabase.rpc("cargar_cheques_migracion_v104", { p_nombre_archivo: archivo.name, p_hoja: hoja, p_fecha_corte: corte, p_filas: filas, p_nota: "Migración controlada desde Tesorería", p_idempotency_key: nuevaClaveIdempotencia() });
      if (error) throw error;
      setMensaje(`${filas.length} cheque(s) cargados para revisión; aún no comprometen efectivo.`); setArchivo(null); setLibro(null); setHoja(""); await cargar(true);
    } catch (e) { await mostrarAvisoDialogo(e instanceof Error ? e.message : String(e), "No se pudo importar"); }
    finally { setProcesando(false); }
  }

  async function confirmarLote(item: Importacion) {
    const motivo = await pedirMotivoDialogo(`Motivo para confirmar los cheques válidos de ${item.nombre_archivo}:`); if (!motivo) return;
    setProcesando(true); const { data, error } = await supabase.rpc("confirmar_lote_cheques_v105", { p_importacion_id: item.id, p_nota: motivo, p_idempotency_key: nuevaClaveIdempotencia() }); setProcesando(false);
    if (error) return void mostrarAvisoDialogo(error.message, "No se pudo confirmar el lote");
    const r = data as { confirmadas?: number; observadas?: number } | null; setMensaje(`${r?.confirmadas ?? 0} cheque(s) confirmados; ${r?.observadas ?? 0} observados.`); await cargar(true);
  }

  async function descartar(l: Linea) {
    const motivo = await pedirMotivoDialogo(`Motivo para descartar la fila ${l.fila_origen}:`); if (!motivo) return;
    const { error } = await supabase.rpc("descartar_linea_importacion_v104", { p_linea_id: l.id, p_detalle: motivo, p_idempotency_key: nuevaClaveIdempotencia() });
    if (error) return void mostrarAvisoDialogo(error.message, "No se pudo descartar"); setMensaje("Fila descartada con trazabilidad."); await cargar(true);
  }

  const total = resumen.reduce((a, r) => ({ saldo: a.saldo + Number(r.saldo_disponible), compromiso: a.compromiso + Number(r.comprometido_total), d30: a.d30 + Number(r.comprometido_30_dias), proyectado: a.proyectado + Number(r.saldo_proyectado_total) }), { saldo: 0, compromiso: 0, d30: 0, proyectado: 0 });
  if (cargando) return <div className="vacio card">Cargando bancos y cheques…</div>;

  return <div className="tesoreria-v104">
    {mensaje && <div className="success-box">{mensaje}</div>}
    <div className="kpis compactos"><div className="kpi"><span className="label">Saldo bancario</span><strong className="valor">{DINERO.format(total.saldo)}</strong></div><div className="kpi compromiso"><span className="label">Efectivo comprometido</span><strong className="valor">{DINERO.format(total.compromiso)}</strong></div><div className="kpi"><span className="label">Sale en 30 días</span><strong className="valor">{DINERO.format(total.d30)}</strong></div><div className={`kpi ${total.proyectado < 0 ? "alerta" : "ok"}`}><span className="label">Saldo proyectado</span><strong className="valor">{DINERO.format(total.proyectado)}</strong></div></div>
    <section className="card tesoreria-seccion"><div className="header-row"><div><h3>Cuentas bancarias</h3><p className="conteo">BM: BMSPORT SAS · IN: Internacional de Alejandra.</p></div>{puedeEditar && <div className="acciones"><button className="secondary" onClick={() => setModal("saldo")}>Registrar saldo</button><button onClick={() => setModal("cuenta")}>Nueva cuenta</button></div>}</div>{resumen.length ? <div className="tesoreria-cuentas">{resumen.map((r) => <article className="card-interna" key={r.cuenta_bancaria_id}><strong>{r.alias}</strong><span className="badge">{r.empresa_pagadora_codigo}</span><p>{DINERO.format(Number(r.saldo_disponible))} disponible · {r.cheques_pendientes} cheque(s)</p><small>Comprometido {DINERO.format(Number(r.comprometido_total))} · proyectado {DINERO.format(Number(r.saldo_proyectado_total))}</small></article>)}</div> : <div className="vacio">Registra las cuentas desde las que se emiten cheques.</div>}</section>
    {puedeEditar && <section className="card tesoreria-seccion"><h3>Migrar cheques desde Excel</h3><p className="conteo">Lee fecha (A), beneficiario (C), código BM/IN (G), monto (H) y observación (I).</p><div className="grid-2"><div className="field"><label>Archivo</label><input type="file" accept=".xlsx,.xls" onChange={(e) => void leerArchivo(e.target.files?.[0] ?? null)} /></div><div className="field"><label>Hoja</label><select disabled={!libro} value={hoja} onChange={(e) => setHoja(e.target.value)}><option value="">Selecciona…</option>{libro?.SheetNames.map((n) => <option key={n}>{n}</option>)}</select></div><div className="field"><label>Fecha de corte</label><input type="date" value={corte} onChange={(e) => setCorte(e.target.value)} /></div></div><button disabled={procesando || !libro} onClick={() => void importar()}>{procesando ? "Procesando…" : "Cargar para revisión"}</button></section>}
    <section className="card tesoreria-seccion"><h3>Lotes de importación</h3>{importaciones.length ? <div className="tabla-scroll"><table><thead><tr><th>Archivo</th><th>Estado</th><th className="num">Válidas</th><th className="num">Observadas</th><th className="num">Migradas</th><th className="num">Monto</th><th></th></tr></thead><tbody>{importaciones.map((i) => <tr key={i.id}><td><strong>{i.nombre_archivo}</strong><div className="conteo">{i.hoja_origen} · corte {i.fecha_corte}</div></td><td><span className="badge">{i.estado}</span></td><td className="num">{i.filas_validas}</td><td className="num">{i.filas_observadas}</td><td className="num">{i.filas_migradas}</td><td className="num">{DINERO.format(Number(i.monto_detectado))}</td><td>{puedeEditar && i.estado === "en_revision" && i.filas_validas > 0 && <button className="btn-mini" disabled={procesando} onClick={() => void confirmarLote(i)}>Confirmar válidas</button>}</td></tr>)}</tbody></table></div> : <div className="vacio">No existen importaciones.</div>}</section>
    {lineas.length > 0 && <section className="card tesoreria-seccion"><h3>Filas pendientes de resolver</h3><div className="tabla-scroll"><table><thead><tr><th>Fila</th><th>Fecha</th><th>Beneficiario</th><th>Cheque</th><th>Cuenta</th><th>Observaciones</th><th className="num">Monto</th><th></th></tr></thead><tbody>{lineas.map((l) => <tr key={l.id}><td>{l.fila_origen}</td><td>{l.fecha_compromiso ?? "—"}</td><td>{l.beneficiario ?? "—"}</td><td>{l.codigo_original ?? "—"}</td><td>{l.cuenta_sugerida ?? "Sin configurar"}</td><td>{l.errores?.join(", ") || "Lista"}</td><td className="num">{l.monto ? DINERO.format(Number(l.monto)) : "—"}</td><td>{puedeEditar && <button className="btn-mini peligro" onClick={() => void descartar(l)}>Descartar</button>}</td></tr>)}</tbody></table></div></section>}
    <section className="card tesoreria-seccion"><div className="header-row"><div><h3 style={{margin:0}}>Cheques e instrumentos</h3><p className="conteo">Un cheque puede nacer suelto: no necesita factura ni cuenta por pagar detrás.</p></div>{puedeEditar && <button onClick={() => setModal("cheque")}>+ Registrar cheque</button>}</div>{pendientesComprobante > 0 && <div className="badge bajo" style={{display:"block",whiteSpace:"normal",lineHeight:1.4,marginBottom:10}}>Hay {pendientesComprobante} cheque(s) esperando comprobante. Mientras no se emita la liquidación de compra, ese gasto no es deducible.</div>}{instrumentos.length ? <div className="tabla-scroll"><table><thead><tr><th>Salida</th><th>Cuenta</th><th>Beneficiario</th><th>Cheque</th><th>Estado</th><th>Comprobante</th><th className="num">Monto</th></tr></thead><tbody>{instrumentos.map((i) => <tr key={i.id}><td>{i.fecha_compromiso}</td><td><strong>{i.empresa_pagadora_codigo}</strong><div className="conteo">{i.cuenta_alias ?? "—"}</div></td><td>{i.beneficiario}</td><td>{i.numero_instrumento ?? "—"}</td><td><span className="badge">{i.estado}</span></td><td>{i.comprobante_estado === "regularizado"
      ? <span className="badge ok">{i.comprobante_numero ?? "regularizado"}</span>
      : i.comprobante_estado === "pendiente"
        ? <>
            <span className="badge bajo">pendiente</span>
            {puedeEditar && <button className="secondary btn-mini" disabled={procesando} onClick={() => void regularizar(i)}>Enlazar</button>}
          </>
        : <span className="conteo">sin comprobante</span>}</td><td className="num">{DINERO.format(Number(i.monto))}</td></tr>)}</tbody></table></div> : <div className="vacio">Todavía no hay instrumentos registrados.</div>}</section>
    {modal === "cuenta" && <div className="modal-operativo"><form className="modal-contenido" onSubmit={guardarCuenta}><div className="header-row"><h3>Nueva cuenta bancaria</h3><button type="button" className="secondary" onClick={() => setModal(null)}>Cerrar</button></div><div className="field"><label>Empresa titular</label><select required value={formCuenta.empresa} onChange={(e) => setFormCuenta({ ...formCuenta, empresa: e.target.value })}>{empresas.map((x) => <option key={x.id} value={x.id}>{x.codigo} · {x.razon_social}</option>)}</select></div><div className="grid-2"><div className="field"><label>Banco</label><input required minLength={3} value={formCuenta.banco} onChange={(e) => setFormCuenta({ ...formCuenta, banco: e.target.value })} /></div><div className="field"><label>Número de cuenta</label><input required minLength={3} value={formCuenta.numero} onChange={(e) => setFormCuenta({ ...formCuenta, numero: e.target.value })} /></div><div className="field"><label>Alias</label><input required minLength={3} value={formCuenta.alias} onChange={(e) => setFormCuenta({ ...formCuenta, alias: e.target.value })} /></div><div className="field"><label>Prefijo del Excel</label><select required value={formCuenta.prefijo} onChange={(e) => setFormCuenta({ ...formCuenta, prefijo: e.target.value })}><option value="">Selecciona…</option><option>BM</option><option>IN</option></select></div></div><button disabled={procesando}>Guardar cuenta</button></form></div>}
    {modal === "cheque" && <div className="modal-operativo"><form className="modal-contenido" onSubmit={(e) => { e.preventDefault(); void registrarCheque() }}>
      <div className="header-row"><div><h3 style={{margin:0}}>Registrar cheque</h3><p className="conteo">Para pagos que no pasan por una cuenta por pagar.</p></div><button type="button" className="secondary" onClick={() => setModal(null)}>Cerrar</button></div>
      <div className="grid-2">
        <div className="field"><label>Cuenta bancaria</label><select required value={formCheque.cuenta} onChange={(e) => setFormCheque({ ...formCheque, cuenta: e.target.value })}>{cuentas.map((x) => <option key={x.id} value={x.id}>{x.alias}</option>)}</select></div>
        <div className="field"><label>N.º de cheque</label><input required value={formCheque.numero} onChange={(e) => setFormCheque({ ...formCheque, numero: e.target.value })} /></div>
      </div>
      <div className="field"><label>Beneficiario</label><input required minLength={2} placeholder="A nombre de quién se emite" value={formCheque.beneficiario} onChange={(e) => setFormCheque({ ...formCheque, beneficiario: e.target.value })} /></div>
      <div className="field"><label>Proveedor registrado (opcional)</label><select value={formCheque.proveedor} onChange={(e) => setFormCheque({ ...formCheque, proveedor: e.target.value })}><option value="">No está en el catálogo</option>{proveedores.map((x) => <option key={x.id} value={x.id}>{x.razon_social}</option>)}</select><p className="conteo">Enlázalo si el proveedor ya existe: así el pago suma a su historial.</p></div>
      <div className="grid-2">
        <div className="field"><label>Monto</label><input required type="number" step="0.01" min="0.01" value={formCheque.monto} onChange={(e) => setFormCheque({ ...formCheque, monto: e.target.value })} /></div>
        <div className="field"><label>Estado</label><select value={formCheque.estado} onChange={(e) => setFormCheque({ ...formCheque, estado: e.target.value })}><option value="emitido">Emitido</option><option value="entregado">Entregado</option><option value="programado">Programado</option><option value="borrador">Borrador</option></select></div>
        <div className="field"><label>Fecha de emisión</label><input type="date" value={formCheque.emision} onChange={(e) => setFormCheque({ ...formCheque, emision: e.target.value })} /></div>
        <div className="field"><label>Débito previsto</label><input required type="date" value={formCheque.compromiso} onChange={(e) => setFormCheque({ ...formCheque, compromiso: e.target.value })} /></div>
      </div>
      <div className="field"><label>Comprobante</label>
        <select value={formCheque.comprobante} onChange={(e) => setFormCheque({ ...formCheque, comprobante: e.target.value })}>
          <option value="pendiente">Pendiente — se emitirá liquidación de compra</option>
          <option value="no_aplica">Sin comprobante — gasto no deducible asumido</option>
        </select>
        <p className="conteo">Esta decisión se toma ahora, al firmar. Los &quot;pendiente&quot; quedan listados hasta que se enlace el documento; los &quot;sin comprobante&quot; no vuelven a aparecer.</p>
      </div>
      <div className="field"><label>Referencia</label><input required minLength={5} placeholder="Qué se pagó: es lo único que explicará este cheque dentro de seis meses" value={formCheque.nota} onChange={(e) => setFormCheque({ ...formCheque, nota: e.target.value })} /></div>
      <button disabled={procesando}>{procesando ? "Registrando…" : "Registrar cheque"}</button>
    </form></div>}
    {modal === "saldo" && <div className="modal-operativo"><form className="modal-contenido" onSubmit={guardarSaldo}><div className="header-row"><h3>Registrar saldo disponible</h3><button type="button" className="secondary" onClick={() => setModal(null)}>Cerrar</button></div><div className="field"><label>Cuenta</label><select required value={formSaldo.cuenta} onChange={(e) => setFormSaldo({ ...formSaldo, cuenta: e.target.value })}>{cuentas.map((x) => <option key={x.id} value={x.id}>{x.alias}</option>)}</select></div><div className="grid-2"><div className="field"><label>Fecha</label><input required type="date" max={hoy} value={formSaldo.fecha} onChange={(e) => setFormSaldo({ ...formSaldo, fecha: e.target.value })} /></div><div className="field"><label>Saldo</label><input required type="number" step="0.01" value={formSaldo.saldo} onChange={(e) => setFormSaldo({ ...formSaldo, saldo: e.target.value })} /></div></div><div className="field"><label>Referencia</label><input required minLength={5} value={formSaldo.nota} onChange={(e) => setFormSaldo({ ...formSaldo, nota: e.target.value })} /></div><button disabled={procesando}>Registrar saldo</button></form></div>}
  </div>;
}
