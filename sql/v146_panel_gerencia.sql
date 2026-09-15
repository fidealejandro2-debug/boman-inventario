-- ============================================================
-- v146 - Acceso al panel de Gerencia
--
-- Gerencia recibe lectura de las vistas ejecutivas existentes. No concede
-- permisos de edicion ni cambia los controles de cada modulo de detalle.
-- ============================================================

begin;

insert into public.permisos_sistema as p(
  codigo, modulo, nombre, descripcion, orden, es_boman_especifico
) values (
  'gerencia.acceder', 'Gerencia', 'Panel ejecutivo',
  'Consolida indicadores, alertas y accesos a los reportes gerenciales.',
  5, false
)
on conflict(codigo) do update set
  modulo=excluded.modulo, nombre=excluded.nombre,
  descripcion=excluded.descripcion, orden=excluded.orden,
  activo=true, es_boman_especifico=false, updated_at=now();

insert into public.rol_permisos(rol,permiso_codigo,permitido)
select r.rol,p.codigo,false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text<>'admin' and p.codigo='gerencia.acceder'
on conflict(rol,permiso_codigo) do nothing;

update public.rol_permisos set permitido=true,updated_at=now()
where rol::text='gerencia' and permiso_codigo in (
  'gerencia.acceder',
  'reportes.acceder',
  'reportes.comercial.ver',
  'produccion.costos.ver',
  'contratos.acceder',
  'contratos.finanzas.ver',
  'contratos.cartera.ver',
  'franquicia.consolidado'
);

insert into public.schema_migrations_boman(id,version,archivo,notas)
values('v146','146','v146_panel_gerencia.sql',
  'Panel ejecutivo y permisos de lectura gerencial')
on conflict(id) do update set version=excluded.version,archivo=excluded.archivo,
  notas=excluded.notas,aplicada_at=now();

commit;
notify pgrst,'reload schema';
