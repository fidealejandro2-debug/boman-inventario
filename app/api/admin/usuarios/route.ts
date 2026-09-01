import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";

export const dynamic = "force-dynamic";

const ROLES = ["admin", "bodega", "logistica", "gerencia", "tienda", "control", "nomina", "franquiciado", "vendedor_franquicia"] as const;
type Rol = (typeof ROLES)[number];
const ROLES_SIN_ALMACEN: Rol[] = ["admin", "control", "gerencia", "nomina"];
const ROLES_UN_SOLO_ALMACEN: Rol[] = ["franquiciado", "vendedor_franquicia"];
const UUID_VALIDO = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type DatosPerfil = {
  id: string;
  nombre_completo: string;
  rol: Rol;
  entidad_id: string | null;
  activo: boolean;
  created_at: string;
};

function esRol(valor: unknown): valor is Rol {
  return typeof valor === "string" && ROLES.includes(valor as Rol);
}

function almacenesDelBody(valor: unknown) {
  return Array.isArray(valor)
    ? [...new Set(valor.map((id) => String(id).trim()).filter(Boolean))]
    : [];
}

async function validarAlmacenesActivos(
  supabase: ReturnType<typeof createClient>,
  ids: string[]
) {
  if (ids.some((id) => !UUID_VALIDO.test(id))) {
    return "Uno de los almacenes tiene un identificador inválido.";
  }
  if (!ids.length) return null;
  const { data, error } = await supabase
    .from("almacenes")
    .select("id")
    .in("id", ids)
    .eq("activo", true);
  if (error) return `No se pudieron validar los almacenes: ${error.message}`;
  const encontrados = new Set((data ?? []).map((fila) => fila.id));
  return ids.every((id) => encontrados.has(id))
    ? null
    : "Uno de los almacenes seleccionados no existe o está inactivo.";
}

function textoError(error: unknown) {
  return error instanceof Error ? error.message : "Ocurrió un error inesperado.";
}

/**
 * Clave temporal legible para dictar por teléfono o WhatsApp.
 *
 * Sin caracteres que se confunden al leerlos (0/O, 1/l/I) y con formato
 * XXXX-XXXX-XX. Se genera con crypto y no con Math.random: es la credencial
 * de acceso de una persona, no un identificador cualquiera.
 */
function generarClaveTemporal() {
  const alfabeto = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  const chars = Array.from(bytes, (b) => alfabeto[b % alfabeto.length]);
  return `${chars.slice(0, 4).join("")}-${chars.slice(4, 8).join("")}-${chars
    .slice(8, 10)
    .join("")}`;
}

function validarOrigen(request: NextRequest) {
  const origin = request.headers.get("origin");
  return !origin || origin === request.nextUrl.origin;
}

async function obtenerAdmin() {
  const supabase = createClient();
  const { data: auth, error: authError } = await supabase.auth.getUser();

  if (authError || !auth.user) {
    return { error: NextResponse.json({ error: "Sesión no válida." }, { status: 401 }) };
  }

  const { data: perfil, error: perfilError } = await supabase
    .from("perfiles")
    .select("rol, activo")
    .eq("id", auth.user.id)
    .single();

  if (perfilError || !perfil?.activo || perfil.rol !== "admin") {
    return { error: NextResponse.json({ error: "Solo un administrador puede gestionar usuarios." }, { status: 403 }) };
  }

  return { supabase, usuario: auth.user };
}

export async function GET() {
  const contexto = await obtenerAdmin();
  if ("error" in contexto) return contexto.error;

  try {
    const admin = createAdminClient();
    const [perfiles, almacenes, asignaciones, usuariosAuth] = await Promise.all([
      contexto.supabase
        .from("perfiles")
        .select("id, nombre_completo, rol, entidad_id, activo, created_at")
        .order("nombre_completo"),
      contexto.supabase
        .from("almacenes")
        .select("id, nombre, tipo, activo")
        .eq("activo", true)
        .order("tipo")
        .order("nombre"),
      contexto.supabase
        .from("perfil_almacenes")
        .select("perfil_id, almacen_id"),
      admin.auth.admin.listUsers({ page: 1, perPage: 1000 }),
    ]);

    if (perfiles.error) throw perfiles.error;
    if (almacenes.error) throw almacenes.error;
    if (asignaciones.error) throw asignaciones.error;
    if (usuariosAuth.error) throw usuariosAuth.error;

    const authPorId = new Map(usuariosAuth.data.users.map((usuario) => [usuario.id, usuario]));
    const usuarios = ((perfiles.data ?? []) as DatosPerfil[]).map((perfil) => {
      const usuarioAuth = authPorId.get(perfil.id);
      const almacenIds = (asignaciones.data ?? [])
        .filter((a) => a.perfil_id === perfil.id)
        .map((a) => a.almacen_id);
      return {
        ...perfil,
        almacen_ids: almacenIds,
        configuracion_incompleta:
          perfil.activo && !ROLES_SIN_ALMACEN.includes(perfil.rol) && almacenIds.length === 0,
        email: usuarioAuth?.email ?? "",
        ultimo_acceso: usuarioAuth?.last_sign_in_at ?? null,
        confirmado: Boolean(usuarioAuth?.email_confirmed_at),
      };
    });

    return NextResponse.json({ usuarios, almacenes: almacenes.data ?? [] });
  } catch (error) {
    return NextResponse.json({ error: textoError(error) }, { status: 500 });
  }
}

export async function POST(request: NextRequest) {
  if (!validarOrigen(request)) {
    return NextResponse.json({ error: "Origen de solicitud no permitido." }, { status: 403 });
  }
  const contexto = await obtenerAdmin();
  if ("error" in contexto) return contexto.error;

  try {
    const body = await request.json();
    const accion = String(body.accion ?? "invitar");
    if (accion === "generar_enlace_acceso") {
      const id = String(body.id ?? "");
      if (!id) return NextResponse.json({ error: "Debes indicar el usuario." }, { status: 400 });

      const { data: perfil, error: perfilError } = await contexto.supabase
        .from("perfiles")
        .select("activo")
        .eq("id", id)
        .single();
      if (perfilError || !perfil) {
        return NextResponse.json({ error: "El usuario no existe." }, { status: 404 });
      }
      if (!perfil.activo) {
        return NextResponse.json({ error: "Restaura el acceso del usuario antes de generar un enlace." }, { status: 400 });
      }

      const admin = createAdminClient();
      const { data: usuarioAuth, error: usuarioError } = await admin.auth.admin.getUserById(id);
      const usuario = usuarioAuth.user;
      if (usuarioError || !usuario?.email) {
        return NextResponse.json({ error: usuarioError?.message ?? "El usuario no tiene un correo válido." }, { status: 400 });
      }

      const urlBase = process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "") ?? request.nextUrl.origin;
      const redirectTo = new URL("/auth/callback?next=/establecer-clave", urlBase).toString();
      const tipo = usuario.email_confirmed_at ? "recovery" : "invite";
      const resultado = tipo === "recovery"
        ? await admin.auth.admin.generateLink({
            type: "recovery",
            email: usuario.email,
            options: { redirectTo },
          })
        : await admin.auth.admin.generateLink({
            type: "invite",
            email: usuario.email,
            options: { data: usuario.user_metadata, redirectTo },
          });
      const enlace = resultado.data?.properties?.action_link;
      if (resultado.error || !enlace) {
        return NextResponse.json(
          { error: resultado.error?.message ?? "Supabase no pudo generar el enlace seguro." },
          { status: 400 }
        );
      }

      return NextResponse.json(
        {
          ok: true,
          email: usuario.email,
          enlace,
          tipo: tipo === "invite" ? "activacion" : "recuperacion",
          mensaje: tipo === "invite"
            ? `Enlace de activación generado para ${usuario.email}.`
            : `Enlace de cambio de contraseña generado para ${usuario.email}.`,
        },
        { headers: { "Cache-Control": "no-store" } }
      );
    }

    if (accion === "reenviar_invitacion") {
      const id = String(body.id ?? "");
      if (!id) return NextResponse.json({ error: "Debes indicar el usuario." }, { status: 400 });

      const admin = createAdminClient();
      const { data: usuarioAuth, error: usuarioError } = await admin.auth.admin.getUserById(id);
      const usuario = usuarioAuth.user;
      if (usuarioError || !usuario?.email) {
        return NextResponse.json({ error: usuarioError?.message ?? "El usuario no tiene un correo válido." }, { status: 400 });
      }
      if (usuario.email_confirmed_at) {
        return NextResponse.json({ error: "El correo ya fue confirmado. Envía un cambio de contraseña." }, { status: 400 });
      }

      const urlBase = process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "") ?? request.nextUrl.origin;
      const redirectTo = new URL("/auth/callback?next=/establecer-clave", urlBase).toString();
      const { data: invitacion, error: invitacionError } = await admin.auth.admin.inviteUserByEmail(usuario.email, {
        data: usuario.user_metadata,
        redirectTo,
      });
      if (invitacionError || !invitacion.user) {
        const detalle = invitacionError?.message ?? "No se pudo reenviar la invitación.";
        return NextResponse.json({
          error: detalle.toLowerCase().includes("rate limit")
            ? "Se alcanzó el límite de correos de Supabase. Usa “Generar enlace de activación” para enviarlo desde otro proveedor."
            : detalle,
        }, { status: 400 });
      }
      if (invitacion.user.id !== id) {
        return NextResponse.json({ error: "Supabase generó una identidad diferente. No se modificó el perfil; revisa Authentication → Users." }, { status: 409 });
      }
      return NextResponse.json({ ok: true, mensaje: `Nueva invitación enviada a ${usuario.email}. El enlace anterior ya no debe utilizarse.` });
    }

    const email = String(body.email ?? "").trim().toLowerCase();
    const nombre = String(body.nombre_completo ?? "").trim();
    const rol = body.rol;
    const almacenIdsRecibidos = almacenesDelBody(body.almacen_ids);

    if (!email || !email.includes("@")) {
      return NextResponse.json({ error: "Ingresa un correo válido." }, { status: 400 });
    }
    if (!nombre) {
      return NextResponse.json({ error: "El nombre completo es obligatorio." }, { status: 400 });
    }
    if (!esRol(rol)) {
      return NextResponse.json({ error: "El rol indicado no es válido." }, { status: 400 });
    }
    const almacenIds = ROLES_SIN_ALMACEN.includes(rol) ? [] : almacenIdsRecibidos;
    if (!ROLES_SIN_ALMACEN.includes(rol) && !almacenIds.length) {
      return NextResponse.json({ error: "Los usuarios operativos deben tener al menos un almacén asignado." }, { status: 400 });
    }
    if (ROLES_UN_SOLO_ALMACEN.includes(rol) && almacenIds.length !== 1) {
      return NextResponse.json({ error: "Los usuarios de franquicia deben tener exactamente un local asignado." }, { status: 400 });
    }
    const errorAlmacenes = await validarAlmacenesActivos(contexto.supabase, almacenIds);
    if (errorAlmacenes) {
      return NextResponse.json({ error: errorAlmacenes }, { status: 400 });
    }

    const admin = createAdminClient();
    const urlBase = process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "") ?? request.nextUrl.origin;
    const redirectTo = new URL("/auth/callback", urlBase).toString();

    // Dos caminos para dar de alta. El correo de Supabase tiene un límite de
    // envíos por hora, y al agotarlo devuelve "email rate limit exceeded" y no
    // se puede crear a nadie más. Con clave temporal el alta no depende del
    // correo: se crea el acceso y el administrador entrega la clave a mano.
    const sinCorreo = accion === "crear_con_clave";
    const claveTemporal = sinCorreo ? generarClaveTemporal() : null;

    const { data: creado, error: creacionError } = sinCorreo
      ? await admin.auth.admin.createUser({
          email,
          password: claveTemporal!,
          // Sin confirmar, el usuario no podría entrar y volveríamos a
          // depender de un correo que quizá no llega.
          email_confirm: true,
          user_metadata: { nombre_completo: nombre },
        })
      : await admin.auth.admin.inviteUserByEmail(email, {
          data: { nombre_completo: nombre },
          redirectTo,
        });

    if (creacionError || !creado.user) {
      const detalle = creacionError?.message ?? "No se pudo crear el usuario.";
      const esLimite = /rate limit/i.test(detalle);
      return NextResponse.json(
        {
          error: esLimite
            ? "Supabase alcanzó su límite de correos por hora. Usa la opción de crear con clave temporal, que no envía correo."
            : detalle,
        },
        { status: 400 }
      );
    }

    const { error: perfilError } = await contexto.supabase.rpc("admin_guardar_usuario_v42", {
      p_perfil_id: creado.user.id,
      p_nombre_completo: nombre,
      p_rol: rol,
      p_almacen_ids: almacenIds,
      p_activo: true,
    });

    if (perfilError) {
      const { error: reversionError } = await admin.auth.admin.deleteUser(creado.user.id);
      return NextResponse.json(
        {
          error: reversionError
            ? `No se pudo completar el usuario: ${perfilError.message}. También falló la reversión automática: ${reversionError.message}`
            : `No se creó el usuario: ${perfilError.message}`,
          revertido: !reversionError,
        },
        { status: 500 }
      );
    }

    if (sinCorreo) {
      // La clave viaja por fuera del sistema, así que queda marcada como
      // temporal: el middleware no deja usar nada hasta que la cambie.
      const { error: marcaError } = await admin
        .from("perfiles")
        .update({ clave_temporal_desde: new Date().toISOString() })
        .eq("id", creado.user.id);

      return NextResponse.json(
        {
          ok: true,
          email,
          clave: claveTemporal,
          mensaje: marcaError
            ? `Usuario creado, pero no se pudo exigir el cambio de clave (${marcaError.message}). Pídele que la cambie a mano.`
            : `Usuario creado. Entrega la clave a ${email}: al entrar el sistema le exigirá cambiarla antes de usar nada.`,
        },
        { headers: { "Cache-Control": "no-store" } }
      );
    }

    return NextResponse.json({ ok: true, mensaje: `Invitación enviada a ${email}.` });
  } catch (error) {
    return NextResponse.json({ error: textoError(error) }, { status: 500 });
  }
}

export async function PATCH(request: NextRequest) {
  if (!validarOrigen(request)) {
    return NextResponse.json({ error: "Origen de solicitud no permitido." }, { status: 403 });
  }
  const contexto = await obtenerAdmin();
  if ("error" in contexto) return contexto.error;

  try {
    const body = await request.json();
    const id = String(body.id ?? "");
    const nombre = String(body.nombre_completo ?? "").trim();
    const rol = body.rol;
    const almacenIdsRecibidos = almacenesDelBody(body.almacen_ids);
    const activo = body.activo;

    if (!id || !nombre || !esRol(rol) || typeof activo !== "boolean") {
      return NextResponse.json({ error: "Los datos del usuario están incompletos." }, { status: 400 });
    }
    const almacenIds = ROLES_SIN_ALMACEN.includes(rol) ? [] : almacenIdsRecibidos;
    if (!ROLES_SIN_ALMACEN.includes(rol) && !almacenIds.length) {
      return NextResponse.json({ error: "Los usuarios operativos deben tener al menos un almacén asignado." }, { status: 400 });
    }
    if (activo && ROLES_UN_SOLO_ALMACEN.includes(rol) && almacenIds.length !== 1) {
      return NextResponse.json({ error: "Los usuarios de franquicia deben tener exactamente un local asignado." }, { status: 400 });
    }
    const errorAlmacenes = await validarAlmacenesActivos(contexto.supabase, almacenIds);
    if (errorAlmacenes) {
      return NextResponse.json({ error: errorAlmacenes }, { status: 400 });
    }

    const { error } = await contexto.supabase.rpc("admin_guardar_usuario_v42", {
      p_perfil_id: id,
      p_nombre_completo: nombre,
      p_rol: rol,
      p_almacen_ids: almacenIds,
      p_activo: activo,
    });

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 400 });
    }

    const admin = createAdminClient();
    const { error: accesoError } = await admin.auth.admin.updateUserById(id, {
      ban_duration: activo ? "none" : "876000h",
    });

    return NextResponse.json({
      ok: true,
      advertencia: accesoError
        ? `El perfil fue actualizado, pero Supabase no pudo sincronizar el bloqueo: ${accesoError.message}`
        : null,
    });
  } catch (error) {
    return NextResponse.json({ error: textoError(error) }, { status: 500 });
  }
}

export async function PUT(request: NextRequest) {
  if (!validarOrigen(request)) {
    return NextResponse.json({ error: "Origen de solicitud no permitido." }, { status: 403 });
  }
  const contexto = await obtenerAdmin();
  if ("error" in contexto) return contexto.error;

  try {
    const body = await request.json();
    const id = String(body.id ?? "");
    if (!id) return NextResponse.json({ error: "Debes indicar el usuario." }, { status: 400 });

    const { data: perfil, error: perfilError } = await contexto.supabase
      .from("perfiles")
      .select("activo")
      .eq("id", id)
      .single();
    if (perfilError || !perfil) {
      return NextResponse.json({ error: "El usuario no existe." }, { status: 404 });
    }
    if (!perfil.activo) {
      return NextResponse.json({ error: "Restaura el acceso del usuario antes de cambiar su contraseña." }, { status: 400 });
    }

    const admin = createAdminClient();
    const { data: usuarioAuth, error: usuarioError } = await admin.auth.admin.getUserById(id);
    const email = usuarioAuth.user?.email;
    if (usuarioError || !email) {
      return NextResponse.json({ error: usuarioError?.message ?? "El usuario no tiene un correo válido." }, { status: 400 });
    }

    const urlBase = process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "") ?? request.nextUrl.origin;
    const redirectTo = new URL("/auth/callback?next=/establecer-clave", urlBase).toString();
    const { error: envioError } = await admin.auth.resetPasswordForEmail(email, { redirectTo });
    if (envioError) {
      return NextResponse.json({ error: envioError.message }, { status: 400 });
    }

    return NextResponse.json({ ok: true, mensaje: `Enlace de cambio de contraseña enviado a ${email}.` });
  } catch (error) {
    return NextResponse.json({ error: textoError(error) }, { status: 500 });
  }
}

export async function DELETE(request: NextRequest) {
  if (!validarOrigen(request)) {
    return NextResponse.json({ error: "Origen de solicitud no permitido." }, { status: 403 });
  }
  const contexto = await obtenerAdmin();
  if ("error" in contexto) return contexto.error;

  try {
    const body = await request.json();
    const id = String(body.id ?? "");
    if (!id) return NextResponse.json({ error: "Debes indicar el usuario." }, { status: 400 });
    if (id === contexto.usuario.id) {
      return NextResponse.json({ error: "No puedes eliminar tu propio acceso administrativo." }, { status: 400 });
    }

    const { data: perfil, error: perfilError } = await contexto.supabase
      .from("perfiles")
      .select("nombre_completo, rol, entidad_id, activo")
      .eq("id", id)
      .single();
    if (perfilError || !perfil) {
      return NextResponse.json({ error: "El usuario no existe." }, { status: 404 });
    }
    if (!perfil.activo) {
      return NextResponse.json({ ok: true, mensaje: "El acceso de este usuario ya estaba eliminado." });
    }

    const { error: desactivarError } = await contexto.supabase.rpc("admin_actualizar_perfil", {
      p_perfil_id: id,
      p_nombre_completo: perfil.nombre_completo,
      p_rol: perfil.rol,
      p_entidad_id: perfil.entidad_id,
      p_activo: false,
    });
    if (desactivarError) {
      return NextResponse.json({ error: desactivarError.message }, { status: 400 });
    }

    const admin = createAdminClient();
    const { error: bloqueoError } = await admin.auth.admin.updateUserById(id, {
      ban_duration: "876000h",
    });

    return NextResponse.json({
      ok: true,
      mensaje: "Acceso eliminado. El historial operativo del usuario fue conservado.",
      advertencia: bloqueoError
        ? `La aplicación ya bloqueó el acceso, pero Supabase no pudo sincronizar la prohibición: ${bloqueoError.message}`
        : null,
    });
  } catch (error) {
    return NextResponse.json({ error: textoError(error) }, { status: 500 });
  }
}
