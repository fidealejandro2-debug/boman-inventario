"use client";

import { useMemo, useState } from "react";
import * as XLSX from "xlsx";
import { createClient } from "@/lib/supabase/client";
import { mensajeError, type Empleado, type Empresa } from "./lib";

type TipoCarga = "atraso" | "ausencia" | "descuento" | "anticipo";
type EstadoFila = "pendiente" | "guardada" | "error";

type Documento = {
  id: string;
  empleado_id: string;
  nombre: string;
};

type FilaCarga = {
  fila: number;
  tipo: TipoCarga;
  empleadoId: string;
  empleadoNombre: string;
  identificacion: string;
  fecha: string | null;
  fechaHasta: string | null;
  tipoAusencia: string | null;
  horas: number | null;
  minutos: number | null;
  valor: number | null;
  cuotas: number | null;
  mesAplicacion: string | null;
  empresaId: string | null;
  empresaNombre: string | null;
  origenDescuento: string | null;
  descripcion: string;
  documentoId: string | null;
  documentoNombre: string | null;
  baseReglamento: string | null;
  errores: string[];
  estado: EstadoFila;
  resultado?: string;
};

const TIPOS = new Set<TipoCarga>(["atraso", "ausencia", "descuento", "anticipo"]);
const TIPOS_AUSENCIA = new Set([
  "vacaciones",
  "enfermedad_iess",
  "enfermedad_particular",
  "permiso_con_sueldo",
  "permiso_sin_sueldo",
  "maternidad",
  "paternidad",
  "lactancia",
  "calamidad_domestica",
  "falta_injustificada",
  "suspension_disciplinaria",
]);
const AUSENCIAS_CON_DOCUMENTO = new Set([
  "enfermedad_iess",
  "enfermedad_particular",
  "maternidad",
  "paternidad",
  "calamidad_domestica",
  "suspension_disciplinaria",
]);
const ORIGENES_DESCUENTO = new Set([
  "prestamo_empresa",
  "prestamo_iess",
  "prestamo_quirografario",
  "prestamo_hipotecario",
  "judicial",
  "uniforme",
  "consumo_interno",
  "otro",
]);

const ALIASES = {
  tipo: ["tipo", "movimiento"],
  identificacion: ["identificacion", "cedula", "documento_empleado"],
  fecha: ["fecha", "fecha_movimiento", "fecha_desde"],
  fechaHasta: ["fecha_hasta", "hasta"],
  tipoAusencia: ["tipo_ausencia", "ausencia"],
  horas: ["horas"],
  minutos: ["minutos", "minutos_atraso"],
  valor: ["valor", "monto"],
  cuotas: ["cuotas"],
  mesAplicacion: ["mes_aplicacion", "mes_rol", "primera_cuota"],
  empresaRuc: ["empresa_ruc", "ruc"],
  origenDescuento: ["origen_descuento", "origen"],
  descripcion: ["descripcion", "motivo", "observacion"],
  documento: ["documento", "documento_respaldo"],
  baseReglamento: ["base_reglamento", "articulo_reglamento"],
} as const;

const normalizar = (valor: unknown) =>
  String(valor ?? "")
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");

const identificacionNormalizada = (valor: unknown) =>
  String(valor ?? "").trim().replace(/\.0+$/, "").replace(/[^0-9a-zA-Z]/g, "").toUpperCase();

const rucNormalizado = (valor: unknown) => String(valor ?? "").replace(/\D/g, "");

function numeroOpcional(valor: unknown): number | null | "invalido" {
  if (valor === null || valor === undefined || String(valor).trim() === "") return null;
  if (typeof valor === "number") return Number.isFinite(valor) ? valor : "invalido";
  let texto = String(valor).trim().replace(/[$\s]/g, "");
  if (texto.includes(",") && texto.includes(".")) {
    texto = texto.lastIndexOf(",") > texto.lastIndexOf(".")
      ? texto.replace(/\./g, "").replace(",", ".")
      : texto.replace(/,/g, "");
  } else if (texto.includes(",")) texto = texto.replace(",", ".");
  const numero = Number(texto);
  return Number.isFinite(numero) ? numero : "invalido";
}

function fechaISO(valor: unknown, soloMes = false): string | null {
  if (valor === null || valor === undefined || String(valor).trim() === "") return null;
  if (valor instanceof Date && !Number.isNaN(valor.getTime())) {
    const y = valor.getFullYear();
    const m = String(valor.getMonth() + 1).padStart(2, "0");
    const d = soloMes ? "01" : String(valor.getDate()).padStart(2, "0");
    return `${y}-${m}-${d}`;
  }
  if (typeof valor === "number") {
    const partes = XLSX.SSF.parse_date_code(valor);
    if (!partes) return null;
    return `${partes.y}-${String(partes.m).padStart(2, "0")}-${soloMes ? "01" : String(partes.d).padStart(2, "0")}`;
  }
  const texto = String(valor).trim();
  let y: number;
  let m: number;
  let d: number;
  let coincidencia = texto.match(/^(\d{4})[-/]([01]?\d)(?:[-/]([0-3]?\d))?$/);
  if (coincidencia) {
    y = Number(coincidencia[1]);
    m = Number(coincidencia[2]);
    d = soloMes ? 1 : Number(coincidencia[3] || 1);
  } else {
    coincidencia = texto.match(/^([0-3]?\d)[/-]([01]?\d)[/-](\d{4})$/);
    if (!coincidencia) return null;
    d = soloMes ? 1 : Number(coincidencia[1]);
    m = Number(coincidencia[2]);
    y = Number(coincidencia[3]);
  }
  const prueba = new Date(y, m - 1, d);
  if (prueba.getFullYear() !== y || prueba.getMonth() !== m - 1 || prueba.getDate() !== d)
    return null;
  return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

function uuidDeterminista(hash: string, fila: number, accion: number) {
  const cola = (fila * 16 + accion).toString(16).padStart(8, "0").slice(-8);
  let hex = (hash.slice(0, 24) + cola).padEnd(32, "0").slice(0, 32);
  hex = `${hex.slice(0, 12)}4${hex.slice(13)}`;
  const variante = ((parseInt(hex[16], 16) & 3) | 8).toString(16);
  hex = `${hex.slice(0, 16)}${variante}${hex.slice(17)}`;
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function etiquetaTipo(tipo: TipoCarga) {
  return tipo === "atraso"
    ? "Atraso"
    : tipo === "ausencia"
      ? "Ausencia"
      : tipo === "descuento"
        ? "Descuento"
        : "Anticipo";
}

export default function ImportacionNominaTab({
  puedeEscribir,
  empleados,
  empresas,
}: {
  puedeEscribir: boolean;
  empleados: Empleado[];
  empresas: Empresa[];
}) {
  const supabase = createClient();
  const [filas, setFilas] = useState<FilaCarga[]>([]);
  const [archivo, setArchivo] = useState("");
  const [archivoHash, setArchivoHash] = useState("");
  const [leyendo, setLeyendo] = useState(false);
  const [procesando, setProcesando] = useState(false);
  const [progreso, setProgreso] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);

  const resumen = useMemo(() => {
    const resultado = { atraso: 0, ausencia: 0, descuento: 0, anticipo: 0, errores: 0 };
    filas.forEach((fila) => {
      resultado[fila.tipo]++;
      if (fila.errores.length) resultado.errores++;
    });
    return resultado;
  }, [filas]);

  function descargarPlantilla() {
    const ejemplos = [
      {
        TIPO: "atraso",
        IDENTIFICACION: "0100000001",
        FECHA: "2026-09-01",
        FECHA_HASTA: "",
        TIPO_AUSENCIA: "",
        HORAS: "",
        MINUTOS: 20,
        VALOR: "",
        CUOTAS: "",
        MES_APLICACION: "",
        EMPRESA_RUC: "",
        ORIGEN_DESCUENTO: "",
        DESCRIPCION: "Llegada 20 minutos tarde",
        DOCUMENTO: "",
        BASE_REGLAMENTO: "",
      },
      {
        TIPO: "ausencia",
        IDENTIFICACION: "0100000002",
        FECHA: "2026-09-02",
        FECHA_HASTA: "2026-09-02",
        TIPO_AUSENCIA: "permiso_con_sueldo",
        HORAS: 2,
        MINUTOS: "",
        VALOR: "",
        CUOTAS: "",
        MES_APLICACION: "",
        EMPRESA_RUC: "",
        ORIGEN_DESCUENTO: "",
        DESCRIPCION: "Cita personal autorizada",
        DOCUMENTO: "",
        BASE_REGLAMENTO: "",
      },
      {
        TIPO: "descuento",
        IDENTIFICACION: "0100000003",
        FECHA: "2026-09-03",
        FECHA_HASTA: "",
        TIPO_AUSENCIA: "",
        HORAS: "",
        MINUTOS: "",
        VALOR: 50,
        CUOTAS: 2,
        MES_APLICACION: "2026-09",
        EMPRESA_RUC: "",
        ORIGEN_DESCUENTO: "uniforme",
        DESCRIPCION: "Uniforme autorizado",
        DOCUMENTO: "Autorizacion uniforme septiembre",
        BASE_REGLAMENTO: "",
      },
      {
        TIPO: "anticipo",
        IDENTIFICACION: "0100000004",
        FECHA: "2026-09-04",
        FECHA_HASTA: "",
        TIPO_AUSENCIA: "",
        HORAS: "",
        MINUTOS: "",
        VALOR: 100,
        CUOTAS: 2,
        MES_APLICACION: "2026-09",
        EMPRESA_RUC: "",
        ORIGEN_DESCUENTO: "",
        DESCRIPCION: "Anticipo solicitado por la persona",
        DOCUMENTO: "Solicitud anticipo septiembre",
        BASE_REGLAMENTO: "",
      },
    ];
    const instrucciones = [
      { CAMPO: "TIPO", REGLA: "atraso, ausencia, descuento o anticipo." },
      { CAMPO: "IDENTIFICACION", REGLA: "Cédula/identificación existente. Formatea esta columna como texto." },
      { CAMPO: "ATRASO", REGLA: "MINUTOS es obligatorio. VALOR vacío = solo registro; con valor = sanción económica en borrador." },
      { CAMPO: "AUSENCIA", REGLA: "Usa TIPO_AUSENCIA. HORAS es opcional; si se llena, debe ser un solo día." },
      { CAMPO: "DESCUENTO", REGLA: "Requiere VALOR, CUOTAS, MES_APLICACION, ORIGEN_DESCUENTO y DOCUMENTO del expediente." },
      { CAMPO: "ANTICIPO", REGLA: "Requiere FECHA, VALOR, CUOTAS, MES_APLICACION y DOCUMENTO del expediente." },
      { CAMPO: "DOCUMENTO", REGLA: "Escribe el nombre exacto del documento activo en el expediente, o su UUID." },
      { CAMPO: "EMPRESA_RUC", REGLA: "Opcional; si queda vacío se usa la empresa pagadora vigente de la persona." },
      { CAMPO: "BASE_REGLAMENTO", REGLA: "Obligatoria cuando un atraso lleva VALOR. La sanción queda pendiente de revisión." },
    ];
    const libro = XLSX.utils.book_new();
    const hoja = XLSX.utils.json_to_sheet(ejemplos);
    hoja["!cols"] = Object.keys(ejemplos[0]).map((campo) => ({ wch: Math.max(13, campo.length + 2) }));
    XLSX.utils.book_append_sheet(libro, hoja, "CARGA");
    XLSX.utils.book_append_sheet(libro, XLSX.utils.json_to_sheet(instrucciones), "INSTRUCCIONES");
    XLSX.writeFile(libro, "plantilla_carga_masiva_nomina.xlsx");
  }

  async function leerArchivo(file: File) {
    setLeyendo(true);
    setError(null);
    setAviso(null);
    setFilas([]);
    try {
      const buffer = await file.arrayBuffer();
      if (!crypto?.subtle) throw new Error("El navegador no permite calcular la huella segura del archivo.");
      const digest = await crypto.subtle.digest("SHA-256", buffer.slice(0));
      const hash = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
      const libro = XLSX.read(buffer, { type: "array", cellDates: true });
      const hoja = libro.Sheets[libro.SheetNames[0]];
      const crudas = XLSX.utils.sheet_to_json<Record<string, unknown>>(hoja, { defval: "", raw: true });
      if (!crudas.length) throw new Error("La primera hoja está vacía.");
      if (crudas.length > 1000) throw new Error("El archivo supera el máximo de 1.000 filas.");

      const columnas = new Map(Object.keys(crudas[0]).map((columna) => [normalizar(columna), columna]));
      const columna = (aliases: readonly string[]) => aliases.map((a) => columnas.get(a)).find(Boolean);
      const cols = Object.fromEntries(
        Object.entries(ALIASES).map(([campo, aliases]) => [campo, columna(aliases)])
      ) as Record<keyof typeof ALIASES, string | undefined>;
      if (!cols.tipo || !cols.identificacion) {
        throw new Error("Faltan las columnas obligatorias TIPO e IDENTIFICACION.");
      }

      const { data: docs, error: errorDocs } = await supabase
        .from("empleado_documentos")
        .select("id, empleado_id, nombre")
        .eq("activo", true)
        .limit(10000);
      if (errorDocs) throw new Error(`No se pudieron consultar los documentos: ${errorDocs.message}`);
      const documentos = (docs as Documento[]) ?? [];

      const empleadosExactos = new Map(
        empleados.map((empleado) => [identificacionNormalizada(empleado.identificacion), empleado])
      );
      const empleadosSinCeros = new Map<string, Empleado[]>();
      empleados.forEach((empleado) => {
        const clave = identificacionNormalizada(empleado.identificacion).replace(/^0+/, "");
        empleadosSinCeros.set(clave, [...(empleadosSinCeros.get(clave) ?? []), empleado]);
      });
      const empresasExactas = new Map(empresas.map((empresa) => [rucNormalizado(empresa.ruc), empresa]));
      const empresasSinCeros = new Map(empresas.map((empresa) => [rucNormalizado(empresa.ruc).replace(/^0+/, ""), empresa]));
      const docsPorEmpleado = new Map<string, Documento[]>();
      documentos.forEach((doc) =>
        docsPorEmpleado.set(doc.empleado_id, [...(docsPorEmpleado.get(doc.empleado_id) ?? []), doc])
      );
      const valor = (fila: Record<string, unknown>, col: string | undefined) => (col ? fila[col] : "");

      const preparadas = crudas.map((cruda, indice): FilaCarga => {
        const numeroFila = indice + 2;
        const errores: string[] = [];
        const tipoTexto = normalizar(valor(cruda, cols.tipo));
        const tipo = (TIPOS.has(tipoTexto as TipoCarga) ? tipoTexto : "atraso") as TipoCarga;
        if (!TIPOS.has(tipoTexto as TipoCarga)) errores.push("TIPO debe ser atraso, ausencia, descuento o anticipo");

        const identificacion = identificacionNormalizada(valor(cruda, cols.identificacion));
        let empleado = empleadosExactos.get(identificacion);
        if (!empleado) {
          const candidatos = empleadosSinCeros.get(identificacion.replace(/^0+/, "")) ?? [];
          if (candidatos.length === 1) empleado = candidatos[0];
        }
        if (!identificacion) errores.push("falta IDENTIFICACION");
        else if (!empleado) errores.push("la identificación no corresponde a una persona vigente");

        const fechaCruda = valor(cruda, cols.fecha);
        const fecha = fechaISO(fechaCruda);
        const fechaHastaCruda = valor(cruda, cols.fechaHasta);
        const fechaHasta = fechaISO(fechaHastaCruda) ?? fecha;
        const horas = numeroOpcional(valor(cruda, cols.horas));
        const minutos = numeroOpcional(valor(cruda, cols.minutos));
        const monto = numeroOpcional(valor(cruda, cols.valor));
        const cuotas = numeroOpcional(valor(cruda, cols.cuotas));
        const mesAplicacionCrudo = valor(cruda, cols.mesAplicacion);
        const mesAplicacion = fechaISO(mesAplicacionCrudo, true);
        const tipoAusencia = normalizar(valor(cruda, cols.tipoAusencia)) || null;
        const origenDescuento = normalizar(valor(cruda, cols.origenDescuento)) || null;
        const descripcion = String(valor(cruda, cols.descripcion) ?? "").trim();
        const baseReglamento = String(valor(cruda, cols.baseReglamento) ?? "").trim() || null;

        const rucIngresado = rucNormalizado(valor(cruda, cols.empresaRuc));
        let empresa: Empresa | undefined;
        if (rucIngresado) {
          empresa = empresasExactas.get(rucIngresado) ?? empresasSinCeros.get(rucIngresado.replace(/^0+/, ""));
          if (!empresa) errores.push("EMPRESA_RUC no existe o no está activa");
        } else if (empleado) {
          const empresaSugerida = tipo === "atraso"
            ? empleado.empresa_afiliacion_id ?? empleado.empresa_pagadora_id
            : empleado.empresa_pagadora_id;
          empresa = empresas.find((item) => item.id === empresaSugerida);
        }

        const documentoIngresado = String(valor(cruda, cols.documento) ?? "").trim();
        let documento: Documento | undefined;
        if (documentoIngresado && empleado) {
          const disponibles = docsPorEmpleado.get(empleado.empleado_id) ?? [];
          const porId = disponibles.filter((doc) => doc.id.toLowerCase() === documentoIngresado.toLowerCase());
          const porNombre = disponibles.filter((doc) => normalizar(doc.nombre) === normalizar(documentoIngresado));
          const coincidencias = porId.length ? porId : porNombre;
          if (coincidencias.length === 1) documento = coincidencias[0];
          else if (!coincidencias.length) errores.push("DOCUMENTO no existe o no está activo en el expediente de la persona");
          else errores.push("DOCUMENTO coincide con varios archivos; usa su UUID");
        }

        if (horas === "invalido") errores.push("HORAS no es un número válido");
        if (minutos === "invalido") errores.push("MINUTOS no es un número válido");
        if (monto === "invalido") errores.push("VALOR no es un número válido");
        if (cuotas === "invalido") errores.push("CUOTAS no es un número válido");
        if (String(fechaCruda ?? "").trim() && !fecha) errores.push("FECHA no es válida");
        if (String(fechaHastaCruda ?? "").trim() && !fechaISO(fechaHastaCruda))
          errores.push("FECHA_HASTA no es válida");
        if (String(mesAplicacionCrudo ?? "").trim() && !mesAplicacion)
          errores.push("MES_APLICACION no es válido");
        const horasNumero = horas === "invalido" ? null : horas;
        const minutosNumero = minutos === "invalido" ? null : minutos;
        const montoNumero = monto === "invalido" ? null : monto;
        const cuotasNumero = cuotas === "invalido" ? null : cuotas;

        if (tipo === "atraso") {
          if (!fecha) errores.push("el atraso requiere FECHA válida");
          if (!Number.isInteger(minutosNumero) || (minutosNumero ?? 0) < 1 || (minutosNumero ?? 0) > 1440)
            errores.push("MINUTOS debe ser un entero entre 1 y 1440");
          if (montoNumero !== null && montoNumero <= 0) errores.push("VALOR debe quedar vacío o ser mayor a cero");
          if (montoNumero !== null && !baseReglamento) errores.push("un atraso con VALOR requiere BASE_REGLAMENTO");
          if (!empresa) errores.push("el atraso requiere EMPRESA_RUC o empresa pagadora vigente");
        }
        if (tipo === "ausencia") {
          if (!fecha || !fechaHasta) errores.push("la ausencia requiere FECHA y FECHA_HASTA válidas");
          else if (fechaHasta < fecha) errores.push("FECHA_HASTA no puede ser anterior a FECHA");
          if (!tipoAusencia || !TIPOS_AUSENCIA.has(tipoAusencia)) errores.push("TIPO_AUSENCIA no es válido");
          if (horasNumero !== null && (horasNumero <= 0 || horasNumero > 24 || fecha !== fechaHasta))
            errores.push("HORAS debe ser mayor a cero, máximo 24 y corresponder a un solo día");
          if (tipoAusencia === "vacaciones" && horasNumero !== null) errores.push("vacaciones no admite HORAS");
          if (tipoAusencia && AUSENCIAS_CON_DOCUMENTO.has(tipoAusencia) && !documento)
            errores.push("este TIPO_AUSENCIA requiere DOCUMENTO");
        }
        if (tipo === "descuento") {
          if (!origenDescuento || !ORIGENES_DESCUENTO.has(origenDescuento)) errores.push("ORIGEN_DESCUENTO no es válido");
          if (montoNumero === null || montoNumero <= 0) errores.push("el descuento requiere VALOR mayor a cero");
          if (!Number.isInteger(cuotasNumero) || (cuotasNumero ?? 0) < 1 || (cuotasNumero ?? 0) > 120)
            errores.push("CUOTAS debe ser un entero entre 1 y 120");
          if (!mesAplicacion) errores.push("el descuento requiere MES_APLICACION válido");
          if (!descripcion) errores.push("el descuento requiere DESCRIPCION");
          if (!documento) errores.push("el descuento requiere DOCUMENTO del expediente");
          if (!empresa) errores.push("el descuento requiere EMPRESA_RUC o empresa pagadora vigente");
        }
        if (tipo === "anticipo") {
          if (!fecha) errores.push("el anticipo requiere FECHA válida");
          if (montoNumero === null || montoNumero <= 0) errores.push("el anticipo requiere VALOR mayor a cero");
          if (!Number.isInteger(cuotasNumero) || (cuotasNumero ?? 0) < 1 || (cuotasNumero ?? 0) > 120)
            errores.push("CUOTAS debe ser un entero entre 1 y 120");
          if (!mesAplicacion) errores.push("el anticipo requiere MES_APLICACION válido");
          else if (fecha && mesAplicacion < `${fecha.slice(0, 7)}-01`) errores.push("MES_APLICACION no puede ser anterior a FECHA");
          if (!descripcion) errores.push("el anticipo requiere DESCRIPCION/motivo");
          if (!empresa) errores.push("el anticipo requiere EMPRESA_RUC o empresa pagadora vigente");
          if (!documento) errores.push("el anticipo requiere DOCUMENTO del expediente");
        }

        return {
          fila: numeroFila,
          tipo,
          empleadoId: empleado?.empleado_id ?? "",
          empleadoNombre: empleado?.nombre_completo ?? "Sin identificar",
          identificacion,
          fecha,
          fechaHasta,
          tipoAusencia,
          horas: horasNumero,
          minutos: minutosNumero,
          valor: montoNumero === null ? null : Math.round(montoNumero * 100) / 100,
          cuotas: cuotasNumero,
          mesAplicacion,
          empresaId: empresa?.id ?? null,
          empresaNombre: empresa?.razon_social ?? null,
          origenDescuento,
          descripcion,
          documentoId: documento?.id ?? null,
          documentoNombre: documento?.nombre ?? null,
          baseReglamento,
          errores,
          estado: "pendiente",
        };
      });

      const vistas = new Map<string, number>();
      preparadas.forEach((fila) => {
        if (fila.errores.length || !fila.empleadoId) return;
        const clave = [
          fila.tipo,
          fila.empleadoId,
          fila.fecha,
          fila.fechaHasta,
          fila.tipoAusencia,
          fila.minutos,
          fila.horas,
          fila.valor,
          fila.origenDescuento,
          fila.mesAplicacion,
          fila.documentoId,
        ].join("|");
        if (vistas.has(clave)) fila.errores.push(`duplicada con la fila ${vistas.get(clave)}`);
        else vistas.set(clave, fila.fila);
      });

      setArchivo(file.name);
      setArchivoHash(hash);
      setFilas(preparadas);
      if (!preparadas.length) throw new Error("No encontré filas para procesar.");
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudo leer el archivo.");
      setFilas([]);
    } finally {
      setLeyendo(false);
    }
  }

  async function guardarFila(fila: FilaCarga): Promise<string> {
    if (fila.tipo === "atraso") {
      const conValor = fila.valor !== null;
      const { error: rpcError } = await supabase.rpc("guardar_novedad_v28", {
        p_novedad_id: null,
        p_empleado_id: fila.empleadoId,
        p_empresa_id: fila.empresaId,
        p_tipo: conValor ? "sancion_economica" : "llamado_atencion",
        p_fecha_hechos: fila.fecha,
        p_asunto: `Atraso de ${fila.minutos} minutos`,
        p_hechos: fila.descripcion || `La persona registró un atraso de ${fila.minutos} minutos.`,
        p_base_reglamento: fila.baseReglamento,
        p_base_legal: "Código del Trabajo y reglamento interno aplicable",
        p_genera_descuento: conValor,
        p_monto_descuento: fila.valor,
        p_idempotency_key: uuidDeterminista(archivoHash, fila.fila, 1),
      });
      if (rpcError) throw new Error(mensajeError(rpcError));
      return conValor
        ? "Sanción económica creada en borrador; falta revisión, emisión y notificación"
        : "Atraso registrado como novedad en borrador, sin valor monetario";
    }
    if (fila.tipo === "ausencia") {
      const { error: rpcError } = await supabase.rpc("solicitar_ausencia_v27", {
        p_empleado_id: fila.empleadoId,
        p_tipo: fila.tipoAusencia,
        p_fecha_desde: fila.fecha,
        p_fecha_hasta: fila.fechaHasta,
        p_horas: fila.horas,
        p_almacen_id: null,
        p_documento_respaldo_id: fila.documentoId,
        p_observacion: fila.descripcion || null,
        p_idempotency_key: uuidDeterminista(archivoHash, fila.fila, 2),
      });
      if (rpcError) throw new Error(mensajeError(rpcError));
      return "Ausencia solicitada; falta aprobación";
    }
    if (fila.tipo === "descuento") {
      const detalleFecha = fila.fecha ? `${fila.descripcion} (fecha de origen: ${fila.fecha})` : fila.descripcion;
      const { error: rpcError } = await supabase.rpc("registrar_descuento_programado_v29", {
        p_empleado_id: fila.empleadoId,
        p_empresa_acreedora_id: fila.empresaId,
        p_origen: fila.origenDescuento,
        p_origen_id: null,
        p_descripcion: detalleFecha,
        p_monto_total: fila.valor,
        p_cuotas: fila.cuotas,
        p_fecha_inicio: fila.mesAplicacion,
        p_documento_respaldo_id: fila.documentoId,
        p_prioridad: null,
        p_idempotency_key: uuidDeterminista(archivoHash, fila.fila, 3),
      });
      if (rpcError) throw new Error(mensajeError(rpcError));
      return "Descuento programado para el rol indicado";
    }
    const { error: rpcError } = await supabase.rpc("solicitar_anticipo_v29", {
      p_empleado_id: fila.empleadoId,
      p_empresa_pagadora_id: fila.empresaId,
      p_fecha: fila.fecha,
      p_monto: fila.valor,
      p_motivo: fila.descripcion,
      p_cuotas: fila.cuotas,
      p_fecha_primera_cuota: fila.mesAplicacion,
      p_documento_respaldo_id: fila.documentoId,
      p_idempotency_key: uuidDeterminista(archivoHash, fila.fila, 4),
    });
    if (rpcError) throw new Error(mensajeError(rpcError));
    return "Anticipo solicitado; falta aprobación y desembolso";
  }

  async function importar() {
    if (!puedeEscribir || procesando || !filas.length || resumen.errores) return;
    if (!window.confirm(
      `Se procesarán ${filas.length} filas.\n\n` +
        "Los atrasos con valor quedarán como sanciones en borrador; no se descontarán automáticamente. ¿Continuar?"
    )) return;
    setProcesando(true);
    setError(null);
    setAviso(null);
    setProgreso(0);
    const resultados = new Map<number, { estado: EstadoFila; resultado: string }>();
    let siguiente = 0;
    let terminadas = 0;

    async function trabajador() {
      while (true) {
        const indice = siguiente++;
        if (indice >= filas.length) return;
        const fila = filas[indice];
        try {
          const resultado = await guardarFila(fila);
          resultados.set(fila.fila, { estado: "guardada", resultado });
        } catch (e) {
          resultados.set(fila.fila, {
            estado: "error",
            resultado: e instanceof Error ? e.message : "No se pudo guardar la fila",
          });
        }
        terminadas++;
        setProgreso(terminadas);
      }
    }

    await Promise.all(Array.from({ length: Math.min(4, filas.length) }, () => trabajador()));
    const actualizadas = filas.map((fila) => {
      const resultado = resultados.get(fila.fila);
      return resultado ? { ...fila, ...resultado } : fila;
    });
    setFilas(actualizadas);
    setProcesando(false);
    const correctas = actualizadas.filter((fila) => fila.estado === "guardada").length;
    const fallidas = actualizadas.filter((fila) => fila.estado === "error").length;
    setAviso(`Carga terminada: ${correctas} guardadas y ${fallidas} con error.`);
  }

  return (
    <>
      <h3>Carga masiva de novedades de nómina</h3>
      <p className="ayuda">
        Importa atrasos, ausencias, descuentos y anticipos desde una sola plantilla. Primero
        se valida todo el archivo y luego se muestra una vista previa antes de guardar.
      </p>
      <div className="info-box">
        <strong>Atrasos:</strong> si VALOR queda vacío, se guarda únicamente la novedad. Si
        escribes un valor, se crea una sanción económica <strong>en borrador</strong>; deberá
        revisarse, emitirse y notificarse en Novedades antes de poder llegar al rol. Así no se
        mezcla con el descuento automático por horas de una ausencia ni se cobra dos veces.
      </div>

      {error && <p className="error">{error}</p>}
      {aviso && <p className="aviso">{aviso}</p>}

      <div className="filtros">
        <input
          type="file"
          accept=".xlsx,.xls,.csv"
          disabled={!puedeEscribir || leyendo || procesando}
          onChange={(e) => {
            const file = e.target.files?.[0];
            if (file) void leerArchivo(file);
          }}
        />
        <button type="button" className="secondary" onClick={descargarPlantilla}>
          Descargar plantilla Excel
        </button>
      </div>

      {!puedeEscribir && <p className="ayuda">Tu perfil es de consulta y no puede importar.</p>}
      {leyendo && <p className="ayuda">Leyendo y validando el archivo…</p>}

      {filas.length > 0 && (
        <>
          <p className="ayuda">
            Archivo: <strong>{archivo}</strong>. La misma copia puede reintentarse sin crear
            duplicados gracias a su huella de idempotencia.
          </p>
          <div className="kpis compactos">
            <div className="kpi"><span className="valor">{filas.length}</span><span className="label">Filas</span></div>
            <div className="kpi"><span className="valor">{resumen.atraso}</span><span className="label">Atrasos</span></div>
            <div className="kpi"><span className="valor">{resumen.ausencia}</span><span className="label">Ausencias</span></div>
            <div className="kpi"><span className="valor">{resumen.descuento}</span><span className="label">Descuentos</span></div>
            <div className="kpi"><span className="valor">{resumen.anticipo}</span><span className="label">Anticipos</span></div>
            <div className={`kpi ${resumen.errores ? "alerta" : "ok"}`}><span className="valor">{resumen.errores}</span><span className="label">Con error</span></div>
          </div>

          <div className="tabla-scroll" style={{ maxHeight: 480 }}>
            <table>
              <thead>
                <tr>
                  <th>Fila</th><th>Estado</th><th>Tipo</th><th>Persona</th><th>Fecha / rol</th>
                  <th>Detalle</th><th className="num">Valor</th><th>Respaldo / resultado</th>
                </tr>
              </thead>
              <tbody>
                {filas.slice(0, 200).map((fila) => (
                  <tr key={fila.fila}>
                    <td>{fila.fila}</td>
                    <td>
                      <span className={`badge ${fila.errores.length || fila.estado === "error" ? "bajo" : fila.estado === "guardada" ? "ok" : "cero"}`}>
                        {fila.errores.length ? "Corregir" : fila.estado === "guardada" ? "Guardada" : fila.estado === "error" ? "Error" : "Lista"}
                      </span>
                    </td>
                    <td>{etiquetaTipo(fila.tipo)}</td>
                    <td><strong>{fila.empleadoNombre}</strong><div className="conteo">{fila.identificacion}</div></td>
                    <td>{fila.fecha ?? "—"}{fila.fechaHasta && fila.fechaHasta !== fila.fecha ? ` a ${fila.fechaHasta}` : ""}<div className="conteo">{fila.mesAplicacion ? `Rol: ${fila.mesAplicacion.slice(0, 7)}` : ""}</div></td>
                    <td>
                      {fila.tipo === "atraso" ? `${fila.minutos ?? "—"} minutos` : fila.tipoAusencia || fila.origenDescuento || fila.descripcion}
                      {fila.descripcion && fila.tipo !== "descuento" && <div className="conteo">{fila.descripcion}</div>}
                    </td>
                    <td className="num">{fila.valor === null ? "—" : `$${fila.valor.toFixed(2)}`}</td>
                    <td>
                      {fila.errores.length ? <span className="error">{fila.errores.join("; ")}</span> : fila.resultado ?? fila.documentoNombre ?? "—"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {filas.length > 200 && <p className="ayuda">Vista previa de 200 filas; se procesarán las {filas.length}.</p>}

          <button
            type="button"
            onClick={() => void importar()}
            disabled={!puedeEscribir || procesando || resumen.errores > 0}
            style={{ marginTop: 12 }}
          >
            {procesando ? `Procesando ${progreso}/${filas.length}…` : `Importar ${filas.length} filas`}
          </button>
          {resumen.errores > 0 && <p className="ayuda">Corrige las filas marcadas y vuelve a seleccionar el archivo.</p>}
        </>
      )}
    </>
  );
}
