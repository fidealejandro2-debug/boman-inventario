-- Verificacion v146. Solo lectura; ejecutar despues de la migracion.
select exists(
  select 1 from public.permisos_sistema
  where codigo='gerencia.acceder' and activo
) as permiso_panel_ok;

select permiso_codigo,permitido
from public.rol_permisos
where rol::text='gerencia' and permiso_codigo in(
  'gerencia.acceder','reportes.acceder','reportes.comercial.ver',
  'produccion.costos.ver','contratos.acceder','contratos.finanzas.ver',
  'contratos.cartera.ver','franquicia.consolidado'
)
order by permiso_codigo;
