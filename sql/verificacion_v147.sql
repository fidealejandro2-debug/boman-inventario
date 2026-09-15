-- Ejecutar despues de los dos pasos de v147.
select
 exists(select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid where t.typname='rol_usuario'and e.enumlabel='vendedor')as rol_vendedor_ok,
 exists(select 1 from public.permisos_sistema where codigo='contratos.abonos.registrar'and activo)as permiso_abonos_ok,
 to_regprocedure('public.crear_contrato_v147(jsonb,uuid)')is not null as ingreso_vinculado_ok,
 to_regprocedure('public.registrar_abono_contrato_v147(uuid,date,numeric,text,text,text,text,uuid)')is not null as abono_caja_ok,
 to_regprocedure('public.anular_abono_contrato_v147(uuid,text,uuid)')is not null as reversa_caja_ok;

select
 count(*)filter(where c.vendedor_perfil_id is not null)as contratos_vinculados,
 count(*)filter(where c.vendedor_perfil_id is null)as contratos_historicos_por_revisar
from public.contratos c;

select count(*)as abonos_nuevos_sin_caja_debe_ser_cero
from public.contrato_abonos_v100 a
left join public.franquicia_caja_movimientos m on m.contrato_abono_id=a.id
where a.estado='aplicado'
  and a.created_at>=(select aplicada_at from public.schema_migrations_boman where id='v147')
  and m.id is null;
