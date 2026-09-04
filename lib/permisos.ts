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
  | "tesoreria.acceder"
  | "tesoreria.editar"
  | "produccion.acceder"
  | "produccion.calidad.registrar"
  | "produccion.calidad.resolver"
  | "produccion.calidad.descuento"
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
  | "franquicia.consolidado"
  | "franquicia.turnos"
  | "franquicia.cobros"
  | "franquicia.devoluciones"
  | "notificaciones.acceder"
  | "notificaciones.publicar"
  | "mantenimiento.acceder"
  | "mantenimiento.editar"
  | "importaciones.acceder";

export const TODOS_LOS_PERMISOS: PermisoCodigo[] = [
  "inventario.acceder",
  "operaciones.acceder",
  "conteos.acceder",
  "movimientos.acceder",
  "ventas.acceder",
  "compras.acceder",
  "tesoreria.acceder",
  "tesoreria.editar",
  "produccion.acceder",
  "produccion.calidad.registrar",
  "produccion.calidad.resolver",
  "produccion.calidad.descuento",
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
  "franquicia.consolidado",
  "franquicia.turnos",
  "franquicia.cobros",
  "franquicia.devoluciones",
  "notificaciones.acceder",
  "notificaciones.publicar",
  "mantenimiento.acceder",
  "mantenimiento.editar",
  "importaciones.acceder",
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
