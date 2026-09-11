import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { mapearContrato, type ContratoCrudo, type ContratoTipado } from "@/lib/bomansportContratos";
import {
  prendasDesdeTallas,
  jugadoresDesde,
  mockupsDesde,
  logosDesde,
  specsDesde,
  facturacionDesde,
  agruparPorNumero,
  etapasDesde,
  eventosDesdeAsignaciones,
  eventosDesdeObservaciones,
  asignacionVigente,
  observacionVigente,
  maquilaVigente,
  type AsignacionCruda,
  type ObservacionCruda,
  type MaquilaCruda,
  type TrazabilidadCruda,
} from "@/lib/bomansportProduccion";

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
  const supabase = await createClient();
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

type AdminClient = ReturnType<typeof createAdminClient>;

const TIPOS_CONTRATO_V79 = ["Normal", "Equipo Profesional", "Mercadería", "Emergente"];

/** ContratoTipado (v90) -> columnas de public.contratos (v79). Solo se
 * mapean los campos que v90 ya tipa con certeza; el resto (telefono,
 * direccion, colores_generales...) se queda en el default de la columna:
 * mapearlos exigiria conocer el encabezado real exacto de ~20 columnas mas
 * de la hoja, y ninguna pantalla construida hasta ahora (v95/v96/v98) los
 * necesita. */
function filaContratoV79(c: ContratoTipado, avisos: string[]) {
  const presupuesto = Math.max(0, c.presupuesto_usd ?? 0);
  const abonoBruto = Math.max(0, c.abono_usd ?? 0);
  // El check (abono <= presupuesto or presupuesto = 0) de v79 puede no
  // cumplirse con datos sucios heredados; se recorta en vez de tumbar todo
  // el lote de contratos por una sola fila mala.
  const abono = presupuesto > 0 ? Math.min(abonoBruto, presupuesto) : 0;
  let fechaInicio = c.fecha_inicio_produccion;
  if (fechaInicio && c.fecha_entrega && c.fecha_entrega < fechaInicio) {
    avisos.push(`${c.numero}: fecha de entrega anterior a la de inicio de producción, se ignoró la fecha de inicio.`);
    fechaInicio = null;
  }
  return {
    numero: c.numero,
    // La fuente histórica de Sheets solo tiene una columna descriptiva. Su
    // contenido corresponde al nombre del contrato, no al cliente real.
    nombre_contrato_v115: c.cliente || "(sin nombre)",
    cliente: c.cliente || "(sin nombre)",
    cliente_confirmado_v115: false,
    vendedor: c.vendedor,
    vendedor_responsable: c.vendedor_responsable,
    canal: c.canal || null,
    // Siempre presente (nunca omitido condicionalmente): un upsert por lotes
    // arma un solo INSERT para todas las filas, y si unas traen esta clave y
    // otras no, PostgREST rellena las que faltan con NULL explícito en vez
    // de aplicar el default de la columna -exactamente lo que rompió el
    // batch completo (fecha_ingreso not null) cuando algunos contratos no
    // traían "Fecha Ingreso" válida en la hoja.
    fecha_ingreso: c.fecha_ingreso ?? new Date().toISOString(),
    fecha_inicio_produccion: fechaInicio,
    fecha_salida_produccion: c.fecha_salida_produccion,
    fecha_entrega: c.fecha_entrega,
    prioridad: c.prioridad === "Urgente" ? "Urgente" : "Normal",
    tipo_contrato: TIPOS_CONTRATO_V79.includes(c.tipo_contrato) ? c.tipo_contrato : "Normal",
    reposicion: c.reposicion,
    total_prendas: Math.max(0, c.total_prendas),
    estado: c.estado || "Ingresado",
    presupuesto,
    abono,
    email_ingresante: c.email_ingresante,
  };
}

/** Upsert de las cabeceras en contratos y lectura de sus id (numero -> id),
 * en lotes para no mandar un solo request gigante. */
async function subirContratosV79(admin: AdminClient, contratos: ContratoTipado[], avisos: string[]) {
  const filas = contratos.map((c) => filaContratoV79(c, avisos));
  for (let i = 0; i < filas.length; i += 500) {
    const { error } = await admin.from("contratos").upsert(filas.slice(i, i + 500), { onConflict: "numero" });
    if (error) throw new Error(`contratos: ${error.message}`);
  }
  return idsPorNumero(admin, contratos.map((c) => c.numero));
}

async function idsPorNumero(admin: AdminClient, numeros: string[]) {
  const mapa = new Map<string, string>();
  const unicos = Array.from(new Set(numeros));
  for (let i = 0; i < unicos.length; i += 300) {
    const lote = unicos.slice(i, i + 300);
    const { data, error } = await admin.from("contratos").select("id, numero").in("numero", lote);
    if (error) throw new Error(`contratos (lectura ids): ${error.message}`);
    (data ?? []).forEach((r) => mapa.set(r.numero as string, r.id as string));
  }
  return mapa;
}

/** Borra y vuelve a insertar los hijos (prendas, jugadores, archivos, specs,
 * facturacion) de cada contrato en contratosATransformar. Correcto porque la
 * fuente (datosTallasJson, etc.) siempre llega completa, nunca incremental:
 * un upsert fila-por-fila arrastraria lineas viejas que ya no existen en el
 * contrato editado. */
async function reemplazarHijosContratos(admin: AdminClient, contratos: { id: string; crudo: ContratoCrudo }[]) {
  const ids = contratos.map((c) => c.id);
  const prendas: Record<string, unknown>[] = [];
  const jugadores: Record<string, unknown>[] = [];
  const archivos: Record<string, unknown>[] = [];
  const specs: Record<string, unknown>[] = [];
  const facturacion: Record<string, unknown>[] = [];
  for (const { id, crudo } of contratos) {
    prendasDesdeTallas(crudo.datosTallasJson).forEach((p) => prendas.push({ ...p, contrato_id: id }));
    jugadoresDesde(crudo.jugadoresJson).forEach((j) => jugadores.push({ ...j, contrato_id: id }));
    mockupsDesde(crudo.linkMockupJson).forEach((a) => archivos.push({ ...a, contrato_id: id }));
    logosDesde(crudo.logosDriveJson).forEach((a) => archivos.push({ ...a, contrato_id: id }));
    specsDesde(crudo.datosTecnicosCalidadJson).forEach((s) => specs.push({ ...s, contrato_id: id }));
    facturacionDesde(crudo.detalleFacturacionJson).forEach((f) => facturacion.push({ ...f, contrato_id: id }));
  }

  for (let i = 0; i < ids.length; i += 200) {
    const lote = ids.slice(i, i + 200);
    for (const tabla of ["contrato_prendas", "contrato_jugadores", "contrato_archivos", "contrato_specs", "contrato_facturacion"]) {
      const { error } = await admin.from(tabla).delete().in("contrato_id", lote);
      if (error) throw new Error(`${tabla} (borrado): ${error.message}`);
    }
  }
  async function insertarLotes(tabla: string, filas: Record<string, unknown>[]) {
    for (let i = 0; i < filas.length; i += 500) {
      const { error } = await admin.from(tabla).insert(filas.slice(i, i + 500));
      if (error) throw new Error(`${tabla} (insercion): ${error.message}`);
    }
  }
  await insertarLotes("contrato_prendas", prendas);
  await insertarLotes("contrato_jugadores", jugadores);
  await insertarLotes("contrato_archivos", archivos);
  await insertarLotes("contrato_specs", specs);
  await insertarLotes("contrato_facturacion", facturacion);
}

/** Trae ?api=produccion (Asignaciones/Observaciones/Maquila completas,
 * Trazabilidad incremental) y lo aplica sobre v79: bitacora de etapas y
 * eventos, mas el valor vigente (disenador/autor_mockup/observacion/maquila)
 * en la cabecera de contratos. Corre aparte de la sincronizacion de
 * contratos: si esto falla, los contratos ya escritos no se pierden. */
/** Aplica disenador/autor_mockup/observacion/maquila vigentes en lotes. Antes
 * era un .update() por contrato -con cientos o miles de contratos eso es una
 * ida y vuelta a Supabase por cada uno, secuencial, y es lo que se pasaba del
 * maxDuration de Vercel dejando la corrida en "en_curso" para siempre. Ahora
 * se lee el valor actual de los 4 campos en lotes, se combina con lo nuevo
 * (un campo ausente en `campos` conserva el valor que ya tenia -Asignaciones/
 * Observaciones/Maquila se leen completas cada vez, asi que si el valor no
 * aparece esta corrida es porque de verdad no existe en el origen) y se sube
 * todo junto en un solo upsert por lote. */
async function aplicarVigente(admin: AdminClient, actualizaciones: { id: string; campos: Record<string, unknown> }[]) {
  if (!actualizaciones.length) return;
  const ids = actualizaciones.map((a) => a.id);
  const actuales = new Map<string, Record<string, unknown>>();
  for (let i = 0; i < ids.length; i += 300) {
    const lote = ids.slice(i, i + 300);
    const { data, error } = await admin
      .from("contratos")
      .select("id, disenador, autor_mockup, observacion, maquila")
      .in("id", lote);
    if (error) throw new Error(`contratos (lectura vigente): ${error.message}`);
    (data ?? []).forEach((r) => actuales.set(r.id as string, r));
  }
  const filas = actualizaciones.map(({ id, campos }) => {
    const base = actuales.get(id) ?? {};
    return {
      id,
      disenador: campos.disenador ?? base.disenador ?? null,
      autor_mockup: campos.autor_mockup ?? base.autor_mockup ?? null,
      observacion: campos.observacion ?? base.observacion ?? null,
      maquila: campos.maquila ?? base.maquila ?? null,
    };
  });
  for (let i = 0; i < filas.length; i += 500) {
    const { error } = await admin.from("contratos").upsert(filas.slice(i, i + 500), { onConflict: "id" });
    if (error) throw new Error(`contratos (vigente): ${error.message}`);
  }
}

async function transformarProduccionV79(
  admin: AdminClient,
  base: string,
  token: string,
  origen: Origen,
  ejecutadoPor: string | null
) {
  const inicio = Date.now();
  const { data: ultimoOk } = await admin
    .from("bomansport_produccion_importaciones")
    .select("ultima_fila_trazabilidad")
    .eq("estado", "ok")
    .order("iniciado_en", { ascending: false })
    .limit(1)
    .maybeSingle();
  const desdeFilaTraza = (ultimoOk?.ultima_fila_trazabilidad as number | undefined) ?? 0;

  const { data: log, error: errorLog } = await admin
    .from("bomansport_produccion_importaciones")
    .insert({ origen, ejecutado_por: ejecutadoPor, ultima_fila_trazabilidad: desdeFilaTraza })
    .select("id")
    .single();
  if (errorLog || !log) return; // no aborta la sincronizacion principal por esto
  const logId = log.id as string;

  async function cerrar(campos: Record<string, unknown>) {
    await admin
      .from("bomansport_produccion_importaciones")
      .update({ finalizado_en: new Date().toISOString(), duracion_ms: Date.now() - inicio, ...campos })
      .eq("id", logId);
  }

  try {
    const url = `${base}?api=produccion&token=${encodeURIComponent(token)}&desdeFilaTraza=${desdeFilaTraza}`;
    const res = await fetch(url, { cache: "no-store", redirect: "follow" });
    if (!res.ok) throw new Error(`Apps Script respondió ${res.status}`);
    const cuerpo = await res.json();
    if (cuerpo && cuerpo.error) throw new Error(String(cuerpo.error));

    const asignaciones = agruparPorNumero((cuerpo.asignaciones ?? []) as AsignacionCruda[]);
    const observaciones = agruparPorNumero((cuerpo.observaciones ?? []) as ObservacionCruda[]);
    const maquila = agruparPorNumero((cuerpo.maquila ?? []) as MaquilaCruda[]);
    const trazabilidad = agruparPorNumero((cuerpo.trazabilidad ?? []) as TrazabilidadCruda[]);
    const ultimaFilaTrazabilidad = Number(cuerpo.ultimaFilaTrazabilidad) || desdeFilaTraza;

    const numerosRelevantes = new Set<string>([
      ...asignaciones.keys(),
      ...observaciones.keys(),
      ...maquila.keys(),
      ...trazabilidad.keys(),
    ]);
    const ids = await idsPorNumero(admin, Array.from(numerosRelevantes));

    const erroresContrato: { numero: string; mensaje: string }[] = [];
    let etapasNuevas = 0;
    let eventosNuevos = 0;

    // Eventos derivados de Asignaciones/Observaciones: esas 2 hojas se leen
    // COMPLETAS en cada corrida (no son incrementales como Trazabilidad), asi
    // que sin este filtro se duplicarian todos los dias. Se compara contra lo
    // que ya existe por (contrato_id, campo, valor_nuevo, created_at).
    const idsConEventos = Array.from(numerosRelevantes)
      .map((n) => ids.get(n))
      .filter((v): v is string => !!v);
    const eventosExistentes = new Set<string>();
    for (let i = 0; i < idsConEventos.length; i += 200) {
      const lote = idsConEventos.slice(i, i + 200);
      const { data } = await admin
        .from("contrato_eventos")
        .select("contrato_id, campo, valor_nuevo, created_at")
        .in("contrato_id", lote);
      (data ?? []).forEach((e) =>
        eventosExistentes.add(`${e.contrato_id}|${e.campo}|${e.valor_nuevo}|${e.created_at}`)
      );
    }

    const filasEtapas: Record<string, unknown>[] = [];
    const filasEventos: Record<string, unknown>[] = [];
    const actualizacionesVigente: { id: string; campos: Record<string, unknown> }[] = [];

    for (const numero of numerosRelevantes) {
      const id = ids.get(numero);
      if (!id) {
        erroresContrato.push({ numero, mensaje: "No existe todavia en contratos (v79); se procesará en la próxima corrida." });
        continue;
      }
      etapasDesde(trazabilidad.get(numero) ?? []).forEach((e) => {
        filasEtapas.push({ ...e, contrato_id: id });
        etapasNuevas++;
      });
      [...eventosDesdeAsignaciones(asignaciones.get(numero) ?? []), ...eventosDesdeObservaciones(observaciones.get(numero) ?? [])].forEach(
        (ev) => {
          const clave = `${id}|${ev.campo}|${ev.valor_nuevo}|${ev.created_at}`;
          if (eventosExistentes.has(clave)) return;
          eventosExistentes.add(clave);
          filasEventos.push({ contrato_id: id, campo: ev.campo, valor_nuevo: ev.valor_nuevo, quien: ev.quien, created_at: ev.created_at });
          eventosNuevos++;
        }
      );

      const vigente = asignacionVigente(asignaciones.get(numero) ?? []);
      const obsVigente = observacionVigente(observaciones.get(numero) ?? []);
      const maquilaVigenteVal = maquilaVigente(maquila.get(numero) ?? []);
      const campos: Record<string, unknown> = {};
      if (vigente?.disenador) campos.disenador = vigente.disenador;
      if (vigente?.autorMockup) campos.autor_mockup = vigente.autorMockup;
      if (obsVigente) campos.observacion = obsVigente;
      if (maquilaVigenteVal) campos.maquila = maquilaVigenteVal;
      if (Object.keys(campos).length) actualizacionesVigente.push({ id, campos });
    }

    async function insertarLotes(tabla: string, filas: Record<string, unknown>[]) {
      for (let i = 0; i < filas.length; i += 500) {
        const { error } = await admin.from(tabla).insert(filas.slice(i, i + 500));
        if (error) throw new Error(`${tabla} (insercion): ${error.message}`);
      }
    }
    await insertarLotes("contrato_etapas", filasEtapas);
    await insertarLotes("contrato_eventos", filasEventos);
    await aplicarVigente(admin, actualizacionesVigente);

    await cerrar({
      estado: "ok",
      contratos_procesados: numerosRelevantes.size,
      etapas_nuevas: etapasNuevas,
      eventos_nuevos: eventosNuevos,
      con_error: erroresContrato.length,
      errores: erroresContrato,
      ultima_fila_trazabilidad: ultimaFilaTrazabilidad,
    });
  } catch (e) {
    await cerrar({ estado: "error", mensaje_error: textoError(e) });
  }
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

  const base = process.env.BOMANSPORT_WEBAPP_URL;
  const token = process.env.BOMANSPORT_API_TOKEN;
  if (!base || !token) {
    return { status: 500 as const, body: { ok: false, error: "Faltan BOMANSPORT_WEBAPP_URL o BOMANSPORT_API_TOKEN en las variables de entorno." } };
  }

  const { data: inicioAtomico, error: errorInicio } = await admin.rpc(
    "iniciar_importacion_bomansport_v132",
    { p_origen: origen, p_ejecutado_por: ejecutadoPor }
  );
  if (errorInicio) {
    return { status: 500 as const, body: { ok: false, error: `No se pudo iniciar la importación: ${errorInicio.message}` } };
  }
  const inicioDatos = inicioAtomico as { iniciada?: boolean; id?: string } | null;
  if (!inicioDatos?.iniciada) {
    return { status: 409 as const, body: { ok: false, error: "Ya hay una sincronización en curso. Intenta de nuevo en unos minutos." } };
  }

  const inicio = Date.now();
  const importacionId = inicioDatos.id as string;

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

  // 4.5. v94: subir a v79 (contratos, prendas, jugadores, archivos, specs,
  // facturacion, etapas, eventos). Aparte de try/catch propio: si v94 todavia
  // no esta instalada en Supabase (o falla), la sincronizacion base de arriba
  // -que ya funcionaba antes de v94- no debe romperse por esto.
  try {
    // Con miles de contratos historicos, migrar TODOS los que faltan en v79 de
    // una sola corrida puede pasarse del maxDuration de Vercel (60s) y matar
    // la funcion a medio insertar, dejando el log en "en_curso" para siempre.
    // Se prioriza lo que de verdad cambio hoy (paraEscribir) y el resto del
    // backfill se completa solo, unos cuantos por corrida, en los proximos
    // clics de "Sincronizar ahora" (numerosFaltantesEnV79 se recalcula cada
    // vez comparando contra lo que ya existe en contratos).
    const LIMITE_BACKFILL_V79 = 150;
    const numerosCreadosActualizados = paraEscribir.map((c) => c.numero);
    const numerosFaltantesEnV79: string[] = [];
    for (let i = 0; i < numerosSinCambio.length; i += 300) {
      const lote = numerosSinCambio.slice(i, i + 300);
      const { data } = await admin.from("contratos").select("numero").in("numero", lote);
      const presentes = new Set((data ?? []).map((r) => r.numero as string));
      lote.forEach((n) => { if (!presentes.has(n)) numerosFaltantesEnV79.push(n); });
    }
    const cupoBackfill = Math.max(0, LIMITE_BACKFILL_V79 - numerosCreadosActualizados.length);
    const numerosBackfill = numerosFaltantesEnV79.slice(0, cupoBackfill);
    if (numerosFaltantesEnV79.length > numerosBackfill.length) {
      errores.push({
        numero: "(v79)",
        mensaje: `Quedan ${numerosFaltantesEnV79.length - numerosBackfill.length} contrato(s) históricos por migrar a producción; se completan solos en las próximas corridas.`,
      });
    }
    const numerosATransformar = new Set([...numerosCreadosActualizados, ...numerosBackfill]);
    const contratosATransformar = validos.filter((c) => numerosATransformar.has(c.numero));

    if (contratosATransformar.length) {
      const avisosV79: string[] = [];
      const idsV79 = await subirContratosV79(admin, contratosATransformar, avisosV79);
      const conId = contratosATransformar
        .map((c) => ({ id: idsV79.get(c.numero), crudo: c.datos }))
        .filter((c): c is { id: string; crudo: ContratoCrudo } => !!c.id);
      await reemplazarHijosContratos(admin, conId);
      avisosV79.forEach((mensaje) => errores.push({ numero: "(v79)", mensaje }));
    }

    await transformarProduccionV79(admin, base, token, origen, ejecutadoPor);
  } catch (e) {
    errores.push({ numero: "(v79)", mensaje: `No se pudo poblar el esquema de contratos: ${textoError(e)}` });
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
