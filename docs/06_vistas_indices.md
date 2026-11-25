# 8. Vistas e índices

## 8.1 Vistas del dashboard

| Vista | Lectura que resuelve | Actualización esperada |
|---|---|---|
| `v_stock_disponible` | Físico, reservado, bloqueado, disponible, próximo vencimiento y lotes con saldo por SKU y bodega (incluye ceros) | En línea: refleja el último COMMIT. Es la tarjeta principal del dashboard. |
| `v_reposicion_sugerida` | SKU bajo mínimo con posición, pendiente en OC y sugerencia de compra (misma definición que Q4) | En línea; se consulta unas pocas veces al día. |
| `v_nivel_servicio_mensual` | Líneas comprometidas, completas a tiempo, con quiebre, nivel de servicio y fill rate por mes | Histórica: si el volumen crece, la convertiríamos en vista materializada con `REFRESH MATERIALIZED VIEW CONCURRENTLY` cada 15 minutos. |
| `v_conciliacion_fisico`, `v_conciliacion_reservado` | Divergencias libro–balance (deben estar vacías) | Se usan en pruebas y como alarma operativa. |

Salida de `v_stock_disponible` con los datos semilla:

{{VISTA_STOCK}}

**Por qué las vistas no son fuente de escritura.** Las tres vistas tienen agregaciones, `GROUP BY` y joins, así que PostgreSQL no las puede actualizar automáticamente. Además, el rol `si_app` solo tiene `SELECT` sobre ellas. Pero la razón de fondo es de diseño: un número agregado (por ejemplo, "236 litros de leche disponibles en UIO") no dice de qué lote ni de qué ubicación saldrían las unidades. Si el dashboard pudiera escribir sobre ese agregado, el saldo dejaría de ser trazable a lote y ubicación y el libro dejaría de explicarlo. Toda escritura pasa por las funciones de negocio, que registran el movimiento o la reserva correspondiente.

## 8.2 Índices propuestos

PostgreSQL crea índices para PK y UNIQUE, pero no para las FK. Revisamos las búsquedas frecuentes y las FK usadas en joins y en verificaciones de borrado:

| Índice | Uso | Selectividad y costo |
|---|---|---|
| `ix_existencia_con_disponible` (id_lote, id_ubicacion) INCLUDE (físico, reservado) WHERE físico > reservado | Búsqueda FEFO | Parcial: solo filas con disponible. Permite *index-only scan*. Cambia en cada reserva, pero es pequeño. |
| `ix_lote_vencimiento` (fecha_vencimiento) WHERE NOT NULL | Q2, alertas de vencimiento | Rango de fechas; excluye productos sin vencimiento. |
| `ix_reserva_linea` (id_pedido, nro_linea) | Q5, Q8, despacho, verificación de FK | Muy selectivo (≈2,5 filas por pedido). |
| `ix_recepcion_linea_lote` (id_lote) | Q5 (origen del lote) | Muy selectivo (≈1 fila por lote). |
| `ix_recepcion_linea_oc` (id_oc, nro_linea_oc) | Trigger de recepción (suma lo ya recibido), Q4, Q6 | Sin este índice el trigger recorre toda la tabla en cada recepción. |
| `ix_movimiento_lote_fecha` (id_lote, ocurrido_en) | Conciliación, Q7, verificación de FK | Es el índice más grande (2,5 MB con 74 530 movimientos); lo mantenemos porque la conciliación se ejecuta como prueba. |
| `ix_reserva_existencia` (id_lote, id_ubicacion) WHERE estado = 'ACTIVA' | Conciliación de reservado | Parcial: las reservas activas son pocas (16 kB). |
| `ix_detalle_pedido_producto`, `ix_pedido_compromiso`, `ix_pedido_abiertos` (parcial) | Verificación de FK, Q8, pedidos vivos | El parcial de pedidos abiertos ocupa 16 kB frente a 160 kB del índice completo. |

**Índices descartados por redundantes**: `existencia_lote(id_lote)`, `detalle_compra(id_oc)` y `detalle_pedido(id_pedido)` son prefijos de sus PK; `movimiento(id_reserva)` y `movimiento(id_recepcion_linea)` ya tienen UNIQUE. También descartamos `lote(id_producto, fecha_vencimiento, …)` después de medirlo (ver C1).

## 8.3 EXPLAIN (ANALYZE, BUFFERS) antes y después

Medimos sobre una base de volumen generada con `benchmarks/seed_volumen.sql` y cargada por las mismas funciones de negocio: 3 bodegas, 300 ubicaciones, 2 000 SKU, 24 000 lotes, 26 384 saldos, 20 000 pedidos, 50 000 líneas, 49 901 reservas y 74 530 movimientos. La fase "antes" elimina los índices propuestos y la fase "después" los recrea; cada consulta se ejecuta una vez para calentar la caché y luego se mide. El paralelismo está desactivado para comparar planes equivalentes. La salida completa está en `evidencias/explain_antes_despues.txt`.

| Consulta crítica | Plan antes | Plan después | Buffers antes → después | Tiempo antes → después |
|---|---|---|---|---|
| C1 · Búsqueda FEFO de un SKU (la ejecuta cada reserva) | Bitmap scan por `uq_lote_producto_numero` + PK de `existencia_lote` | Igual en `lote`; *index-only scan* en `ix_existencia_con_disponible` | 61 → 56 | 0,077 → 0,083 ms |
| C2 · Lotes que vencen en 30 días | Seq scan de `lote` (24 000) + seq scan de `existencia_lote` + hash join | Bitmap scan en `ix_lote_vencimiento` para `lote`; `existencia_lote` sigue en seq scan | 1 308 → 1 310 | 10,5 → 13,6 ms |
| C3 · Trazabilidad de un pedido | Seq scan de `reserva` (49 901) y de `recepcion_linea` (21 600) + hash joins | Nested loops con `ix_reserva_linea` e `ix_recepcion_linea_lote` | 1 274 → 51 | 6,46 → 0,10 ms |

**Costo de escritura.** Registramos 2 000 traslados dentro de una transacción que luego se deshace. Sin los índices propuestos tomaron 350 ms y con ellos 407 ms, es decir, **16 % más**, porque cada movimiento actualiza `ix_movimiento_lote_fecha` y el índice parcial de existencias. En total, los diez índices propuestos ocupan cerca de 6,3 MB.

**Lectura de los resultados.**

- **C3 justifica sus índices claramente**: pasa de leer 1 274 páginas a 51 (25 veces menos) y de 6,5 ms a 0,1 ms. Sin índice en las FK, cada consulta de trazabilidad recorre todas las reservas y recepciones.
- **C1 no mejora y eso nos llevó a descartar un índice.** La búsqueda por producto ya la resuelve `uq_lote_producto_numero` (su primera columna es `id_producto`), y cada SKU tiene alrededor de 12 lotes, así que ordenarlos en memoria cuesta menos de 0,1 ms. Por eso eliminamos el índice `lote(id_producto, fecha_vencimiento, …)` que habíamos propuesto: sumaba costo en cada recepción sin bajar las páginas leídas. Solo conservamos el índice parcial de existencias, que evita leer el heap.
- **C2 no mejora con este dataset.** El índice cambia el seq scan de `lote` (que descartaba 22 486 filas) por un bitmap scan, pero los 1 514 lotes de la ventana están repartidos en 176 de las 177 páginas de la tabla, así que se leen casi las mismas páginas. Además, el costo lo domina el join con `existencia_lote` (1 112 páginas): con 1 514 lotes en la ventana, el planificador elige con razón un hash join sobre toda la tabla, que es más barato que 1 514 búsquedas por índice. La diferencia de tiempo (10,5 frente a 13,6 ms) es variación de medición, porque los buffers son prácticamente iguales. El índice se justifica cuando la tabla de lotes acumula años de historial y la ventana de 30 días pasa a ser una fracción mucho menor.

**Limitaciones del dataset de prueba.** Los datos son sintéticos y uniformes (los SKU y las cantidades siguen fórmulas modulares), todo cabe en `shared_buffers` (por eso solo hay *shared hit*) y las mediciones son de una sola ejecución en caché caliente. Los tiempos menores a 1 ms están dentro del ruido; por eso basamos las conclusiones en las páginas leídas y en el tipo de plan. En la carga de volumen, los pedidos se reservaron en orden de creación, pero sin impedir que tomaran lotes recibidos después de la fecha del pedido, lo que no afecta los planes medidos.
