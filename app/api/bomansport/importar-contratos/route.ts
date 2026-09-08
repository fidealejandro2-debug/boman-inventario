import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { mapearContrato, type ContratoCrudo, type ContratoTipado } from "@/lib/bomansportContratos";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

type Origen = "cron" | "manual";

function textoError(error: unknown) {
  return error instanceof Error ? error.message : "Ocurrió un error inesperado.";
}

/** true si el header Authorization trae exactamente el CRON_SECRET configurado. */
function tieneSecretoValido(request: NextRequest) {
  const secreto = process.env.CRON_SECRET;
  if (!secreto) return false;
  return request.headers.get("authorization") === `Bearer ${secreto}`;
}

/** Sesión de admin activo, para el botón manual sin el bearer a mano. */
async function adminDeSesion() {
  const supabase = createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return null;
  const { data: perfil } = await supabase
    .from("perfiles")
    .select("id, activo, rol")
    .eq("id", auth.user.id)
    .single();
  if (!perfil?.activo || perfil.rol !== "admin") return null;
  return perfil.id as string;
}

async function sincronizar(origen: Origen, ejecutadoPor: string | null) {
  const admin = createAdminClient();

  // v103 convierte este importador en una contingencia controlada. Antes de
  // instalarla la tabla no existe y se conserva el comportamiento anterior;
  // una vez que Supabase es la fuente principal, ni el cron ni un clic manual
  // pueden volver a sobrescribir datos desde el legado por accidente.
  const { data: cierre, error: errorCierre } = await admin
    .from("bomansport_cierre_migracion_v103")
    .select("modo")
    .eq("id", true)
    .maybeSingle();
  if (!errorCierre && cierre?.modo && cierre.modo !== "paralelo") {
    const mensaje = `La importación heredada está deshabilitada: el modo actual es ${String(cierre.modo).replace("_", " ")}.`;
    return origen === "cron"
      ? { status: 200 as const, body: { ok: true, omitida: true, modo: cierre.modo, mensaje } }
      : { status: 409 as const, body: { ok: false, omitida: true, modo: cierre.modo, error: mensaje } };
  }

  const { data: enCurso } = await admin
    .from("bomansport_importaciones")
    .select("id")
    .eq("estado", "en_curso")
    .gt("iniciado_en", new Date(Date.now() - 10 * 60 * 1000).toISOString())
    .limit(1)
    .maybeSingle();
  if (enCurso) {
    return { status: 409 as const, body: { ok: false, error: "Ya hay una sincronización en curso. Intenta de nuevo en unos minutos." } };
  }

  const base = process.env.BOMANSPORT_WEBAPP_URL;
  const token = process.env.BOMANSPORT_API_TOKEN;
  if (!base || !token) {
    return { status: 500 as const, body: { ok: false, error: "Faltan BOMANSPORT_WEBAPP_URL o BOMANSPORT_API_TOKEN en las variables de entorno." } };
  }

  const inicio = Date.now();
  const { data: log, error: errorLog } = await admin
    .from("bomansport_importaciones")
    .insert({ origen, ejecutado_por: ejecutadoPor })
    .select("id")
    .single();
  if (errorLog || !log) {
    return { status: 500 as const, body: { ok: false, error: `No se pudo iniciar el registro de importación: ${errorLog?.message ?? "error desconocido"}` } };
  }
  const importacionId = log.id as string;

  async function cerrarConError(mensaje: string) {
    await admin
      .from("bomansport_importaciones")
      .update({ estado: "error", mensaje_error: mensaje, finalizado_en: new Date().toISOString(), duracion_ms: Date.now() - inicio })
      .eq("id", importacionId);
  }

  // 1. Traer los contratos crudos de Apps Script (mismo mecanismo server-to-server que /tablero).
  let contratosCrudos: ContratoCrudo[];
  let totalOrigen = 0;
  try {
    const url = `${base}?api=contratos&token=${encodeURIComponent(token)}`;
    const res = await fetch(url, { cache: "no-store", redirect: "follow" });
    if (!res.ok) throw new Error(`Apps Script respondió ${res.status}`);
    const cuerpo = await res.json();
    if (cuerpo && cuerpo.error) throw new Error(String(cuerpo.error));
    if (!Array.isArray(cuerpo?.contratos)) throw new Error("Respuesta de Apps Script sin el arreglo 'contratos'.");
    contratosCrudos = cuerpo.contratos as ContratoCrudo[];
    totalOrigen = Number(cuerpo.total) || contratosCrudos.length;
  } catch (e) {
    const mensaje = `No se pudo leer BomanSport: ${textoError(e)}`;
    await cerrarConError(mensaje);
    return { status: 502 as const, body: { ok: false, importacion_id: importacionId, error: mensaje } };
  }

  // 2. Mapear cada fila; una fila mala no aborta el resto.
  const validos: ContratoTipado[] = [];
  const errores: { numero: string; mensaje: string }[] = [];
  const vistos = new Set<string>();
  for (const crudo of contratosCrudos) {
    const resultado = mapearContrato(crudo);
    if (!resultado.ok) {
      errores.push({ numero: resultado.numero, mensaje: resultado.mensaje });
      continue;
    }
    // Si el mismo numero aparece dos veces en la hoja (no deberia, pero por
    // las dudas), se queda con la ultima ocurrencia y no se cuenta dos veces.
    if (vistos.has(resultado.contrato.numero)) {
      const idx = validos.findIndex((c) => c.numero === resultado.contrato.numero);
      if (idx >= 0) validos[idx] = resultado.contrato;
    } else {
      vistos.add(resultado.contrato.numero);
      validos.push(resultado.contrato);
    }
  }

  // 3. Comparar contra lo ya importado para clasificar creado/actualizado/sin_cambio.
  const { data: existentes, error: errorExistentes } = await admin
    .from("bomansport_contratos")
    .select("numero, fila_hash, datos");
  if (errorExistentes) {
    const mensaje = `No se pudo leer el estado actual: ${errorExistentes.message}`;
    await cerrarConError(mensaje);
    return { status: 500 as const, body: { ok: false, importacion_id: importacionId, error: mensaje } };
  }
  const previoPorNumero = new Map(
    (existentes ?? []).map((f) => [f.numero as string, { hash: f.fila_hash as string, datos: f.datos as unknown }])
  );

  const nowIso = new Date().toISOString();
  const paraEscribir: (ContratoTipado & { ultima_sincronizacion_en: string; ultimo_cambio_en: string; ultima_importacion_id: string })[] = [];
  const historial: { numero_contrato: string; fila_hash_anterior: string | null; fila_hash_nuevo: string; datos_anterior: unknown; datos_nuevo: unknown; importacion_id: string }[] = [];
  const numerosSinCambio: string[] = [];
  let creados = 0;
  let actualizados = 0;

  for (const contrato of validos) {
    const previo = previoPorNumero.get(contrato.numero);
    if (previo === undefined) {
      creados++;
      paraEscribir.push({ ...contrato, ultima_sincronizacion_en: nowIso, ultimo_cambio_en: nowIso, ultima_importacion_id: importacionId });
    } else if (previo.hash !== contrato.fila_hash) {
      actualizados++;
      paraEscribir.push({ ...contrato, ultima_sincronizacion_en: nowIso, ultimo_cambio_en: nowIso, ultima_importacion_id: importacionId });
      historial.push({
        numero_contrato: contrato.numero,
        fila_hash_anterior: previo.hash,
        fila_hash_nuevo: contrato.fila_hash,
        datos_anterior: previo.datos,
        datos_nuevo: contrato.datos,
        importacion_id: importacionId,
      });
    } else {
      numerosSinCambio.push(contrato.numero);
    }
  }

  // 4. Escribir. Creados/actualizados por upsert en lotes; sin_cambio con un
  // update liviano (mismo lote homogeneo, sin mezclar formas de fila).
  try {
    for (let i = 0; i < paraEscribir.length; i += 500) {
      const lote = paraEscribir.slice(i, i + 500);
      const { error } = await admin.from("bomansport_contratos").upsert(lote, { onConflict: "numero" });
      if (error) throw new Error(error.message);
    }
    for (let i = 0; i < numerosSinCambio.length; i += 500) {
      const lote = numerosSinCambio.slice(i, i + 500);
      const { error } = await admin
        .from("bomansport_contratos")
        .update({ ultima_sincronizacion_en: nowIso, ultima_importacion_id: importacionId })
        .in("numero", lote);
      if (error) throw new Error(error.message);
    }
    if (historial.length) {
      const { error } = await admin.from("bomansport_contratos_historial").insert(historial);
      if (error) throw new Error(error.message);
    }
  } catch (e) {
    const mensaje = `Falló al escribir en Supabase: ${textoError(e)}`;
    await cerrarConError(mensaje);
    return { status: 500 as const, body: { ok: false, importacion_id: importacionId, error: mensaje } };
  }

  // 5. Cerrar el log.
  const resumen = {
    total_filas_origen: totalOrigen,
    creados,
    actualizados,
    sin_cambio: numerosSinCambio.length,
    con_error: errores.length,
    errores,
  };
  await admin
    .from("bomansport_importaciones")
    .update({ estado: "ok", finalizado_en: new Date().toISOString(), duracion_ms: Date.now() - inicio, ...resumen })
    .eq("id", importacionId);

  return { status: 200 as const, body: { ok: true, importacion_id: importacionId, ...resumen } };
}

export async function GET(request: NextRequest) {
  if (!tieneSecretoValido(request)) {
    return NextResponse.json({ ok: false, error: "No autorizado." }, { status: 401 });
  }
  const resultado = await sincronizar("cron", null);
  return NextResponse.json(resultado.body, { status: resultado.status });
}

export async function POST(request: NextRequest) {
  // El bearer identifica una llamada automatizada (igual que el cron, solo
  // que disparada por POST para poder probarla con curl) - "manual" en el
  // log queda reservado a cuando SI hay una persona detras del clic, que es
  // lo que exige el check de la tabla (manual <=> ejecutado_por no nulo).
  if (tieneSecretoValido(request)) {
    const resultado = await sincronizar("cron", null);
    return NextResponse.json(resultado.body, { status: resultado.status });
  }
  const adminId = await adminDeSesion();
  if (!adminId) {
    return NextResponse.json({ ok: false, error: "Solo un administrador puede sincronizar." }, { status: 401 });
  }
  const resultado = await sincronizar("manual", adminId);
  return NextResponse.json(resultado.body, { status: resultado.status });
}
