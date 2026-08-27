import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";

export const dynamic = "force-dynamic";

const ROLES = ["admin", "bodega", "logistica", "gerencia", "tienda", "control"] as const;
type Rol = (typeof ROLES)[number];

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

function textoError(error: unknown) {
  return error instanceof Error ? error.message : "Ocurrió un error inesperado.";
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
      return {
        ...perfil,
        almacen_ids: (asignaciones.data ?? []).filter((a) => a.perfil_id === perfil.id).map((a) => a.almacen_id),
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
    const email = String(body.email ?? "").trim().toLowerCase();
    const nombre = String(body.nombre_completo ?? "").trim();
    const rol = body.rol;
    const almacenIds = Array.isArray(body.almacen_ids) ? body.almacen_ids.map(String).filter(Boolean) : [];
    const entidadId = almacenIds[0] ?? (body.entidad_id ? String(body.entidad_id) : null);

    if (!email || !email.includes("@")) {
      return NextResponse.json({ error: "Ingresa un correo válido." }, { status: 400 });
    }
    if (!nombre) {
      return NextResponse.json({ error: "El nombre completo es obligatorio." }, { status: 400 });
    }
    if (!esRol(rol)) {
      return NextResponse.json({ error: "El rol indicado no es válido." }, { status: 400 });
    }
    if (!["admin", "control", "gerencia"].includes(rol) && !entidadId) {
      return NextResponse.json({ error: "Los usuarios operativos deben tener al menos un almacén asignado." }, { status: 400 });
    }

    const admin = createAdminClient();
    const urlBase = process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "") ?? request.nextUrl.origin;
    const redirectTo = new URL("/auth/callback", urlBase).toString();
    const { data: invitacion, error: invitacionError } = await admin.auth.admin.inviteUserByEmail(email, {
      data: { nombre_completo: nombre },
      redirectTo,
    });

    if (invitacionError || !invitacion.user) {
      return NextResponse.json(
        { error: invitacionError?.message ?? "No se pudo crear la invitación." },
        { status: 400 }
      );
    }

    const { error: perfilError } = await contexto.supabase.rpc("admin_actualizar_perfil", {
      p_perfil_id: invitacion.user.id,
      p_nombre_completo: nombre,
      p_rol: rol,
      p_entidad_id: entidadId,
      p_activo: true,
    });

    if (perfilError) {
      return NextResponse.json(
        {
          error: `La invitación fue creada, pero no se pudo asignar el perfil: ${perfilError.message}`,
          invitacion_creada: true,
        },
        { status: 500 }
      );
    }

    const { error: asignacionError } = await contexto.supabase.rpc("admin_asignar_almacenes", {
      p_perfil_id: invitacion.user.id,
      p_almacen_ids: ["admin", "control", "gerencia"].includes(rol) ? [] : almacenIds.length ? almacenIds : [entidadId],
    });
    if (asignacionError) {
      return NextResponse.json({ error: `El perfil fue creado, pero falló la asignación de almacenes: ${asignacionError.message}` }, { status: 500 });
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
    const almacenIds = Array.isArray(body.almacen_ids) ? body.almacen_ids.map(String).filter(Boolean) : [];
    const entidadId = almacenIds[0] ?? (body.entidad_id ? String(body.entidad_id) : null);
    const activo = body.activo;

    if (!id || !nombre || !esRol(rol) || typeof activo !== "boolean") {
      return NextResponse.json({ error: "Los datos del usuario están incompletos." }, { status: 400 });
    }
    if (!["admin", "control", "gerencia"].includes(rol) && !entidadId) {
      return NextResponse.json({ error: "Los usuarios operativos deben tener al menos un almacén asignado." }, { status: 400 });
    }

    const { error } = await contexto.supabase.rpc("admin_actualizar_perfil", {
      p_perfil_id: id,
      p_nombre_completo: nombre,
      p_rol: rol,
      p_entidad_id: entidadId,
      p_activo: activo,
    });

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 400 });
    }

    if (activo) {
      const { error: asignacionError } = await contexto.supabase.rpc("admin_asignar_almacenes", {
        p_perfil_id: id,
        p_almacen_ids: ["admin", "control", "gerencia"].includes(rol) ? [] : almacenIds.length ? almacenIds : [entidadId],
      });
      if (asignacionError) {
        return NextResponse.json({ error: asignacionError.message }, { status: 400 });
      }
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
