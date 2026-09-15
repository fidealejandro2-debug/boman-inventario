-- Debe devolver todo en true/0 despues de instalar los dos pasos de v152.
select
  exists(select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid
    where t.typname='rol_usuario' and e.enumlabel='supervisor') rol_supervisor_ok,
  exists(select 1 from public.permisos_sistema
    where codigo='supervision.acceder' and activo) permiso_ok,
  to_regprocedure('public.panel_supervision_v152(date,date,uuid)') is not null rpc_ok,
  exists(select 1 from public.rol_permisos
    where rol::text='supervisor' and permiso_codigo='supervision.acceder' and permitido) acceso_ok,
  exists(select 1 from public.schema_migrations_boman where id='v152') registro_ok;

select count(*) pendientes_matriz
from public.permisos_sistema p
where p.activo and not exists(
  select 1 from public.rol_permisos rp
  where rp.rol::text='supervisor' and rp.permiso_codigo=p.codigo
);
