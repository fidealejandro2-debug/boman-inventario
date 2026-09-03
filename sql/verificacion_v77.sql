-- ============================================================
-- Verificacion v77 - Licencias por activo
-- Solo lectura: ejecutar despues de instalar v77.
-- ============================================================

select
  to_regclass('public.activo_licencias') is not null as tabla_ok,
  to_regclass('public.vista_licencias_activos_v77') is not null as vista_ok,
  to_regprocedure('public.guardar_licencia_activo_v77(uuid,uuid,jsonb,text,uuid)') is not null as guardar_ok,
  to_regprocedure('public.renovar_licencia_activo_v77(uuid,date,jsonb,text,uuid)') is not null as renovar_ok,
  to_regprocedure('public.cancelar_licencia_activo_v77(uuid,text,uuid)') is not null as cancelar_ok,
  to_regprocedure('public.sincronizar_alertas_licencias_v77()') is not null as alertas_ok;

-- Los eventos de mantenimiento deben admitir 'licencia'; sin esto la auditoria
-- de cualquier licencia viola el check.
select pg_get_constraintdef(c.oid) like '%licencia%' as evento_admite_licencia
from pg_constraint c
where c.conrelid = 'public.mantenimiento_eventos'::regclass
  and c.conname = 'mantenimiento_eventos_entidad_tipo_check';

-- RLS encendida y sin escritura directa: todo pasa por los RPC.
select rowsecurity from pg_tables
where schemaname = 'public' and tablename = 'activo_licencias';

select
  not has_table_privilege('authenticated', 'public.activo_licencias', 'insert') as insert_bloqueado,
  not has_table_privilege('authenticated', 'public.activo_licencias', 'update') as update_bloqueado,
  has_table_privilege('authenticated', 'public.activo_licencias', 'select') as lectura_ok;

-- Integridad de la cadena de renovaciones: una licencia no puede tener dos
-- renovaciones, y toda renovacion apunta a una del mismo activo.
select count(*) as renovaciones_de_otro_activo_debe_ser_cero
from public.activo_licencias h
join public.activo_licencias p on p.id = h.renovacion_de_id
where h.activo_id <> p.activo_id;

select count(*) as vigentes_ya_renovadas_debe_ser_cero
from public.activo_licencias p
join public.activo_licencias h on h.renovacion_de_id = p.id
where p.estado = 'vigente';

-- Estado de las licencias vigentes, ordenadas por urgencia.
select activo_codigo, nombre, tipo, proveedor,
       fecha_vencimiento, dias_restantes, estado_vencimiento, costo_renovacion
from public.vista_licencias_activos_v77
where estado = 'vigente'
order by dias_restantes;

-- Avisos publicados por el sincronizador.
select origen_clave, nivel, titulo, activo
from public.notificaciones_comunicados
where origen_tipo = 'mantenimiento_licencia'
order by nivel desc, titulo;
