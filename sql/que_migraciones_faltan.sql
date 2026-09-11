-- Que migraciones faltan por correr en esta base.
-- Solo lee: no crea ni modifica nada. Pegalo en el SQL editor de Supabase.
-- Cada fila mira un objeto testigo de su migracion; si el testigo no existe,
-- la migracion no se corrio.
select v.orden,v.archivo,
 case when v.existe then 'YA ESTA' else '>>> FALTA CORRER' end as estado
from(values
 -- Estas cuatro son de antes pero varias migraciones nuevas dependen de ellas,
 -- asi que se vigilan igual: si falta una, lo de arriba falla sin explicar por que.
 (96, 'v96_cronograma_produccion.sql',           to_regclass('public.capacidad_produccion_diaria_v96') is not null),
 (99, 'v99_gestion_contratos.sql',               to_regprocedure('public.guardar_gestion_contrato_v99(uuid,jsonb,text,uuid)') is not null),
 (100,'v100_abonos_presupuesto_contratos.sql',   to_regprocedure('public.ajustar_finanzas_contrato_v100(uuid,numeric,numeric,text,uuid)') is not null),
 (102,'v102_sincronizacion_definitiva_bomansport.sql', to_regprocedure('public.tablero_produccion_v102()') is not null),
 (107,'v107_permisos_persona_y_marca_blanca.sql',to_regclass('public.configuracion_sistema') is not null),
 (108,'v108_ingreso_contratos.sql',            to_regclass('public.contrato_ingresos_v108') is not null),
 (109,'v109_productos_franquicia.sql',         to_regclass('public.productos_creados_franquicia_v109') is not null),
 (110,'v110_capacidad_dia_produccion.sql',     to_regprocedure('public.capacidad_dia_produccion_v110(date,uuid)') is not null),
 (111,'v111_panel_vendedores.sql',             to_regclass('public.panel_vendedores_v111') is not null),
 (112,'v112_despachos_entregas_contratos.sql', to_regclass('public.contrato_entregas_v112') is not null),
 (113,'v113_ficha_integral_clientes.sql',      to_regclass('public.clientes_v113') is not null),
 (114,'v114_cuentas_por_cobrar_contratos.sql', to_regclass('public.contrato_cartera_v114') is not null),
 (115,'v115_consolidado_comercial.sql',        to_regprocedure('public.catalogo_ingreso_contrato_v115()') is not null),
 (116,'v116_marcar_etapa_desde_vercel.sql',    to_regprocedure('public.marcar_etapa_contrato_v116(text,text,text,text,boolean,text,uuid)') is not null),
 (117,'v117_estaciones_produccion.sql',        to_regprocedure('public.estaciones_produccion_v117()') is not null),
 -- v118 reemplaza una funcion que ya existia desde v99, asi que el testigo no
 -- puede ser "que exista": es que acepte los campos comerciales nuevos.
 (118,'v118_gestion_datos_comerciales.sql',
   coalesce((select position('nombre_contrato_v115' in pg_get_functiondef(p.oid))>0
               from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='guardar_gestion_contrato_v99' limit 1),false)),
 -- v119 tambien reemplaza una funcion existente (la de v96): el testigo es que
 -- ya devuelva los contratos sin diseñador en vez de los mockups por aprobar.
 (119,'v119_cronograma_sin_disenador.sql',
   coalesce((select position('sin_disenador' in pg_get_functiondef(p.oid))>0
               from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='cronograma_produccion_v96' limit 1),false)),
 (120,'v120_editar_contenido_contrato.sql',      to_regprocedure('public.actualizar_contrato_v120(uuid,jsonb,text,uuid)') is not null),
 (121,'v121_subestaciones_tablero.sql',           to_regprocedure('public.columnas_tablero_v121()') is not null),
 -- v122 tambien reemplaza el tablero: el testigo es que ya devuelva el id del
 -- contrato, que es lo que permite editar en la fila.
 (122,'v122_tablero_editable.sql',
   coalesce((select position($$'id',a.id$$ in pg_get_functiondef(p.oid))>0
               from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='tablero_produccion_v102' limit 1),false)),
 (123,'v123_prendas_desde_tablero.sql',          to_regprocedure('public.editar_prendas_tablero_v123(uuid,jsonb,boolean,uuid)') is not null),
 -- v124 cambia la FIRMA del tablero: la version sin parametros se borra. Si
 -- sigue existiendo, la migracion no se corrio (o se corrio a medias).
 (124,'v124_tablero_entregados.sql',
   to_regprocedure('public.tablero_produccion_v102(boolean)') is not null
   and to_regprocedure('public.tablero_produccion_v102()') is null),
 (125,'v125_foto_y_detalle_tablero.sql',         to_regprocedure('public.agregar_archivo_contrato_v125(uuid,uuid,text,text,uuid)') is not null),
 (126,'v126_estacion_exteriores.sql',            to_regprocedure('public.es_contrato_exterior_v126(text)') is not null),
 (127,'v127_personal_diseno_nomina.sql',          to_regprocedure('public.asignar_personal_diseno_v127(uuid,text,uuid,text,uuid)') is not null),
 (128,'v128_colaboradores_diseno_externos.sql',   to_regclass('public.colaboradores_diseno_v128') is not null),
 (129,'v129_decimos_mensualizados_solo_afiliados.sql', to_regprocedure('public.normalizar_beneficios_rol_v129()') is not null),
 (130,'v130_paso1 + v130_paso2_rol_produccion.sql',
   exists (
     select 1
     from pg_enum e join pg_type t on t.oid=e.enumtypid
     join pg_namespace n on n.oid=t.typnamespace
     where n.nspname='public' and t.typname='rol_usuario' and e.enumlabel='produccion'
   )
   and exists (
     select 1 from public.rol_permisos rp
     where rp.rol::text='produccion' and rp.permiso_codigo='produccion.acceder'
       and rp.permitido
   )),
 (133,'v133_cheques_sin_factura.sql',           to_regprocedure('public.regularizar_cheque_v133(uuid,uuid,text,uuid)') is not null)
)as v(orden,archivo,existe)
order by v.orden;
