-- ============================================================
-- Verificacion v117 - Estaciones de produccion
-- Solo lectura. Ejecutar despues de instalar v117.
-- ============================================================

-- 1) Las funciones nuevas existen.
select
  to_regprocedure('public.estaciones_produccion_v117()') is not null as catalogo_ok,
  to_regprocedure('public.area_etapa_v117(text)') is not null as mapa_ok,
  to_regprocedure('public.estaciones_usuario_actual_v117()') is not null as mias_ok,
  to_regprocedure('public.es_operario_estacion_v117()') is not null as encierro_ok,
  to_regprocedure('public.puede_marcar_area_v117(text)') is not null as area_ok,
  to_regprocedure('public.admin_asignar_estaciones_v117(uuid,text[])') is not null as asignar_ok;

-- 2) La columna existe y arranca vacia para todos.
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='perfiles' and column_name='estaciones') = 1 as columna_ok,
  (select count(*) from public.perfiles where coalesce(array_length(estaciones,1),0) > 0) as cuentas_de_estacion;

-- 3) Ninguna cuenta admin quedo encerrada (debe ser cero SIEMPRE).
select count(*) as admins_encerrados
  from public.perfiles
 where rol::text = 'admin' and coalesce(array_length(estaciones,1),0) > 0;

-- 4) Cada etapa tiene su estacion. 'Ingresado' debe salir vacia (la pone
--    ventas, no el taller); ninguna otra puede salir vacia.
select e as etapa, public.area_etapa_v117(e) as estacion
  from unnest(array['Ingresado','Por imprimir','Impreso','Sublimación','Cortado',
                    'En costura o maquila','Estampado','Terminado','Estampado final',
                    'Pendiente entrega','Entregado']) as e;

-- 5) Toda estacion del mapa esta en el catalogo (si no, seria imposible
--    asignarla y la etapa quedaria sin dueno posible).
select a.estacion, a.estacion = any(public.estaciones_produccion_v117()) as en_catalogo
  from (select distinct public.area_etapa_v117(e) as estacion
          from unnest(array['Por imprimir','Impreso','Sublimación','Cortado',
                            'En costura o maquila','Estampado','Terminado',
                            'Estampado final','Pendiente entrega','Entregado']) as e) a
 order by a.estacion;

-- 6) El tablero ya no devuelve areas vacias. Antes de v117 todas salian ''.
--    (Requiere sesion con permiso de produccion; desde el editor de Supabase
--    puede fallar por auth.uid() nulo, eso es esperado.)
select x->>'nombre' as etapa, x->>'area' as area
  from jsonb_array_elements((public.tablero_produccion_v102())->'etapas') x;

-- 7) El permiso existe y NO se hereda de ningun rol.
select
  (select count(*) from public.permisos_sistema where codigo='produccion.estacion' and activo) = 1 as permiso_ok,
  (select count(*) from public.rol_permisos where permiso_codigo='produccion.estacion' and permitido) = 0 as sin_herencia_ok;

-- 8) Privilegios: authenticated si, anon no.
select
  has_function_privilege('authenticated','public.admin_asignar_estaciones_v117(uuid,text[])','execute') as auth_ok,
  not has_function_privilege('anon','public.admin_asignar_estaciones_v117(uuid,text[])','execute') as anon_bloqueado_ok,
  not has_function_privilege('anon','public.estaciones_usuario_actual_v117()','execute') as anon_mias_bloqueado_ok;

-- 9) Marcas historicas por area. Sirve para confirmar que los nombres de
--    estacion que llegan de la hoja coinciden con el catalogo: las que salgan
--    fuera de el son sub-etapas ("Sellos · TPU") o areas viejas.
select area, count(*) as marcas,
       split_part(area,' · ',1) = any(public.estaciones_produccion_v117()) as area_conocida
  from public.contrato_etapas
 group by area
 order by marcas desc
 limit 20;
