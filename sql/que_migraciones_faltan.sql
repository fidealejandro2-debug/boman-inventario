-- Que migraciones faltan por correr en esta base.
-- Solo lee: no crea ni modifica nada. Pegalo en el SQL editor de Supabase.
-- Cada fila mira un objeto testigo de su migracion; si el testigo no existe,
-- la migracion no se corrio.
select v.orden,v.archivo,
 case when v.existe then 'YA ESTA' else '>>> FALTA CORRER' end as estado
from(values
 (107,'v107_permisos_persona_y_marca_blanca.sql',to_regclass('public.configuracion_sistema') is not null),
 (108,'v108_ingreso_contratos.sql',            to_regclass('public.contrato_ingresos_v108') is not null),
 (109,'v109_productos_franquicia.sql',         to_regclass('public.productos_creados_franquicia_v109') is not null),
 (110,'v110_capacidad_dia_produccion.sql',     to_regprocedure('public.capacidad_dia_produccion_v110(date,uuid)') is not null),
 (111,'v111_panel_vendedores.sql',             to_regclass('public.panel_vendedores_v111') is not null),
 (112,'v112_despachos_entregas_contratos.sql', to_regclass('public.contrato_entregas_v112') is not null),
 (113,'v113_ficha_integral_clientes.sql',      to_regclass('public.clientes_v113') is not null),
 (114,'v114_cuentas_por_cobrar_contratos.sql', to_regclass('public.contrato_cartera_v114') is not null),
 (115,'v115_consolidado_comercial.sql',        to_regprocedure('public.catalogo_ingreso_contrato_v115()') is not null)
)as v(orden,archivo,existe)
order by v.orden;
