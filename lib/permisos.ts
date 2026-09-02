export type RolUsuario =
  | "admin"
  | "bodega"
  | "logistica"
  | "gerencia"
  | "tienda"
  | "control"
  | "nomina"
  | "franquiciado"
  | "vendedor_franquicia";

export type PermisoCodigo =
  | "inventario.acceder"
  | "operaciones.acceder"
  | "conteos.acceder"
  | "movimientos.acceder"
  | "ventas.acceder"
  | "compras.acceder"
  | "produccion.acceder"
  | "control.acceder"
  | "reportes.acceder"
  | "nomina.acceder"
  | "nomina.editar"
  | "franquicia.acceder"
  | "franquicia.ventas"
  | "franquicia.caja"
  | "franquicia.inventario"
  | "franquicia.reposicion"
  | "franquicia.precio_libre"
  | "franquicia.descuento"
  | "notificaciones.acceder"
  | "notificaciones.publicar"
  | "mantenimiento.acceder"
  | "mantenimiento.editar";

export const TODOS_LOS_PERMISOS: PermisoCodigo[] = [
  "inventario.acceder",
  "operaciones.acceder",
  "conteos.acceder",
  "movimientos.acceder",
  "ventas.acceder",
  "compras.acceder",
  "produccion.acceder",
  "control.acceder",
  "reportes.acceder",
  "nomina.acceder",
  "nomina.editar",
  "franquicia.acceder",
  "franquicia.ventas",
  "franquicia.caja",
  "franquicia.inventario",
  "franquicia.reposicion",
  "franquicia.precio_libre",
  "franquicia.descuento",
  "notificaciones.acceder",
  "notificaciones.publicar",
  "mantenimiento.acceder",
  "mantenimiento.editar",
];

export type Perfil = {
  id: string;
  nombre_completo: string;
  rol: RolUsuario;
  entidad_id: string | null;
  activo: boolean;
  permisos: PermisoCodigo[];
};

export function tienePermiso(
  perfil: Pick<Perfil, "rol" | "permisos">,
  permiso: PermisoCodigo
) {
  return perfil.rol === "admin" || perfil.permisos.includes(permiso);
}
