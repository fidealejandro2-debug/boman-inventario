export type RolUsuario =
  | "admin"
  | "bodega"
  | "logistica"
  | "gerencia"
  | "tienda"
  | "control"
  | "nomina";

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
  | "nomina.editar";

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
