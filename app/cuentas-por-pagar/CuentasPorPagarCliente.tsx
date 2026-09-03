"use client";

import { useEffect, useMemo, useState } from "react";
import { confirmarDialogo, pedirMotivoDialogo } from "@/components/Dialogo";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { tienePermiso, type Perfil } from "@/lib/permisos";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV, fechaISOEcuador } from "@/lib/utils";

type Empresa = { id: string; codigo: string; razon_social: string };
type Configuracion = {
  grupo_id: string; empresa_pagadora_predeterminada_id: string;
  dias_credito_predeterminados: number;
};
type Cuenta = {
  id: string; grupo_id: string; comprobante_id: string;
  empresa_deudora_id: string; empresa_deudora_codigo: string; empresa_deudora: string;
  empresa_pagadora_id: string; empresa_pagadora_codigo: string; empresa_pagadora: string;
  proveedor_id: string; proveedor_identificacion: string; proveedor: string;
  comprobante_tipo: string; numero_documento: string; fecha_documento: string;
  fecha_vencimiento: string; total_documento: number; total_retenciones: number;
  total_exigible: number; total_pagado: number; total_comprometido: number;
  saldo_pendiente: number; saldo_por_programar: number; dias_vencida: number;
  estado: "pendiente" | "programada" | "parcial" | "vencida" | "pagada" | "anulada";
  nota: string | null; created_at: string; updated_at: string;
};
type Pago = {
  id: string; cuenta_id: string; empresa_pagadora_id: string;
  medio: "cheque" | "transferencia" | "efectivo" | "tarjeta" | "otro";
  monto: number; fecha_programada: string;
  estado: "programado" | "emitido" | "entregado" | "pagado" | "anulado";
  banco: string | null; numero_cuenta: string | null; numero_cheque: string | null;
  fecha_pago: string | null; nota: string | null; motivo_anulacion: string | null;
  created_at: string;
};
type Compromiso = {
  pago_id: string; cuenta_id: string; empresa_pagadora_id: string;
  empresa_pagadora_codigo: string; empresa_pagadora: string;
  empresa_deudora_codigo: string; proveedor: string; numero_documento: string;
  medio: string; monto: number; fecha_programada: string; dias_para_salida: number;
  estado: string; banco: string | null; numero_cuenta: string | null;
  numero_cheque: string | null; fecha_pago: string | null; nota: string | null;
};
type Resumen = {
  empresa_pagadora_id: string; empresa_pagadora_codigo: string; empresa_pagadora: string;
  saldo_total: number; saldo_vencido: number; saldo_por_programar: number;
  comprometido_total: number; comprometido_hoy: number;
  comprometido_7_dias: number; comprometido_30_dias: number;
  cheques_en_transito: number;
};
type FormPago = {
  medio: Pago["medio"]; monto: string; fechaProgramada: string;
  banco: string; numeroCuenta: string; numeroCheque: string;
  yaPagado: boolean; fechaPago: string; nota: string;
};
type FormCuenta = { empresaPagadoraId: string; fechaVencimiento: string; nota: string };
type FormConfig = { empresaPagadoraId: string; diasCredito: string; aplicarPendientes: boolean; motivo: string };
type Tab = "cartera" | "calendario";

const DINERO = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });
const ESTADO_CUENTA: Record<Cuenta["estado"], string> = {
  pendiente: "Pendiente", programada: "Programada", parcial: "Pago parcial",
  vencida: "Vencida", pagada: "Pagada", anulada: "Anulada",
};
const ESTADO_PAGO: Record<Pago["estado"], string> = {
  programado: "Programado", emitido: "Cheque emitido", entregado: "Cheque entregado",
  pagado: "Pagado / cobrado", anulado: "Anulado",
};
const MEDIO: Record<string, string> = {
  cheque: "Cheque", transferencia: "Transferencia", efectivo: "Efectivo",
  tarjeta: "Tarjeta", otro: "Otro",
};

function fechaCorta(valor: string | null) {
  if (!valor) return "—";
  const [a, m, d] = valor.slice(0, 10).split("-");
  return `${d}/${m}/${a}`;
}

export default function CuentasPorPagarCliente({ perfil }: { perfil: Perfil }) {
  const supabase = useMemo(() => createClient(), []);
  const puedeEditar = tienePermiso(perfil, "tesoreria.editar");
  const hoy = fechaISOEcuador();
  const [tab, setTab] = useState<Tab>("cartera");
  const [cuentas, setCuentas] = useState<Cuenta[]>([]);
  const [pagos, setPagos] = useState<Pago[]>([]);
  const [compromisos, setCompromisos] = useState<Compromiso[]>([]);
  const [resumen, setResumen] = useState<Resumen[]>([]);
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [configuracion, setConfiguracion] = useState<Configuracion | null>(null);
  const [busqueda, setBusqueda] = useState("");
  const [estado, setEstado] = useState("");
  const [pagadoraId, setPagadoraId] = useState("");
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);
  const [cuentaAbierta, setCuentaAbierta] = useState<string | null>(null);
  const [programando, setProgramando] = useState<Cuenta | null>(null);
  const [editando, setEditando] = useState<Cuenta | null>(null);
  const [configurando, setConfigurando] = useState(false);
  const [formPago, setFormPago] = useState<FormPago>({
    medio: "cheque", monto: "", fechaProgramada: hoy,
    banco: "", numeroCuenta: "", numeroCheque: "",
    yaPagado: false, fechaPago: hoy, nota: "",
  });
  const [formCuenta, setFormCuenta] = useState<FormCuenta>({ empresaPagadoraId: "", fechaVencimiento: hoy, nota: "" });
  const [formConfig, setFormConfig] = useState<FormConfig>({ empresaPagadoraId: "", diasCredito: "30", aplicarPendientes: true, motivo: "Configuración inicial de tesorería" });

  async function cargar() {
    setCargando(true); setError(null);
    const [c, p, co, r, e, tc] = await Promise.all([
      supabase.from("vista_cuentas_por_pagar_v73").select("*").order("fecha_vencimiento").limit(1000),
      supabase.from("cuentas_por_pagar_pagos").select("id,cuenta_id,empresa_pagadora_id,medio,monto,fecha_programada,estado,banco,numero_cuenta,numero_cheque,fecha_pago,nota,motivo_anulacion,created_at").order("created_at", { ascending: false }).limit(2000),
      supabase.from("vista_efectivo_comprometido_v73").select("*").order("fecha_programada").limit(1000),
      supabase.from("vista_resumen_tesoreria_v73").select("*").order("empresa_pagadora_codigo"),
      supabase.from("vista_empresas_tesoreria_v73").select("id,codigo,razon_social").order("codigo"),
      supabase.from("tesoreria_configuracion").select("grupo_id,empresa_pagadora_predeterminada_id,dias_credito_predeterminados").limit(1).maybeSingle(),
    ]);
    setCargando(false);
    const fallo = c.error ?? p.error ?? co.error ?? r.error ?? e.error ?? tc.error;
    if (fallo) return setError(`No se pudo cargar Cuentas por pagar. Verifica v73: ${fallo.message}`);
    setCuentas((c.data ?? []) as Cuenta[]);
    setPagos((p.data ?? []) as Pago[]);
    setCompromisos((co.data ?? []) as Compromiso[]);
    setResumen((r.data ?? []) as Resumen[]);
    const empresasData = (e.data ?? []) as Empresa[];
    const config = (tc.data as Configuracion | null) ?? null;
    setEmpresas(empresasData); setConfiguracion(config);
    setFormConfig((actual) => ({
      ...actual,
      empresaPagadoraId: config?.empresa_pagadora_predeterminada_id || actual.empresaPagadoraId || empresasData[0]?.id || "",
      diasCredito: String(config?.dias_credito_predeterminados ?? 30),
    }));
  }

  useEffect(() => { cargar(); }, []);

  const cuentasFiltradas = useMemo(() => {
    const q = busqueda.trim().toLocaleLowerCase("es");
    return cuentas.filter((cuenta) => (!estado || cuenta.estado === estado)
      && (!pagadoraId || cuenta.empresa_pagadora_id === pagadoraId)
      && (!q || [cuenta.proveedor, cuenta.proveedor_identificacion, cuenta.numero_documento,
        cuenta.empresa_deudora_codigo, cuenta.empresa_pagadora_codigo]
        .some((valor) => valor.toLocaleLowerCase("es").includes(q))));
  }, [busqueda, cuentas, estado, pagadoraId]);

  const kpis = useMemo(() => cuentasFiltradas.reduce((acc, cuenta) => {
    if (cuenta.estado !== "anulada") {
      acc.saldo += Number(cuenta.saldo_pendiente);
      acc.comprometido += Number(cuenta.total_comprometido);
      acc.porProgramar += Number(cuenta.saldo_por_programar);
      if (cuenta.estado === "vencida") acc.vencido += Number(cuenta.saldo_pendiente);
    }
    return acc;
  }, { saldo: 0, comprometido: 0, porProgramar: 0, vencido: 0 }), [cuentasFiltradas]);

  const calendario = useMemo(() => {
    const mapa = new Map<string, Compromiso[]>();
    compromisos.filter((pago) => ["programado", "emitido", "entregado"].includes(pago.estado)
      && (!pagadoraId || pago.empresa_pagadora_id === pagadoraId))
      .forEach((pago) => mapa.set(pago.fecha_programada, [...(mapa.get(pago.fecha_programada) ?? []), pago]));
    return Array.from(mapa.entries()).sort(([a], [b]) => a.localeCompare(b));
  }, [compromisos, pagadoraId]);

  function abrirProgramacion(cuenta: Cuenta) {
    setProgramando(cuenta); setError(null);
    setFormPago({
      medio: "cheque", monto: cuenta.saldo_por_programar > 0 ? String(cuenta.saldo_por_programar) : "",
      fechaProgramada: cuenta.fecha_vencimiento < hoy ? hoy : cuenta.fecha_vencimiento,
      banco: "", numeroCuenta: "", numeroCheque: "", yaPagado: false,
      fechaPago: hoy, nota: `Pago factura ${cuenta.numero_documento}`,
    });
  }

  async function guardarPago(evento: React.FormEvent) {
    evento.preventDefault();
    if (!programando) return;
    const monto = Number(formPago.monto);
    if (!Number.isFinite(monto) || monto <= 0 || monto > Number(programando.saldo_por_programar) + 0.004) return setError("El monto debe ser mayor que cero y no superar el saldo sin programar.");
    if (formPago.medio === "cheque" && (!formPago.banco.trim() || !formPago.numeroCuenta.trim() || !formPago.numeroCheque.trim())) return setError("Para un cheque indica banco, cuenta y número de cheque.");
    if (formPago.nota.trim().length < 5) return setError("Añade una referencia de al menos 5 caracteres.");
    if (formPago.yaPagado && formPago.fechaProgramada > hoy) return setError("Un pago ya realizado no puede tener salida futura.");
    setProcesando(true); setError(null); setMensaje(null);
    const { error: rpcError } = await supabase.rpc("programar_pago_cuenta_v73", {
      p_cuenta_id: programando.id, p_medio: formPago.medio, p_monto: monto,
      p_fecha_programada: formPago.fechaProgramada, p_banco: formPago.banco.trim() || null,
      p_numero_cuenta: formPago.numeroCuenta.trim() || null,
      p_numero_cheque: formPago.numeroCheque.trim() || null,
      p_ya_pagado: formPago.yaPagado, p_fecha_pago: formPago.yaPagado ? formPago.fechaPago : null,
      p_nota: formPago.nota.trim(), p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (rpcError) return setError(rpcError.message);
    setProgramando(null); setMensaje(formPago.yaPagado ? "Pago registrado y aplicado al saldo." : "Salida de efectivo programada.");
    await cargar();
  }

  function abrirEdicion(cuenta: Cuenta) {
    setEditando(cuenta); setError(null);
    setFormCuenta({ empresaPagadoraId: cuenta.empresa_pagadora_id, fechaVencimiento: cuenta.fecha_vencimiento, nota: cuenta.nota ?? "" });
  }

  async function guardarCuenta(evento: React.FormEvent) {
    evento.preventDefault();
    if (!editando) return;
    setProcesando(true); setError(null); setMensaje(null);
    const { error: rpcError } = await supabase.rpc("actualizar_cuenta_por_pagar_v73", {
      p_cuenta_id: editando.id, p_empresa_pagadora_id: formCuenta.empresaPagadoraId,
      p_fecha_vencimiento: formCuenta.fechaVencimiento, p_nota: formCuenta.nota.trim() || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (rpcError) return setError(rpcError.message);
    setEditando(null); setMensaje("Condiciones de pago actualizadas."); await cargar();
  }

  async function guardarConfiguracion(evento: React.FormEvent) {
    evento.preventDefault();
    const dias = Number(formConfig.diasCredito);
    if (!formConfig.empresaPagadoraId || !Number.isInteger(dias) || dias < 0 || dias > 365) return setError("Selecciona la compañía pagadora e indica de 0 a 365 días de crédito.");
    if (formConfig.motivo.trim().length < 10) return setError("Documenta la configuración con al menos 10 caracteres.");
    setProcesando(true); setError(null); setMensaje(null);
    const { data, error: rpcError } = await supabase.rpc("configurar_tesoreria_v73", {
      p_empresa_pagadora_id: formConfig.empresaPagadoraId, p_dias_credito: dias,
      p_aplicar_pendientes: formConfig.aplicarPendientes, p_motivo: formConfig.motivo.trim(),
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (rpcError) return setError(rpcError.message);
    const resultado = data as { cuentas_actualizadas?: number } | null;
    setConfigurando(false); setMensaje(`Configuración guardada. ${resultado?.cuentas_actualizadas ?? 0} cuenta(s) pendiente(s) fueron reasignadas.`); await cargar();
  }

  async function gestionarPago(pago: Pago, nuevoEstado: "emitido" | "entregado" | "pagado" | "anulado") {
    const verbo = nuevoEstado === "anulado" ? "anular" : nuevoEstado === "pagado" ? "confirmar como pagado" : `marcar ${nuevoEstado}`;
    if (nuevoEstado === "anulado" && !await confirmarDialogo(`Se liberará el efectivo comprometido por ${DINERO.format(Number(pago.monto))}. ¿Deseas anularlo?`)) return;
    const detalle = (await pedirMotivoDialogo(`Detalle para ${verbo} este ${MEDIO[pago.medio].toLowerCase()}:`))?.trim();
    if (!detalle) return;
    setProcesando(true); setError(null); setMensaje(null);
    const { error: rpcError } = await supabase.rpc("gestionar_pago_cuenta_v73", {
      p_pago_id: pago.id, p_nuevo_estado: nuevoEstado,
      p_fecha_pago: nuevoEstado === "pagado" ? hoy : null,
      p_detalle: detalle, p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (rpcError) return setError(rpcError.message);
    setMensaje(nuevoEstado === "pagado" ? "Pago confirmado; el saldo de la factura fue actualizado." : nuevoEstado === "anulado" ? "Compromiso anulado y efectivo liberado." : `Cheque marcado como ${nuevoEstado}.`);
    await cargar();
  }

  function exportar() {
    exportarCSV("cuentas_por_pagar", cuentasFiltradas.map((cuenta) => ({
      Estado: ESTADO_CUENTA[cuenta.estado], Proveedor: cuenta.proveedor,
      Identificacion: cuenta.proveedor_identificacion, Factura: cuenta.numero_documento,
      Empresa_facturada: cuenta.empresa_deudora_codigo, Empresa_pagadora: cuenta.empresa_pagadora_codigo,
      Emision: cuenta.fecha_documento, Vencimiento: cuenta.fecha_vencimiento,
      Total: cuenta.total_documento, Retenciones: cuenta.total_retenciones,
      Exigible: cuenta.total_exigible, Pagado: cuenta.total_pagado,
      Comprometido: cuenta.total_comprometido, Saldo_por_programar: cuenta.saldo_por_programar,
    })));
  }

  const resumenVisible = pagadoraId ? resumen.find((item) => item.empresa_pagadora_id === pagadoraId) : null;
  const pagosCuenta = (cuentaId: string) => pagos.filter((pago) => pago.cuenta_id === cuentaId);

  return (
    <div className="cxp-page">
      <div className="header-row cxp-header">
        <div><h2>Cuentas por pagar</h2><p className="conteo">Facturas de todas las compañías, desembolsos centralizados y cheques posfechados.</p></div>
        <div className="acciones">
          <button type="button" className="secondary" onClick={exportar}>Exportar</button>
          {puedeEditar && <button type="button" onClick={() => setConfigurando(true)}>Configurar pagadora</button>}
        </div>
      </div>

      {!configuracion && <div className="error-box"><strong>Configura la compañía pagadora principal.</strong> Mientras tanto, cada factura quedó asignada a la misma compañía que la recibió.</div>}
      <div className="info-box cxp-explicacion"><strong>Efectivo comprometido</strong><span>Incluye cheques, transferencias u otros pagos programados que todavía no se han hecho efectivos. Solo “Pagado / cobrado” reduce la deuda.</span></div>
      {error && <div className="error-box">{error}</div>}
      {mensaje && <div className="success-box">{mensaje}</div>}

      <div className="kpis cxp-kpis">
        <div className="kpi"><span className="label">Saldo por pagar</span><strong className="valor">{DINERO.format(kpis.saldo)}</strong></div>
        <div className="kpi alerta"><span className="label">Saldo vencido</span><strong className="valor">{DINERO.format(kpis.vencido)}</strong></div>
        <div className="kpi compromiso"><span className="label">Efectivo comprometido</span><strong className="valor">{DINERO.format(kpis.comprometido)}</strong></div>
        <div className="kpi"><span className="label">Aún por programar</span><strong className="valor">{DINERO.format(kpis.porProgramar)}</strong></div>
        <div className="kpi"><span className="label">Comprometido próximos 30 días</span><strong className="valor">{DINERO.format(Number(resumenVisible?.comprometido_30_dias ?? resumen.reduce((s, x) => s + Number(x.comprometido_30_dias), 0)))}</strong></div>
      </div>

      <div className="tabs">
        <button type="button" className={`tab ${tab === "cartera" ? "activo" : ""}`} onClick={() => setTab("cartera")}>Cartera ({cuentasFiltradas.length})</button>
        <button type="button" className={`tab ${tab === "calendario" ? "activo" : ""}`} onClick={() => setTab("calendario")}>Calendario de efectivo ({calendario.length})</button>
      </div>
      <div className="filtros cxp-filtros">
        <div className="field buscador"><label>Buscar</label><input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} placeholder="Proveedor, RUC, factura o compañía" /></div>
        <div className="field"><label>Estado</label><select value={estado} onChange={(e) => setEstado(e.target.value)}><option value="">Todos</option>{Object.entries(ESTADO_CUENTA).map(([valor, etiqueta]) => <option value={valor} key={valor}>{etiqueta}</option>)}</select></div>
        <div className="field"><label>Compañía pagadora</label><select value={pagadoraId} onChange={(e) => setPagadoraId(e.target.value)}><option value="">Todas</option>{empresas.map((empresa) => <option key={empresa.id} value={empresa.id}>{empresa.codigo} · {empresa.razon_social}</option>)}</select></div>
        {(busqueda || estado || pagadoraId) && <button type="button" className="chip-limpiar" onClick={() => { setBusqueda(""); setEstado(""); setPagadoraId(""); }}>Limpiar</button>}
      </div>

      {cargando ? <div className="vacio">Cargando cartera…</div> : tab === "cartera" ? (
        cuentasFiltradas.length === 0 ? <div className="vacio card">No hay cuentas por pagar para estos filtros.</div> :
        <div className="cxp-lista">{cuentasFiltradas.map((cuenta) => {
          const abierta = cuentaAbierta === cuenta.id;
          const detallePagos = pagosCuenta(cuenta.id);
          return <article className={`cxp-cuenta estado-${cuenta.estado}`} key={cuenta.id}>
            <button type="button" className="cxp-cuenta-resumen" onClick={() => setCuentaAbierta(abierta ? null : cuenta.id)}>
              <span><strong>{cuenta.proveedor}</strong><small>{cuenta.proveedor_identificacion} · {cuenta.numero_documento}</small></span>
              <span><small>Factura de</small><strong>{cuenta.empresa_deudora_codigo}</strong></span>
              <span><small>Paga</small><strong>{cuenta.empresa_pagadora_codigo}</strong></span>
              <span><small>Vence</small><strong>{fechaCorta(cuenta.fecha_vencimiento)}</strong></span>
              <span className="num"><small>Saldo</small><strong>{DINERO.format(Number(cuenta.saldo_pendiente))}</strong></span>
              <span className={`badge estado-${cuenta.estado}`}>{ESTADO_CUENTA[cuenta.estado]}</span>
              <b aria-hidden="true">{abierta ? "−" : "+"}</b>
            </button>
            {abierta && <div className="cxp-cuenta-detalle">
              <div className="cxp-montos">
                <span>Total factura<strong>{DINERO.format(Number(cuenta.total_documento))}</strong></span>
                <span>Retenciones<strong>{DINERO.format(Number(cuenta.total_retenciones))}</strong></span>
                <span>Neto exigible<strong>{DINERO.format(Number(cuenta.total_exigible))}</strong></span>
                <span>Ya pagado<strong>{DINERO.format(Number(cuenta.total_pagado))}</strong></span>
                <span>Comprometido<strong>{DINERO.format(Number(cuenta.total_comprometido))}</strong></span>
                <span>Sin programar<strong>{DINERO.format(Number(cuenta.saldo_por_programar))}</strong></span>
              </div>
              <div className="acciones-documento">
                {puedeEditar && cuenta.estado !== "anulada" && cuenta.estado !== "pagada" && <button type="button" className="secondary" onClick={() => abrirEdicion(cuenta)}>Condiciones</button>}
                {puedeEditar && cuenta.saldo_por_programar > 0 && <button type="button" onClick={() => abrirProgramacion(cuenta)}>Programar pago</button>}
              </div>
              {detallePagos.length === 0 ? <p className="conteo">Todavía no existen pagos ni cheques para esta factura.</p> : <div className="tabla-scroll cxp-pagos"><table><thead><tr><th>Medio</th><th>Salida prevista</th><th>Referencia</th><th>Estado</th><th className="num">Monto</th><th>Acciones</th></tr></thead><tbody>{detallePagos.map((pago) => <tr className={pago.estado === "anulado" ? "fila-anulada" : ""} key={pago.id}><td><strong>{MEDIO[pago.medio]}</strong>{pago.banco && <div className="conteo">{pago.banco}</div>}</td><td>{fechaCorta(pago.fecha_programada)}{pago.fecha_pago && <div className="conteo">Pagado {fechaCorta(pago.fecha_pago)}</div>}</td><td>{pago.numero_cheque ? `Cheque ${pago.numero_cheque}` : pago.nota}<div className="conteo">{pago.numero_cuenta ?? ""}</div></td><td><span className={`badge pago-${pago.estado}`}>{ESTADO_PAGO[pago.estado]}</span>{pago.motivo_anulacion && <div className="conteo">{pago.motivo_anulacion}</div>}</td><td className="num">{DINERO.format(Number(pago.monto))}</td><td><div className="acciones-tabla">{puedeEditar && pago.estado === "programado" && pago.medio === "cheque" && <button type="button" className="btn-mini secondary" onClick={() => gestionarPago(pago, "emitido")}>Emitir</button>}{puedeEditar && ["programado", "emitido"].includes(pago.estado) && pago.medio === "cheque" && <button type="button" className="btn-mini secondary" onClick={() => gestionarPago(pago, "entregado")}>Entregar</button>}{puedeEditar && ["programado", "emitido", "entregado"].includes(pago.estado) && <button type="button" className="btn-mini" onClick={() => gestionarPago(pago, "pagado")}>{pago.medio === "cheque" ? "Cobrado" : "Pagado"}</button>}{puedeEditar && pago.estado !== "anulado" && (pago.estado !== "pagado" || perfil.rol === "admin") && <button type="button" className="btn-mini peligro" onClick={() => gestionarPago(pago, "anulado")}>Anular</button>}</div></td></tr>)}</tbody></table></div>}
            </div>}
          </article>;
        })}</div>
      ) : calendario.length === 0 ? <div className="vacio card">No hay salidas de efectivo programadas.</div> : (
        <div className="cxp-calendario">{calendario.map(([dia, items]) => <section className={`cxp-dia ${dia < hoy ? "vencido" : ""}`} key={dia}><div className="cxp-dia-cabecera"><span><strong>{fechaCorta(dia)}</strong><small>{dia < hoy ? "Compromiso vencido" : dia === hoy ? "Sale hoy" : "Salida prevista"}</small></span><strong>{DINERO.format(items.reduce((s, item) => s + Number(item.monto), 0))}</strong></div><div>{items.map((item) => <article className="cxp-compromiso" key={item.pago_id}><span><strong>{item.proveedor}</strong><small>{item.numero_documento} · factura {item.empresa_deudora_codigo}</small></span><span><strong>{MEDIO[item.medio]}</strong><small>{item.numero_cheque ? `${item.banco} · cheque ${item.numero_cheque}` : item.nota}</small></span><span><strong>{item.empresa_pagadora_codigo}</strong><small>Compañía pagadora</small></span><strong className="num">{DINERO.format(Number(item.monto))}</strong></article>)}</div></section>)}</div>
      )}

      {configurando && <div className="modal-operativo"><form className="modal-contenido" onSubmit={guardarConfiguracion}><div className="header-row"><div><h3>Configuración de tesorería</h3><p className="conteo">Define la compañía que paga por defecto, aunque la factura pertenezca a otro RUC.</p></div><button type="button" className="secondary" onClick={() => { setConfigurando(false); setError(null); }}>Cerrar</button></div><div className="field"><label>Compañía pagadora principal</label><select required value={formConfig.empresaPagadoraId} onChange={(e) => setFormConfig({ ...formConfig, empresaPagadoraId: e.target.value })}><option value="">Selecciona…</option>{empresas.map((empresa) => <option key={empresa.id} value={empresa.id}>{empresa.codigo} · {empresa.razon_social}</option>)}</select></div><div className="field"><label>Días de crédito predeterminados</label><input required type="number" min="0" max="365" step="1" value={formConfig.diasCredito} onChange={(e) => setFormConfig({ ...formConfig, diasCredito: e.target.value })} /></div><label className="opcion-destacada compacta"><input type="checkbox" checked={formConfig.aplicarPendientes} onChange={(e) => setFormConfig({ ...formConfig, aplicarPendientes: e.target.checked })} /><span><strong>Aplicar a cuentas sin pagos</strong><small>Reasigna la pagadora y recalcula su vencimiento. Nunca modifica cuentas que ya tengan compromisos.</small></span></label><div className="field"><label>Motivo</label><textarea required minLength={10} rows={3} value={formConfig.motivo} onChange={(e) => setFormConfig({ ...formConfig, motivo: e.target.value })} /></div>{error && <div className="error-box">{error}</div>}<div className="acciones"><button type="submit" disabled={procesando}>{procesando ? "Guardando…" : "Guardar configuración"}</button><button type="button" className="secondary" onClick={() => { setConfigurando(false); setError(null); }}>Cancelar</button></div></form></div>}

      {editando && <div className="modal-operativo"><form className="modal-contenido" onSubmit={guardarCuenta}><div className="header-row"><div><h3>Condiciones de pago</h3><p className="conteo">{editando.proveedor} · {editando.numero_documento}</p></div><button type="button" className="secondary" onClick={() => { setEditando(null); setError(null); }}>Cerrar</button></div><div className="field"><label>Compañía pagadora</label><select required disabled={pagosCuenta(editando.id).some((pago) => pago.estado !== "anulado")} value={formCuenta.empresaPagadoraId} onChange={(e) => setFormCuenta({ ...formCuenta, empresaPagadoraId: e.target.value })}>{empresas.map((empresa) => <option key={empresa.id} value={empresa.id}>{empresa.codigo} · {empresa.razon_social}</option>)}</select></div><div className="field"><label>Fecha de vencimiento</label><input required type="date" min={editando.fecha_documento} value={formCuenta.fechaVencimiento} onChange={(e) => setFormCuenta({ ...formCuenta, fechaVencimiento: e.target.value })} /></div><div className="field"><label>Nota</label><textarea rows={3} value={formCuenta.nota} onChange={(e) => setFormCuenta({ ...formCuenta, nota: e.target.value })} /></div>{pagosCuenta(editando.id).some((pago) => pago.estado !== "anulado") && <div className="info-box">Puedes cambiar el vencimiento, pero la compañía pagadora queda bloqueada porque esta cuenta ya tiene historial de pagos o compromisos.</div>}{error && <div className="error-box">{error}</div>}<div className="acciones"><button type="submit" disabled={procesando}>{procesando ? "Guardando…" : "Guardar condiciones"}</button><button type="button" className="secondary" onClick={() => { setEditando(null); setError(null); }}>Cancelar</button></div></form></div>}

      {programando && <div className="modal-operativo"><form className="modal-contenido" onSubmit={guardarPago}><div className="header-row"><div><h3>Programar salida de efectivo</h3><p className="conteo">{programando.proveedor} · {programando.numero_documento} · paga {programando.empresa_pagadora_codigo}</p></div><button type="button" className="secondary" onClick={() => { setProgramando(null); setError(null); }}>Cerrar</button></div><div className="cxp-saldo-modal"><span>Disponible para programar</span><strong>{DINERO.format(Number(programando.saldo_por_programar))}</strong></div><div className="grid-2"><div className="field"><label>Medio</label><select value={formPago.medio} onChange={(e) => setFormPago({ ...formPago, medio: e.target.value as Pago["medio"] })}>{Object.entries(MEDIO).map(([valor, etiqueta]) => <option key={valor} value={valor}>{etiqueta}</option>)}</select></div><div className="field"><label>Monto</label><input required type="number" min="0.01" max={programando.saldo_por_programar} step="0.01" value={formPago.monto} onChange={(e) => setFormPago({ ...formPago, monto: e.target.value })} /></div><div className="field"><label>Fecha prevista de salida</label><input required type="date" value={formPago.fechaProgramada} onChange={(e) => setFormPago({ ...formPago, fechaProgramada: e.target.value })} /></div><div className="field"><label>Referencia</label><input required minLength={5} value={formPago.nota} onChange={(e) => setFormPago({ ...formPago, nota: e.target.value })} /></div></div>{formPago.medio === "cheque" && <div className="cxp-cheque"><strong>Datos del cheque posfechado</strong><div className="grid-2"><div className="field"><label>Banco</label><input required value={formPago.banco} onChange={(e) => setFormPago({ ...formPago, banco: e.target.value })} /></div><div className="field"><label>Número de cuenta</label><input required value={formPago.numeroCuenta} onChange={(e) => setFormPago({ ...formPago, numeroCuenta: e.target.value })} /></div><div className="field"><label>Número de cheque</label><input required value={formPago.numeroCheque} onChange={(e) => setFormPago({ ...formPago, numeroCheque: e.target.value })} /></div></div></div>}<label className="opcion-destacada compacta"><input type="checkbox" checked={formPago.yaPagado} onChange={(e) => setFormPago({ ...formPago, yaPagado: e.target.checked })} /><span><strong>Este pago ya se hizo efectivo</strong><small>Si no lo marcas, aparecerá como efectivo comprometido y no reducirá la deuda todavía.</small></span></label>{formPago.yaPagado && <div className="field"><label>Fecha efectiva</label><input required type="date" max={hoy} value={formPago.fechaPago} onChange={(e) => setFormPago({ ...formPago, fechaPago: e.target.value })} /></div>}{error && <div className="error-box">{error}</div>}<div className="acciones"><button type="submit" disabled={procesando}>{procesando ? "Guardando…" : formPago.yaPagado ? "Registrar pago" : "Comprometer efectivo"}</button><button type="button" className="secondary" onClick={() => { setProgramando(null); setError(null); }}>Cancelar</button></div></form></div>}
    </div>
  );
}
