-- ============================================================
-- Verificacion v91 - Codigos de barras y QR
-- Solo lectura. Ejecutar despues de instalar v91.
-- ============================================================

select
  to_regclass('public.producto_codigos_v91') is not null as codigos_ok,
  to_regclass('public.producto_codigo_eventos_v91') is not null as auditoria_ok,
  to_regclass('public.vista_codigos_productos_v91') is not null as vista_ok;

select
  to_regprocedure('public.validar_gtin_v91(text,integer)') is not null as validar_gtin_ok,
  to_regprocedure('public.resolver_codigo_producto_v91(text)') is not null as resolver_ok,
  to_regprocedure('public.guardar_codigo_producto_v91(uuid,uuid,text,text,text,boolean,text,uuid)') is not null as guardar_ok,
  to_regprocedure('public.archivar_codigo_producto_v91(uuid,text,uuid)') is not null as archivar_ok;

select
  has_function_privilege('authenticated', 'public.resolver_codigo_producto_v91(text)', 'execute') as resolver_authenticated_ok,
  not has_function_privilege('anon', 'public.resolver_codigo_producto_v91(text)', 'execute') as resolver_anon_bloqueado_ok,
  not has_table_privilege('authenticated', 'public.producto_codigos_v91', 'insert') as insercion_directa_bloqueada_ok,
  not has_table_privilege('authenticated', 'public.producto_codigos_v91', 'update') as edicion_directa_bloqueada_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in ('producto_codigos_v91', 'producto_codigo_eventos_v91')
order by tablename;

-- Todos deben ser cero.
select count(*) as productos_sin_qr_interno_debe_ser_cero
from public.productos p
where not exists (
  select 1 from public.producto_codigos_v91 c
  where c.producto_id = p.id and c.activo and c.tipo = 'qr'
    and c.codigo = 'BOMAN:P:' || p.id::text
);

select count(*) as codigos_activos_duplicados_debe_ser_cero
from (
  select codigo_normalizado from public.producto_codigos_v91 where activo
  group by codigo_normalizado having count(*) > 1
) duplicados;

select count(*) as principales_duplicados_debe_ser_cero
from (
  select producto_id from public.producto_codigos_v91 where activo and principal
  group by producto_id having count(*) > 1
) duplicados;

select count(*) as codigos_huerfanos_debe_ser_cero
from public.producto_codigos_v91 c
left join public.productos p on p.id = c.producto_id
where p.id is null;

select count(*) as codigos_que_colisionan_con_sku_debe_ser_cero
from public.producto_codigos_v91 c
join public.productos p on
  upper(regexp_replace(btrim(p.sku), '[[:space:]]+', '', 'g')) = c.codigo_normalizado
where c.activo;

select count(*) as gtin_invalidos_debe_ser_cero
from public.producto_codigos_v91
where activo and (
  (tipo = 'ean13' and not public.validar_gtin_v91(codigo, 13))
  or (tipo = 'upca' and not public.validar_gtin_v91(codigo, 12))
);

select count(*) as eventos_sin_control_debe_ser_cero
from public.producto_codigo_eventos_v91
where usuario_id is null or idempotency_key is null or btrim(motivo) = '';

select tipo, count(*) as codigos_activos
from public.producto_codigos_v91 where activo
group by tipo order by tipo;
