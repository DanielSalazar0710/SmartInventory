# 4. Matriz regla – restricción – prueba

Cada regla de negocio se hace cumplir en la base de datos, no en la aplicación. La columna "Prueba" remite a `tests/pruebas_integridad.sql` (T01–T39, resultado esperado entre paréntesis como SQLSTATE; 00000 significa que la operación debe aceptarse) y al experimento de concurrencia (E0–E7). La ejecución completa dio **39 de 39 pruebas OK**.

| # | Regla de negocio | Entidad | Restricción SQL | Prueba |
|---|---|---|---|---|
| R01 | La cantidad física nunca es negativa | existencia_lote, movimiento | `ck_existencia_fisica CHECK (cantidad_fisica >= 0)` aplicado por `trg_movimiento_aplica_saldo` | T15 ajuste mayor al saldo (23514); T16 traslado que dejaría reservado > físico (23514) |
| R02 | SKU único; código de ubicación único dentro de su bodega | producto, ubicacion | `uq_producto_sku`, `uq_ubicacion_bodega_codigo (id_bodega, codigo)` | T07 SKU duplicado (23505); T08 código repetido en la misma bodega (23505); T09 mismo código en otra bodega (00000) |
| R03 | El número de lote es único dentro de su SKU | lote | `uq_lote_producto_numero (id_producto, numero_lote)` | T03 lote duplicado (23505) |
| R04 | Un lote vence después de fabricarse | lote | `ck_lote_fechas` | T04 fechas invertidas (23514) |
| R05 | El vencimiento es obligatorio solo si el producto lo controla | lote, producto | `trg_lote_valida_vencimiento` | T11 lote sin fecha de un producto con vencimiento (23514); T12 producto sin vencimiento acepta NULL (00000) |
| R06 | Cantidades positivas; tipo de movimiento válido y con la forma correcta | detalle_compra, movimiento | `ck_detalle_compra_cantidad`, `ck_mov_cantidad`, `ck_mov_tipo`, `ck_mov_forma`, `trg_movimiento_valida` | T02 cantidad negativa (23514); T22 SALIDA sin reserva (23514); T23 tipo inválido (23514) |
| R07 | El libro de movimientos no se modifica ni se borra | movimiento | `trg_movimiento_inmutable`, `trg_movimiento_no_truncate`, REVOKE UPDATE/DELETE/TRUNCATE | T17 UPDATE, T18 DELETE, T19 TRUNCATE (P0001) |
| R08 | El balance coincide siempre con el libro y solo lo escriben los triggers | existencia_lote | Triggers `SECURITY DEFINER` + REVOKE a `si_app` + `v_conciliacion_fisico` | T20 UPDATE directo con el rol de la aplicación (42501); T21 movimiento con `si_app` y 0 divergencias (00000); T39 conciliación final (00000) |
| R09 | Lo reservado está entre 0 y lo físico (no hay sobreasignación) | existencia_lote, reserva | `ck_existencia_reservada CHECK (cantidad_reservada BETWEEN 0 AND cantidad_fisica)` | T26 reservar 11 con 10 libres (23514); E1–E5 sin sobreventa |
| R10 | Solo se reserva stock que existe en ese lote y esa ubicación | reserva | `fk_reserva_existencia (id_lote, id_ubicacion) → existencia_lote` | T28 lote en una ubicación donde no está (23503) |
| R11 | El pedido solo tiene estados válidos y transiciones permitidas | pedido | `ck_pedido_estado`, `ck_pedido_despacho`, `trg_pedido_transicion` | T05 DESPACHADO → ABIERTO (23514); T06 estado ENVIADO (23514) |
| R12 | El lote reservado es del mismo producto que la línea | reserva | `fk_reserva_lote_producto (id_lote, id_producto) → lote` | T27 lote de yogur para una línea de leche (23503) |
| R13 | No existen líneas, reservas ni movimientos huérfanos | todas | FK con `ON DELETE RESTRICT` | T01 producto inexistente (23503) |
| R14 | No se reserva un lote vencido, en cuarentena o de otra bodega | reserva | `trg_reserva_valida` | T29 lote vencido (23514); T30 cuarentena (23514) |
| R15 | Una reserva solo pasa de ACTIVA a CONSUMIDA o LIBERADA y no cambia sus datos | reserva | `ck_reserva_estado`, `ck_reserva_cierre`, `trg_reserva_valida`, `trg_reserva_no_delete` | T31 CONSUMIDA → ACTIVA (23514) |
| R16 | Lo reservado es la suma de reservas ACTIVAS; cancelar libera el saldo | reserva, existencia_lote | `trg_reserva_aplica_saldo`, `v_conciliacion_reservado` | T32 cancelar el pedido 10 deja 0 reservado y 0 divergencias (00000) |
| R17 | La reserva FEFO es atómica: orden por vencimiento y todo o nada | reserva, existencia_lote, pedido | `reservar_fefo` / `reservar_pedido` (FOR UPDATE en orden FEFO, RAISE → ROLLBACK) | T33 toma SU-2411A=4 y SU-2411B=2, excluye el vencido (00000); T34 fallo parcial sin residuos (00000); E2, E3 |
| R18 | El stock objetivo no es menor que el mínimo | producto | `ck_producto_objetivo`, `ck_producto_minimo` | T10 objetivo < mínimo (23514) |
| R19 | Un producto con historial no se borra; se desactiva y no admite nuevas líneas | producto | FK `RESTRICT` + `trg_detalle_*_producto_activo` | T13 línea con producto inactivo (23514); T14 DELETE con historial (23503) |
| R20 | Un error se corrige con un movimiento compensatorio espejo, una sola vez | movimiento | `trg_movimiento_valida`, `uq_mov_revertido` | T24 reverso que no es espejo (23514); T25 segundo reverso (23505) |
| R21 | La recepción (total o parcial) se vincula a línea de OC, lote, ubicación y movimiento; no se recibe de más ni en una OC cerrada | recepcion_linea, orden_compra, movimiento | FK compuestas `fk_rl_*`, `trg_recepcion_linea_valida`, `trg_recepcion_linea_genera_entrada`, `uq_mov_recepcion_linea` | T35 recepción parcial válida → OC PARCIAL y ENTRADA (00000); T36 sobre-recepción (23514); T37 producto ajeno a la línea (23503); T38 OC cancelada (23514) |

Las cinco pruebas mínimas que pide el enunciado corresponden a T01 (FK inválida), T02 (cantidad negativa), T03 (clave duplicada), T04 (fecha inconsistente) y T05 (transición no permitida).
