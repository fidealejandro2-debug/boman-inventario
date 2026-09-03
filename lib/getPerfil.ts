import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";
import {
  TODOS_LOS_PERMISOS,
  type Perfil,
  type PermisoCodigo,
  type RolUsuario,
} from "@/lib/permisos";

export { tienePermiso } from "@/lib/permisos";
export type { Perfil, PermisoCodigo, RolUsuario } from "@/lib/permisos";

// Permite desplegar la interfaz antes de instalar v35 sin cambiar el acceso
// que ya tenia cada rol. Cuando existe v35, la base reemplaza estos valores.
const PERMISOS_ANTERIORES: Record<RolUsuario, PermisoCodigo[]> = {
  admin: TODOS_LOS_PERMISOS,
  bodega: [
    "inventario.acceder", "operaciones.acceder", "conteos.acceder",
    "movimientos.acceder", "ventas.acceder", "compras.acceder",
    "produccion.acceder", "produccion.calidad.registrar", "notificaciones.acceder",
    "mantenimiento.acceder", "mantenimiento.editar", "importaciones.acceder",
  ],
  logistica: [
    "inventario.acceder", "operaciones.acceder",
    "movimientos.acceder", "produccion.acceder", "produccion.calidad.registrar",
    "notificaciones.acceder",
    "mantenimiento.acceder", "mantenimiento.editar",
  ],
  gerencia: [
    "inventario.acceder", "operaciones.acceder", "conteos.acceder",
    "movimientos.acceder", "ventas.acceder", "compras.acceder",
    "produccion.acceder", "produccion.calidad.resolver",
    "control.acceder", "reportes.acceder",
    "nomina.acceder", "notificaciones.acceder", "notificaciones.publicar",
    "mantenimiento.acceder", "franquicia.consolidado", "tesoreria.acceder",
  ],
  tienda: [
    "inventario.acceder", "operaciones.acceder", "conteos.acceder",
    "movimientos.acceder", "ventas.acceder", "notificaciones.acceder",
    "importaciones.acceder",
  ],
  control: [
    "inventario.acceder", "operaciones.acceder", "conteos.acceder",
    "movimientos.acceder", "ventas.acceder", "compras.acceder",
    "produccion.acceder", "produccion.calidad.registrar",
    "produccion.calidad.resolver", "control.acceder", "reportes.acceder",
    "notificaciones.acceder", "notificaciones.publicar",
    "mantenimiento.acceder", "mantenimiento.editar", "franquicia.consolidado",
    "importaciones.acceder", "tesoreria.acceder", "tesoreria.editar",
  ],
  nomina: [
    "inventario.acceder", "operaciones.acceder", "conteos.acceder",
    "movimientos.acceder", "nomina.acceder", "nomina.editar",
    "produccion.calidad.descuento",
    "notificaciones.acceder", "importaciones.acceder",
  ],
  franquiciado: [
    "inventario.acceder", "operaciones.acceder", "franquicia.acceder",
    "franquicia.ventas", "franquicia.caja", "franquicia.inventario",
    "franquicia.reposicion", "notificaciones.acceder", "importaciones.acceder",
  ],
  vendedor_franquicia: [
    "inventario.acceder", "franquicia.acceder", "franquicia.ventas",
    "notificaciones.acceder",
  ],
};

export async function getPerfilActual(): Promise<Perfil> {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: perfil, error } = await supabase
    .from("perfiles")
    .select("id, nombre_completo, rol, entidad_id, activo")
    .eq("id", user.id)
    .single();

  if (error || !perfil) {
    await supabase.auth.signOut();
    redirect("/login?motivo=sin-perfil");
  }

  if (!perfil.activo) {
    await supabase.auth.signOut();
    redirect("/login?motivo=inactivo");
  }

  const perfilBase = perfil as Omit<Perfil, "permisos">;
  const { data: permisos, error: permisosError } = await supabase.rpc(
    "permisos_usuario_actual_v35"
  );

  return {
    ...perfilBase,
    permisos:
      !permisosError && Array.isArray(permisos)
        ? (permisos as PermisoCodigo[])
        : PERMISOS_ANTERIORES[perfilBase.rol],
  };
}
