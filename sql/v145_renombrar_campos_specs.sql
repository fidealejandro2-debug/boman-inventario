-- ============================================================
-- v145 - Renombra ids de campos en contrato_specs.spec.campos
--
-- Auditoría completa: se comparó, prenda por prenda, cada campo que
-- Codigo.gs (BomanSport) realmente recolecta contra los ids que
-- specsPrendas.ts (Vercel) sabe imprimir. Aparecieron ids que no calzaban
-- con la forma real de los datos migrados (ver commit de specsPrendas.ts):
-- "botones" en vez de "cuello_botones_tiene", "punos" en vez de "puno",
-- "tipo" en vez de "bolsillos_tipo", etc.
--
-- Esa corrección arregla los contratos MIGRADOS de BomanSport sola (su
-- spec ya trae la forma anidada real de Codigo.gs; aplanarSpec la lee bien
-- en cuanto specsPrendas.ts busca el id correcto).
--
-- Pero un contrato creado DIRECTO en Vercel guarda spec como
-- {campos:{...}, observacion} usando como clave el id de specsPrendas.ts
-- TAL CUAL estaba en ese momento. Si ese id cambia de nombre, el valor ya
-- guardado queda huérfano bajo la clave vieja hasta que alguien reabra la
-- ficha y la vuelva a llenar -exactamente lo que "que no se salte o altere
-- campos" pide evitar. Esta migración renombra esas claves donde existan,
-- por prenda, sin tocar los contratos migrados (que no tienen 'campos').
-- ============================================================

begin;

do $migrar_specs$
declare
  r record;
  v_afectadas integer := 0;
  v_total integer := 0;
  -- (prenda_clave, clave_vieja, clave_nueva)
  v_renombres text[][] := array[
    array['camiseta',     'botones',    'cuello_botones_tiene'],
    array['camisetaPolo', 'botones',    'cuello_botones_tiene'],
    array['chompa',       'tipo',       'bolsillos_tipo'],
    array['chompa',       'velcro',     'velcro_tiene'],
    array['chompa',       'basta',      'ruedo'],
    array['retro',        'punos',      'puno'],
    array['deportiva',    'punos',      'puno'],
    array['pantalon',     'punos',      'puno'],
    array['bermuda',      'tipo',       'bolsillos_tipo'],
    array['faldaShort',   'tipo',       'bolsillos_tipo'],
    array['licra',        'punos',      'puno_tipo'],
    array['licra',        'basta_tipo', 'basta']
  ];
  v_fila text[];
begin
  foreach v_fila slice 1 in array v_renombres loop
    update public.contrato_specs
    set spec = jsonb_set(
      spec #- array['campos', v_fila[2]],
      array['campos', v_fila[3]],
      spec->'campos'->v_fila[2]
    )
    where prenda_clave = v_fila[1]
      and spec ? 'campos'
      and spec->'campos' ? v_fila[2]
      and not (spec->'campos' ? v_fila[3]);
    get diagnostics v_afectadas = row_count;
    v_total := v_total + v_afectadas;
    if v_afectadas > 0 then
      raise notice '%: % -> % (% fila(s))', v_fila[1], v_fila[2], v_fila[3], v_afectadas;
    end if;
  end loop;
  raise notice 'Total de filas renombradas: %', v_total;
end;
$migrar_specs$;

insert into public.schema_migrations_boman(id,version,archivo,notas)
values('v145','145','v145_renombrar_campos_specs.sql',
  'Renombra ids huérfanos en contrato_specs.spec.campos para contratos nativos de Vercel (camiseta/chompa/retro/deportiva/pantalon/bermuda/faldaShort/licra)')
on conflict(id) do update set version=excluded.version,archivo=excluded.archivo,
  notas=excluded.notas,aplicada_at=now();

commit;
