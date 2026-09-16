# Arquitectura y base tributaria v160

## Resultado de la auditoría

La aplicación ya tenía piezas útiles que v160 reutiliza:

- `empresas`, `empresa_establecimientos` y `empresa_puntos_emision` contienen la identidad legal y la jerarquía SRI.
- `perfil_empresas`, `usuario_puede_empresa`, `permisos_sistema`, `rol_permisos` y `perfil_permisos` resuelven alcance por empresa, rol y persona.
- `comprobantes_compra`, `retenciones_compra` y `retencion_conceptos` contienen la compra y el cálculo contable que origina una retención.
- `facturacion.emision` limita el módulo por plan contratado.
- `venta_rapida_v148`, contratos y `documentos_venta_xml` son fuentes operativas; no deben duplicar caja ni inventario al emitir.

Faltaban la instantánea fiscal propia, la reserva atómica de secuenciales, certificados seguros, estados SRI, cola, respuestas, reintentos y una auditoría común. V160 cubre esa base. La firma XAdES, construcción XML, validación XSD, SOAP, RIDE y correo pertenecen al worker server-side siguiente.

## Decisiones de seguridad

- El navegador y PostgreSQL nunca reciben la contraseña del `.p12`.
- `certificados_firma_v160` guarda metadatos, huella, ruta privada y una referencia opaca al secreto. El archivo y la contraseña deben residir en Storage privado y un gestor de secretos accesible solo al worker.
- Consumir un secuencial requiere bloqueo de fila sobre `series_comprobantes_v160`. El documento, la serie y la cola se confirman en la misma transacción.
- Las claves y números tienen índices únicos. Un origen operativo solo puede producir una factura fiscal vigente.
- Preparar no consume numeración. Emitir toma una instantánea fiscal y encola.
- Las líneas, impuestos, pagos y retenciones quedan bloqueados cuando el documento ya tiene clave de acceso.
- `authenticated` solo puede leer con RLS y escribir mediante RPC. Las RPC del worker son exclusivas de `service_role`.
- Un comprobante autorizado pasa a `anulacion_solicitada`; nunca se borra ni se marca anulado localmente antes de la confirmación externa.

## Permisos

| Código | Acción |
|---|---|
| `facturacion.preparar` | Preparar y revisar una factura sin numerarla |
| `facturacion.emitir` | Consumir secuencial y enviar a la cola |
| `facturacion.reintentar` | Reencolar un error recuperable con motivo |
| `facturacion.anular` | Solicitar cancelación o anulación con motivo |
| `facturacion.certificados` | Configuración tributaria, certificados y series |
| `facturacion.retenciones_emitir` | Preparar y emitir comprobantes de retención |

Administración mantiene todos los permisos por la regla global existente. Control recibe por defecto preparar, reintentar, anular y emitir retenciones. Emitir facturas y administrar certificados se conceden individualmente al responsable contable desde `perfil_permisos`.

## Contratos RPC para el frontend

Todas las mutaciones reciben una UUID de idempotencia. El frontend debe conservarla durante los reintentos de la misma acción.

| RPC | Entrada | Salida principal |
|---|---|---|
| `guardar_configuracion_tributaria_v160` | `empresa_id`, configuración JSON, idempotencia | empresa y duplicado |
| `registrar_certificado_firma_v160` | `empresa_id`, metadatos/referencias JSON, idempotencia | certificado y duplicado |
| `desactivar_certificado_firma_v160` | certificado, motivo, idempotencia | certificado inactivo |
| `configurar_serie_comprobante_v160` | punto, ambiente, código de documento, siguiente secuencial, idempotencia | serie |
| `preparar_factura_electronica_v160` | cabecera, líneas, impuestos, pagos, idempotencia | factura preparada |
| `emitir_factura_electronica_v160` | factura, idempotencia | clave, número y estado `en_cola` |
| `preparar_retencion_electronica_v160` | cabecera, líneas derivadas de la compra, idempotencia | retención preparada |
| `emitir_retencion_electronica_v160` | retención, idempotencia | clave, número y estado `en_cola` |
| `reintentar_transmision_sri_v160` | transmisión, motivo, idempotencia | estado `pendiente` |
| `solicitar_anulacion_comprobante_v160` | tipo, comprobante, motivo, idempotencia | nuevo estado |
| `listar_comprobantes_electronicos_v160` | empresa, tipo/estado opcionales, fechas | arreglo resumido |
| `obtener_comprobante_electronico_v160` | tipo e ID | cabecera, detalle, cola y respuestas |

En los impuestos de factura, `linea_numero` enlaza el impuesto con `numero` de la línea. Si es `null`, representa el resumen total por tarifa. Las líneas de retención requieren `retencion_compra_id`; la RPC vuelve a comparar código, clase, base, porcentaje y valor con la compra registrada.

## Contrato privado del worker

- `reclamar_transmisiones_sri_v160(worker, limite)` usa `FOR UPDATE SKIP LOCKED`, incrementa intentos y evita que dos procesos firmen el mismo documento.
- `registrar_resultado_transmision_sri_v160(...)` conserva la respuesta por etapa y mueve documento/cola. Solo `service_role` puede ejecutarlas.
- El worker debe cargar certificado y secreto directamente, generar XML UTF-8, validar XSD, firmar XAdES-BES, transmitir a Recepción, consultar Autorización y guardar los artefactos privados.
- Los errores recuperables vuelven a `esperando_autorizacion` con `disponible_at`; los definitivos quedan en `error` o `rechazado` para revisión humana.

## Orden de integración

1. Ejecutar v160 y su verificador en una copia o en el editor SQL de pruebas.
2. Registrar la configuración de Boman Cía. Ltda. en ambiente 1, incluida su resolución de agente de retención sin ceros iniciales.
3. Registrar una referencia de certificado y series de prueba para códigos `01` y `07`.
4. Implementar el worker y probar una factura manual hasta autorización SRI de pruebas.
5. Conectar venta rápida y contratos usando `origen_tipo/origen_id`, sin volver a tocar caja o inventario.
6. Probar una retención originada en `comprobantes_compra/retenciones_compra`.
7. Añadir RIDE, envío por correo, monitoreo y recién después habilitar ambiente 2.
