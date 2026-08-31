# Plan · Control de nómina multi-RUC (v26 → v36)

Documento de trabajo compartido entre Fidel, Codex y Claude.
**Ningún SQL de nómina está escrito todavía.** Esto define el modelo acordado para que
quien tome cada fase no reinvente el diseño ni choque con la numeración de producción.

Última actualización: 2026-08-30.

---

## Reserva de numeración

Producción (Codex) ocupa hasta **v25**. Nómina y administración reservan **v26 a v36**.
Quien necesite una migración fuera de este bloque antes de que se cierre v36, la toma
desde **v37** y lo anota aquí. No se reutiliza ni se renumera nada ya ejecutado.

> El rango creció hasta v36: v32 pasó a ser la trazabilidad para el SGC, v33 el
> reingreso de personal, v34 el catálogo de departamentos, v35 la matriz de permisos
> por rol y las extensiones (IR, finiquitos) se corrieron a v36.

---

## Qué resuelve

El grupo tiene personal repartido en tres RUC, personal **no afiliado**, y sueldos
afiliados menores al que realmente se paga. Hoy nada de eso vive en un solo lugar, así
que no se conoce el costo real de personal por empresa.

El sistema emite **dos roles sobre los mismos datos**:

| | Rol real | Rol declarado |
|---|---|---|
| Qué muestra | Lo que la persona efectivamente cobra | Lo que consta ante el IESS |
| Base de cálculo | `sueldo_real` | `sueldo_declarado` |
| Cubre a | Todo el personal, afiliado o no | Solo afiliados |
| Uso | Costo real, gestión interna | Planilla y reportes IESS |

**Alcance.** Es control interno de gestión. No corrige ni sustituye el reporte legal.
La brecha entre real y declarado el sistema la **hace visible**, no la administra.
Lo único que sale hacia el IESS es el rol declarado.

---

## Reglas de negocio acordadas

1. **El empleado no tiene empresa fija.** Existe una sola vez en el grupo. Su vínculo con
   un RUC vive en tablas historizadas aparte.

2. **Al no afiliado también se le emite rol.** Entra en `nomina_rol_lineas` con
   `afiliado = false`, `sueldo_declarado = 0` y todas las columnas del bloque declarado en
   cero. Su rol real se calcula igual que el de cualquiera. No aparece en la planilla IESS.

3. **La empresa pagadora se elige.** Hoy en la práctica casi todo sale de una persona
   natural, pero eso puede cambiar por persona y por mes. Se define un default en
   `empleado_compensacion.empresa_pagadora_id` y se permite **override por línea de rol**.
   La pagadora puede ser cualquier empresa registrada en `empresas` (v18), y **puede
   diferir del RUC que afilia**.

4. **Hay dos fechas de inicio y no significan lo mismo.**
   - `empleados.fecha_ingreso_real` — inicio efectivo de la relación laboral.
   - `empleado_afiliaciones.fecha_afiliacion` — fecha del aviso de entrada al IESS.

   | Cálculo | Fecha que manda |
   |---|---|
   | Vacaciones, décimos, antigüedad, finiquito | `fecha_ingreso_real` |
   | Fondos de reserva (desde el mes 13), historia IESS | `fecha_afiliacion` |

   La diferencia en días entre ambas se reporta por empleado: es parte de la brecha.

5. **El rol congela un snapshot.** Al abrir el período se copian empresa afiliadora,
   sueldo declarado, empresa pagadora y sueldo real dentro de la línea. Cambiar un sueldo
   hoy no puede alterar un rol de marzo. Con más de 100 personas esto no es opcional.

6. **Período cerrado es inmutable.** Corrección = nota de ajuste en un período nuevo,
   nunca edición del cerrado.

7. **La gente vuelve.** Hay personal que deja de venir un par de meses y luego se
   reincorpora. Si nunca se liquidó es una ausencia (v27) y la antigüedad sigue corriendo;
   si hubo finiquito es una relación nueva y la antigüedad se reinicia. La persona sigue
   siendo **la misma fila** en `empleados` en los dos casos: su expediente, su historial
   disciplinario y su historial de sueldos no se parten nunca. Lo resuelve v33.

---

## Convenciones (las mismas del resto del proyecto)

- Un archivo `sql/vN_descripcion.sql` + su `sql/verificacion_vN.sql`.
  Cabecera indicando *"Ejecutar una sola vez DESPUÉS de vN-1"*.
- RPCs `security definer set search_path = public`, nombre terminado en `_vN`.
- Toda RPC que muta recibe `p_idempotency_key` (patrón de Compras v21).
- RLS en cada tabla. Tabla de eventos por módulo para auditoría (patrón v18 / v25).
- Todo en español: tablas, columnas, mensajes de error de Postgres, UI.
- Nunca editar un SQL ya ejecutado.

### Acceso — más estricto que el resto del ERP

Se agrega el valor `nomina` a `rol_usuario`:

```sql
alter type public.rol_usuario add value if not exists 'nomina';
-- ejecutar en transacción separada antes de usarlo (mismo caso que v21)
```

Solo `admin`, `gerencia` y `nomina` leen o escriben estas tablas. Ninguna vista general
del ERP debe tocarlas. Cédulas, sueldos reales y la brecha por persona son el dato más
sensible del sistema — el acceso queda registrado en `nomina_eventos`.

---

## v26 · Personal y expediente

```
empleados
  id, grupo_id, cedula (unique), nombres, apellidos, fecha_nacimiento,
  estado_civil, direccion, telefono, email,
  contacto_emergencia_nombre, contacto_emergencia_telefono,
  fecha_ingreso_real, fecha_salida, cargo, area,
  tipo_contrato (indefinido|eventual|ocasional|servicios_profesionales|aprendizaje),
  estado (activo|inactivo|liquidado),
  forma_pago, banco, tipo_cuenta, numero_cuenta
  -- SIN empresa_id

empleado_afiliaciones                          -- historizada
  empleado_id, empresa_id (FK empresas, nullable), afiliado bool,
  fecha_afiliacion, sueldo_declarado,
  fecha_desde, fecha_hasta, motivo, registrado_por
  -- unique parcial: una sola vigente por empleado (fecha_hasta is null)
  -- check: afiliado = false ⇒ empresa_id null, fecha_afiliacion null, sueldo_declarado 0

empleado_compensacion                          -- historizada
  empleado_id, empresa_pagadora_id (FK empresas), sueldo_real,
  fecha_desde, fecha_hasta, motivo, registrado_por
  -- unique parcial: una sola vigente por empleado
  -- empresa_pagadora_id puede diferir de la afiliadora

empleado_documentos                            -- expediente digital
  empleado_id, tipo (hoja_vida|cedula|papeleta_votacion|contrato|adendum|
    titulo|certificado_laboral|certificado_medico|antecedentes|firma|foto|
    aviso_entrada_iess|acta_finiquito|otro),
  nombre, storage_path, mime, tamano_bytes,
  fecha_emision, fecha_caducidad, subido_por, created_at, activo

nomina_parametros                              -- por año, nunca en el código
  anio, salario_basico_unificado,
  pct_aporte_personal, pct_aporte_patronal, pct_fondos_reserva,
  pct_iece, pct_secap, horas_jornada_semanal,
  tope_multa_pct, tope_descuento_total_pct

nomina_eventos                                 -- auditoría transversal del módulo
```

**Almacenamiento de documentos.** Bucket **privado** `expedientes` en Supabase Storage,
path `empleados/{empleado_id}/{documento_id}.{ext}`. Política de acceso por el mismo rol.
Nunca público, nunca URL firmada de larga duración.

`fecha_caducidad` alimenta alertas: exámenes médicos, licencias, contratos eventuales.
`tipo = 'firma'` guarda el PNG recortado que se estampa en roles y llamados impresos.

**RPCs:** `guardar_empleado_v26`, `registrar_afiliacion_v26` (cierra la vigente y abre la
nueva), `registrar_compensacion_v26`, `registrar_documento_empleado_v26`.

---

## v27 · Ausencias y vacaciones

```
feriados
  anio, fecha, nombre, tipo (nacional|local), almacen_id nullable

vacaciones_periodos                            -- uno por aniversario de ingreso real
  empleado_id, periodo_desde, periodo_hasta, anos_servicio,
  dias_derecho, dias_tomados, dias_pagados, dias_saldo (generated),
  estado (abierto|agotado|liquidado|caducado)

ausencias
  empleado_id, tipo (vacaciones|enfermedad_iess|enfermedad_particular|
    permiso_con_sueldo|permiso_sin_sueldo|maternidad|paternidad|lactancia|
    calamidad_domestica|falta_injustificada|suspension_disciplinaria),
  fecha_desde, fecha_hasta, horas,
  dias_calendario, dias_habiles,
  vacaciones_periodo_id nullable,
  documento_respaldo_id (FK empleado_documentos),
  solicitado_por, aprobado_por, aprobado_at,
  estado (solicitada|aprobada|rechazada|anulada), observacion
```

- Derecho a vacaciones: 15 días desde el primer año; +1 día por año desde el sexto,
  tope 30 (Art. 69 CT). Acumulables hasta tres períodos (Art. 75 CT).
- El período se genera contra `fecha_ingreso_real`, no contra la afiliación.
- `tipo = 'vacaciones'` descuenta de `vacaciones_periodos`, **FIFO** por el período más
  antiguo abierto.
- `falta_injustificada` y `permiso_sin_sueldo` descuentan días en el rol.
- `dias_habiles` se calcula contra `feriados`; sin la tabla cargada el cálculo miente.

**Implementación v27.** `feriados_anios` confirma que el calendario de cada año está
completo antes de calcular días hábiles. Una ausencia de vacaciones puede consumir más
de un período; `ausencia_vacaciones_aplicaciones` conserva ese reparto FIFO y su reversa
sin borrar historia. Los días de vacaciones se descuentan como días calendario
ininterrumpidos; `dias_habiles` queda como dato separado de asistencia.

---

## v28 · Novedades disciplinarias

```
novedades_empleado
  empleado_id, empresa_id (bajo qué RUC se emite),
  numero (correlativo por empresa y año),
  tipo (llamado_atencion|amonestacion_escrita|memorando|acta_compromiso|
    felicitacion|sancion_economica|solicitud_visto_bueno),
  fecha, asunto, hechos,
  base_reglamento, base_legal,
  descargo_empleado, resolucion,
  emitido_por, aprobado_por,
  estado (borrador|emitida|notificada|con_descargo|archivada),
  notificado_at, forma_notificacion (fisica|correo|testigos),
  firma_empleado_doc_id, documento_pdf_id,
  genera_descuento bool, monto_descuento, descuento_id

novedad_eventos
```

- El correlativo por empresa+año hace verificable el documento impreso.
- La impresión arma: datos del empleado, RUC que emite, hechos, base legal invocada,
  espacio de descargo y firma. El PDF generado se guarda en el expediente.
- Consulta de acumulación: novedades por empleado en ventana móvil de días. El sistema
  **muestra** el conteo (relevante para visto bueno, Art. 172 CT); no decide por sí solo.
- Multa: tope en `nomina_parametros.tope_multa_pct`. Solo procede si está prevista en el
  reglamento interno aprobado por el MDT — el Art. 44 lit. b) CT prohíbe multas no
  previstas en él. Si `genera_descuento`, se crea la fila en `descuentos_programados`.

---

## v29 · Anticipos y descuentos

```
anticipos
  empleado_id, empresa_pagadora_id, fecha, monto, motivo, cuotas,
  solicitado_por, aprobado_por,
  estado (solicitado|aprobado|rechazado|desembolsado|anulado),
  desembolsado_at, forma_desembolso

descuentos_programados                         -- motor único de egresos recurrentes
  empleado_id, origen (anticipo|prestamo_iess|prestamo_quirografario|
    prestamo_hipotecario|prestamo_empresa|multa|judicial|uniforme|
    consumo_interno|otro),
  origen_id, descripcion,
  monto_total, cuotas_total, cuotas_pagadas, monto_cuota, saldo (generated),
  fecha_inicio, fecha_fin, documento_respaldo_id,
  estado (vigente|pagado|suspendido|condonado),
  prioridad
```

Al calcular el rol se leen las cuotas vigentes del período. Si la suma supera
`tope_descuento_total_pct`, se aplican por `prioridad` — retención judicial y pensiones
alimenticias primero, siempre — y el resto se difiere al período siguiente.
**Nunca se fuerza un neto negativo.**

**Coordinación v28/v29.** V28 conserva la sanción económica aprobada y su evidencia,
pero no crea anticipadamente tablas de V29. V29 agrega la relación con
`descuentos_programados` y el RPC auditado para convertir una sanción emitida en un
descuento. Así las migraciones siguen siendo ejecutables estrictamente en orden.

Lo que v28 dejó listo y v29 tiene que enganchar:

- `novedades_empleado.descuento_id uuid` existe **sin clave foránea**. v29 la agrega:
  ```sql
  alter table public.novedades_empleado
    add constraint novedades_empleado_descuento_id_fkey
    foreign key (descuento_id) references public.descuentos_programados(id)
    on delete restrict;
  ```
- `vista_multas_pendientes_v28` ya lista las multas notificadas o archivadas que
  todavía no tienen descuento. Es la cola de entrada del RPC de v29.
- La multa ya viene validada contra el tope: `tope_multa_empleado_v28(empleado, fecha)`
  aplica `nomina_parametros.tope_multa_pct` sobre la **remuneración mensual**, usando el
  sueldo real y cayendo al declarado si no hay compensación vigente. v29 no necesita
  revalidarlo, pero sí debe respetar `tope_descuento_total_pct` al sumar todas las cuotas.
- `anular_novedad_v28` **se niega a anular** una novedad que ya tenga `descuento_id`.
  v29 debe ofrecer la reversión del descuento primero, y dejarlo en `null` al revertir.
- Ampliar el check de `nomina_eventos.entidad` con los valores nuevos, como hicieron v27
  y v28 (v28 lo dejó en: empleado, afiliacion, compensacion, documento, parametros,
  calendario_feriados, periodos_vacaciones, ausencia, novedad).
- `tope_multa_empleado_v28` y `contar_novedades_v28` **no son** `security definer`, a
  propósito: si lo fueran, un usuario sin acceso a nómina deduciría el sueldo real
  dividiendo el tope por el porcentaje. Mantén ese criterio en las funciones de consulta
  de v29.

---

## v30 · Períodos y cálculo

```
nomina_periodos
  grupo_id, anio, mes, estado (abierto|calculado|cerrado),
  generado_por, calculado_at, cerrado_por, cerrado_at

nomina_rol_lineas                              -- snapshot congelado
  periodo_id, empleado_id,

  -- identidad congelada
  empresa_afiliacion_id, afiliado, fecha_afiliacion, sueldo_declarado,
  empresa_pagadora_id, sueldo_real, cargo, area, fecha_ingreso_real,

  -- asistencia
  dias_periodo, dias_laborados, dias_vacaciones,
  dias_ausencia_con_sueldo, dias_ausencia_sin_sueldo,
  horas_extra_50, horas_extra_100,

  -- ingresos
  sueldo_proporcional_real, sueldo_proporcional_declarado,
  valor_horas_extra, comisiones, bonos, vacaciones_pagadas,
  decimo_tercero_mensualizado, decimo_cuarto_mensualizado,
  fondos_reserva_pagados, otros_ingresos,

  -- egresos
  aporte_personal, anticipos_cuota, multas,
  prestamos_iess, prestamos_empresa, retencion_judicial, otros_descuentos,

  -- costo patronal (no se descuenta al trabajador)
  aporte_patronal, provision_decimo_tercero, provision_decimo_cuarto,
  provision_vacaciones, provision_fondos_reserva,

  -- resultados
  total_ingresos_real, total_ingresos_declarado, total_egresos,
  neto_real, neto_declarado, brecha (generated),
  costo_empleador_real, costo_empleador_declarado

nomina_rubros / nomina_rol_rubros
  -- detalle de lo variable, para que el rol impreso muestre
  -- "Anticipo 15/03 — cuota 2 de 3 — $50,00"
```

**RPCs:** `abrir_periodo_nomina_v30` (crea el período y genera una línea por empleado
activo con el snapshot), `calcular_rol_v30` (aplica las fórmulas del año),
`cerrar_periodo_nomina_v30` (lo vuelve inmutable).

### Fórmulas — todas leídas de `nomina_parametros` del año del período

| Concepto | Base | Tasa |
|---|---|---|
| Aporte personal IESS | sueldo declarado | 9,45 % |
| Aporte patronal IESS | sueldo declarado | 11,15 % |
| Fondos de reserva | sueldo declarado | 8,33 % — desde el mes 13 contado sobre `fecha_afiliacion` |
| Décimo tercero | ingresos del mes | 8,33 % (1/12) |
| Décimo cuarto | SBU del año | SBU/12 — monto fijo, no proporcional al sueldo |
| Vacaciones | ingresos del mes | 4,17 % (1/24) |
| Hora suplementaria | valor hora | +50 % |
| Hora extraordinaria | valor hora | +100 % |

El bloque declarado se calcula solo si `afiliado = true`; en caso contrario queda en cero
y la línea reporta únicamente el rol real.

Impuesto a la renta en relación de dependencia **no entra en v30**: requiere proyección
anual, gastos personales y liquidación en enero. Va en v32.

---

## v31 · Reportes e interfaz

Vistas: `vista_rol_real`, `vista_rol_declarado`, `vista_brecha_nomina`,
`vista_costo_empleador_por_empresa`, `vista_pagos_por_empresa_pagadora`.

Módulo `app/nomina/` con secciones **Empleados · Expediente · Ausencias · Novedades ·
Roles · Parámetros · Reportes**, visible solo para `admin`, `gerencia` y `nomina`.

Impresiones: rol individual real y declarado · planilla consolidada por RUC · llamado de
atención y memorando · solicitud y aprobación de vacaciones · comprobante de anticipo ·
certificado laboral · ficha completa con historial.

---

## v32 · Trazabilidad de cambios (SGC)

Auditoría de campo por **trigger** sobre `empleados`, `empleado_compensacion`,
`empleado_afiliaciones` y `nomina_parametros` → tabla `nomina_cambios` con tabla,
registro, campo, valor anterior, valor nuevo, autor, rol de base y motivo. La escribe el
trigger y no la aplicación: un evento que hay que acordarse de registrar se olvida, y un
cambio hecho directo contra la base tampoco quedaría rastreado. La bitácora es de solo
lectura incluso para la app.

Cierra los huecos que dejaba v26:

| Hueco | Cómo queda |
|---|---|
| Cambio de cuenta bancaria y de cédula sin rastro | El trigger guarda el valor anterior; la UI los marca como sensibles y alerta |
| `nomina_parametros` sobrescribible en años ya liquidados | Congelados al cerrar el primer rol del año |
| `motivo` en texto libre | `motivo_tipo` tipificado en compensación y afiliación |
| Sin respaldo documental | `documento_respaldo_id` en ambas series |
| Reducción de sueldo como cambio ordinario | Exige `reduccion_acordada` o `correccion_error` **y** documento (Art. 39 CT) |
| Desafiliación como cambio ordinario | Exige motivo `desafiliacion` y respaldo |
| Retroactividad sobre período cerrado | Solo como `correccion_error` con respaldo |
| Error de digitación sin salida | `rectificar_compensacion_v32`, mientras ningún rol la haya usado |

**Las funciones v26 sin controles quedan revocadas** (`registrar_compensacion_v26`,
`registrar_afiliacion_v26`, `guardar_nomina_parametros_v26`). Si siguieran disponibles
bastaría llamarlas para saltarse todo lo anterior. Usa siempre las `_v32`.

Decisión tomada con Fidel: **sin aprobación en dos pasos**. Los cambios surten efecto de
inmediato y el control es la trazabilidad, no la fricción.

---

## v33 · Reingreso de personal

**Caso real del grupo:** hay gente que deja de venir un par de meses y luego vuelve.
Eso puede significar dos cosas muy distintas, y el sistema hoy solo soporta una.

### Los dos caminos

**A · No se liquidó.** La relación laboral nunca terminó; la persona simplemente faltó.
Ya funciona: se registra como ausencia `permiso_sin_sueldo` o `falta_injustificada` en
v27, el rol de v30 le descuenta los días y la antigüedad sigue corriendo sin cortes.
No hace falta nada nuevo.

**B · Se liquidó y volvió.** Hubo finiquito y aviso de salida al IESS. **Hoy está
bloqueado:** `dar_baja_empleado_v26` deja al empleado en `estado = 'liquidado'`, y tanto
`registrar_afiliacion_v32` como `registrar_compensacion_v32` rechazan a los liquidados.
No hay forma de reincorporarlo sin crear una persona duplicada — lo que partiría su
expediente, su historial disciplinario y su historial de sueldos en dos.

### El problema de fondo: la antigüedad

`empleados.fecha_ingreso_real` es una sola fecha, y de ella cuelga casi todo:

- **v27** calcula los períodos de vacaciones por aniversario directamente contra ella
  (`sql/v27_ausencias_vacaciones.sql`, generación de períodos).
- Los décimos y el finiquito se proporcionan sobre el tiempo trabajado.
- Los fondos de reserva cuentan desde el mes 13, pero sobre `fecha_afiliacion`.

Si un reingreso **sobrescribe** esa fecha, se pierden los períodos de vacaciones
anteriores y su saldo. Si **no** la toca, el sistema le sigue contando antigüedad por
los meses en que no existió relación laboral. Las dos opciones están mal.

### Modelo propuesto

```
empleado_vinculos                          -- un renglón por relación laboral
  empleado_id, secuencia (1, 2, 3…),
  fecha_ingreso, fecha_salida,
  motivo_salida, tipo_salida (renuncia|despido|visto_bueno|fin_contrato|abandono),
  tipo_vinculo (inicial | reingreso_continuidad | reingreso_nueva_relacion),
  antiguedad_desde date not null,          -- LA CLAVE
  liquidado boolean, documento_finiquito_id,
  activo boolean
  -- índice único parcial: un solo vínculo activo por persona
```

**`antiguedad_desde` es la pieza que resuelve todo.** En un vínculo inicial vale lo
mismo que `fecha_ingreso`. En un reingreso lo decide quien lo registra:

- **`reingreso_nueva_relacion`** → `antiguedad_desde = fecha_ingreso` del vínculo nuevo.
  Se liquidó, se pagó el finiquito, la antigüedad arranca de cero. Vacaciones desde 15
  días otra vez.
- **`reingreso_continuidad`** → `antiguedad_desde` conserva la fecha del primer vínculo.
  Se usa cuando la salida fue formal pero se acuerda respetar la antigüedad, o cuando la
  liquidación se revierte.

Todo cálculo de antigüedad pasa a leer `antiguedad_desde` del vínculo activo en vez de
`empleados.fecha_ingreso_real`. Esa fecha se mantiene sincronizada con el vínculo vigente
por compatibilidad con lo ya construido.

### Alcance de v33

- Tabla `empleado_vinculos` y **backfill**: un vínculo `inicial` por cada empleado
  existente, con `antiguedad_desde = fecha_ingreso_real`. Nadie cambia de saldo.
- `registrar_salida_v33` — sustituye a `dar_baja_empleado_v26`: cierra el vínculo, exige
  tipo y motivo de salida, y registra si hubo liquidación y con qué documento.
- `registrar_reingreso_v33` — abre un vínculo nuevo sobre la misma persona, obliga a
  declarar si la antigüedad continúa o se reinicia, y reactiva al empleado.
- `antiguedad_desde_v33(empleado_id, fecha)` — función única que v27 y v30 deben usar
  para vacaciones, décimos y finiquito.
- Vista `vista_vinculos_empleado_v33` con el historial de entradas y salidas.
- **Ajuste en v27:** la generación de períodos de vacaciones pasa a `antiguedad_desde`.
  Los períodos del vínculo anterior se marcan `liquidado` si hubo finiquito, o siguen
  abiertos si fue continuidad.

### Lo que hay que decidir al registrar cada reingreso

Nadie puede decidirlo por el sistema, y es la única pregunta que la UI debe hacer:
**¿se le pagó finiquito al salir?** Si sí, es relación nueva y la antigüedad se reinicia.
Si no, es continuidad. Se registra con el documento de respaldo, y v32 lo audita.

---

## v34 · Departamentos del grupo económico

Catálogo controlado de departamentos, transversal a todos los RUC del grupo. Reemplaza
el texto libre `empleados.area` con `departamento_id`, migra los nombres ya registrados
y mantiene `area` como espejo compatible con los roles históricos de v30. Incluye alta
atómica de personal, creación automática del vínculo inicial, edición, desactivación
protegida, reasignación de personal y auditoría con idempotencia.

---

## v35 · Permisos configurables por rol

Catálogo central de permisos funcionales y matriz editable desde Administración. El
administrador define qué módulos puede abrir cada rol y separa consulta de edición en
Nómina. El rol administrador conserva acceso total como mecanismo de recuperación y
las reglas críticas de segregación (aprobaciones propias, motores internos y alcance
por empresa/almacén) continúan protegidas en los RPC; no se convierten en casillas.

La interfaz incluye `Administración → Permisos por rol`, auditoría e idempotencia. La
gestión de usuarios también permite asignar correctamente el rol `nomina`.

V35 también cierra hallazgos de calidad detectados al revisar la interfaz de personal:
fechas calculadas en `America/Guayaquil`, edición justificada de datos personales,
altas resumidas en una sola fila de auditoría, paginación explícita de la bitácora y
protección frente a respuestas desordenadas al cambiar de expediente.

---

## v36 · Extensiones

Impuesto a la renta en relación de dependencia · liquidaciones y actas de finiquito ·
enlace del costo real de mano de obra con `ruta_produccion_etapas.costo_estimado`, que
cierra el costeo real abierto en v25.

Las liquidaciones se apoyan en `empleado_vinculos` de v33: el finiquito se calcula sobre
el vínculo que se cierra, no sobre toda la vida de la persona en el grupo.

---

## Orden de construcción

**v26 y v30 bastan para tener roles funcionando.** v27, v28 y v29 los enriquecen y se
acoplan sin rehacer nada: cada uno solo aporta filas a `nomina_rol_rubros` y días a las
columnas de asistencia de la línea.

---

### Notas de v26 para quien siga con v27

- Se agrega `nomina` a `rol_usuario` en un **paso 1 separado** al inicio del archivo
  (Postgres no deja usar el valor en la misma transacción en que se crea).
- Helper de acceso: `usuario_puede_nomina(p_escritura boolean)`. `admin` y `nomina`
  escriben, `gerencia` solo lee. Úsalo en las policies de v27.
- Toda escritura pasa por RPC; las policies son **solo de lectura**.
- Las vistas llevan `with (security_invoker = true)` — sin eso se saltan el RLS de las
  tablas base y cualquier autenticado leería sueldos.
- Auditoría: `registrar_evento_nomina_v26(entidad, entidad_id, empleado_id, tipo, detalle)`.
  Está revocada para `authenticated`, solo se llama desde otros RPC del módulo.
- `public.es_cedula_ecuatoriana(text)` valida el dígito verificador (módulo 10) y queda
  disponible para reutilizar.
- La antigüedad para vacaciones se cuenta sobre `empleados.fecha_ingreso_real`, nunca
  sobre `empleado_afiliaciones.fecha_afiliacion`.

## Pendiente antes de escribir v26

- [ ] Corte inicial: qué persona está en qué RUC hoy, con qué sueldo declarado, con qué
      `fecha_ingreso_real` y qué `fecha_afiliacion`.
- [ ] Definir si el pago hecho desde un RUC distinto al afiliador se registra como gasto
      propio de la pagadora o como cuenta por cobrar intercompañía.
- [ ] Cargar `nomina_parametros` del año en curso (SBU vigente y porcentajes).
- [ ] Cargar `feriados` del año antes de usar v27.

### Notas de v31 (para v30 y para quien siga la interfaz)

v31 es **solo vistas**: no crea tablas ni RPC, así que puede reejecutarse sin riesgo si
v30 cambia. Lee de `nomina_rol_lineas`, `nomina_periodos`, `nomina_rubros` y
`nomina_rol_rubros` con los nombres de columna del plan.

Las 9 vistas: `vista_rol_real_v31`, `vista_rol_declarado_v31`, `vista_brecha_nomina_v31`,
`vista_costo_empleador_por_empresa_v31`, `vista_pagos_por_empresa_pagadora_v31`,
`vista_planilla_iess_v31`, `vista_resumen_periodo_nomina_v31`, `vista_rol_impresion_v31`,
`vista_rol_rubros_v31`. Todas con `security_invoker = true`.

Si v30 renombra alguna columna de `nomina_rol_lineas`, hay que reejecutar v31 — es el
único acoplamiento entre ambas.

`verificacion_v31.sql` incluye cuadres contables que valen como prueba de v30: que el
neto real nunca sea negativo, que ingresos − egresos = neto, que la brecha no se invierta,
que los días no excedan los del período, y que las sumas por RUC pagador y por RUC
afiliador cuadren con el total del período.

**Interfaz.** `app/nomina/` con tres pestañas: Personal, Roles de pago y Reportes. La
página exige rol `admin`, `gerencia` o `nomina`; `gerencia` entra en modo consulta.
Pendientes de la interfaz: formularios de alta y cambio de sueldo, pestañas de Ausencias
(v27) y Novedades (v28), parámetros anuales, e impresión del rol y del llamado de
atención (las vistas `vista_rol_impresion_v31` y `vista_novedad_impresion_v28` ya dan
todos los campos).

## Reparto de trabajo

Anotar aquí quién toma cada fase antes de empezarla, para no cruzarse.

| Fase | Responsable | Estado |
|---|---|---|
| v26 | Claude | SQL escrito 2026-08-30 — falta ejecutar en Supabase y la UI |
| v27 | Codex | SQL y verificación listos localmente — falta ejecutar en Supabase |
| v28 | Claude | SQL y verificación listos localmente — falta ejecutar en Supabase |
| v29 | Codex | instalada y verificada en Supabase 2026-08-30 |
| v30 | Codex | instalada y verificada en Supabase 2026-08-30; V31 alineada |
| v31 | Claude | vistas + módulo `app/nomina/` listos localmente — falta ejecutar en Supabase |
| v32 | Claude | SQL, verificación y pestaña de Auditoría listos — falta ejecutar en Supabase |
| v33 | Claude | SQL, verificación y pestaña "Ingresos y salidas" listos — falta ejecutar en Supabase |
| v34 | Codex | SQL, verificación e interfaz de departamentos listos localmente — falta ejecutar en Supabase |
| v35 | Codex | SQL, verificación e interfaz de permisos listos localmente — falta ejecutar en Supabase |
| v36 | — | pendiente (IR, finiquitos, costo de mano de obra) |
