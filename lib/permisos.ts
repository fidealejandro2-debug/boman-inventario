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
  | "produccion.costos.ver"
  | "produccion.costos.editar"
  | "contratos.acceder"
  | "contratos.editar"
  | "contratos.marcar_etapa"
  | "contratos.finanzas.ver"
  | "contratos.finanzas.editar"
  | "contratos.entregar"
  | "contratos.revertir_entrega"
  | "clientes.acceder"
  | "clientes.editar"
  | "clientes.fusionar"
  | "contratos.cartera.ver"
  | "contratos.cartera.editar"
  | "reportes.comercial.ver"
  | "reportes.comercial.comisiones"
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
  | "importaciones.acceder"
  | "productos.crear";

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
  "produccion.costos.ver",
  "produccion.costos.editar",
  "contratos.acceder",
  "contratos.editar",
  "contratos.marcar_etapa",
  "contratos.finanzas.ver",
  "contratos.finanzas.editar",
  "contratos.entregar",
  "contratos.revertir_entrega",
  "clientes.acceder",
  "clientes.editar",
  "clientes.fusionar",
  "contratos.cartera.ver",
  "contratos.cartera.editar",
  "reportes.comercial.ver",
  "reportes.comercial.comisiones",
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
  "productos.crear",
];

export type Perfil = {
  id: string;
  nombre_completo: string;
  rol: RolUsuario;
  entidad_id: string | null;
  activo: boolean;
  permisos: PermisoCodigo[];
  // v107: si es false, oculta lo especifico de Boman Sport (contratos/
  // BomanSport, franquicias) incluso para admin -por eso Navbar.tsx lo
  // consulta directo, sin pasar por tienePermiso() (ver su propio bypass
  // de admin mas abajo).
  modo_boman_especifico: boolean;
};

export function tienePermiso(
  perfil: Pick<Perfil, "rol" | "permisos">,
  permiso: PermisoCodigo
) {
  return perfil.rol === "admin" || perfil.permisos.includes(permiso);
}
