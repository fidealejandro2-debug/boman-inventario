import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";
import { cache } from "react";
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
  produccion: [
    "produccion.acceder", "produccion.calidad.registrar",
    "contratos.marcar_etapa", "notificaciones.acceder",
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
    "franquicia.reposicion", "franquicia.turnos", "franquicia.cobros",
    "franquicia.devoluciones", "notificaciones.acceder", "importaciones.acceder",
  ],
  vendedor_franquicia: [
    "inventario.acceder", "franquicia.acceder", "franquicia.ventas",
    "franquicia.turnos", "notificaciones.acceder",
  ],
};

type PerfilNavegacionV137 = {
  id: string;
  nombre_completo: string;
  rol: RolUsuario;
  entidad_id: string | null;
  activo: boolean;
  clave_temporal_desde: string | null;
  permisos: string[];
  modo_boman_especifico: boolean;
  estaciones: string[];
};

function esPerfilNavegacion(valor: unknown): valor is PerfilNavegacionV137 {
  if (!valor || typeof valor !== "object") return false;
  const perfil = valor as Partial<PerfilNavegacionV137>;
  return typeof perfil.id === "string"
    && typeof perfil.nombre_completo === "string"
    && typeof perfil.rol === "string"
    && typeof perfil.activo === "boolean"
    && Array.isArray(perfil.permisos)
    && Array.isArray(perfil.estaciones)
    && typeof perfil.modo_boman_especifico === "boolean";
}

// cache() evita repetir esta lectura cuando una misma renderizacion del
// servidor necesita el perfil mas de una vez. v137, ademas, reduce cinco
// solicitudes a Supabase a una sola llamada. El camino anterior queda como
// compatibilidad para poder publicar la app antes de instalar la migracion.
export const getPerfilActual = cache(async (): Promise<Perfil> => {
  const supabase = await createClient();

  const { data: resumen } = await supabase.rpc("perfil_navegacion_v137");
  if (esPerfilNavegacion(resumen)) {
    if (!resumen.activo) {
      await supabase.auth.signOut();
      redirect("/login?motivo=inactivo");
    }
    if (resumen.clave_temporal_desde) {
      redirect("/establecer-clave?motivo=clave-temporal");
    }
    return {
      id: resumen.id,
      nombre_completo: resumen.nombre_completo,
      rol: resumen.rol,
      entidad_id: resumen.entidad_id,
      activo: resumen.activo,
      permisos: resumen.permisos as PermisoCodigo[],
      modo_boman_especifico: resumen.modo_boman_especifico,
      estaciones: resumen.estaciones,
    };
  }

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

  const perfilBase = perfil as Omit<Perfil, "permisos" | "modo_boman_especifico" | "estaciones">;
  const [
    { data: permisos, error: permisosError },
    { data: modoBoman, error: modoBomanError },
    { data: estaciones },
  ] = await Promise.all([
    supabase.rpc("permisos_usuario_actual_v35"),
    supabase.rpc("modo_boman_especifico_activo"),
    // Aparte del select principal a proposito: `estaciones` solo existe desde
    // v117, y pedirla ahi tumbaria el login de TODOS si el deploy llega antes
    // que la migracion. Aqui, si la columna no esta, solo se pierde el dato.
    supabase.rpc("estaciones_usuario_actual_v117"),
  ]);

  return {
    ...perfilBase,
    estaciones: Array.isArray(estaciones) ? (estaciones as string[]) : [],
    permisos:
      !permisosError && Array.isArray(permisos)
        ? (permisos as PermisoCodigo[])
        : PERMISOS_ANTERIORES[perfilBase.rol],
    // Fail-open a true: un error de RPC nunca debe ocultar algo por si solo,
    // mismo criterio que el fallback de permisos de arriba.
    modo_boman_especifico: !modoBomanError && typeof modoBoman === "boolean" ? modoBoman : true,
  };
});
