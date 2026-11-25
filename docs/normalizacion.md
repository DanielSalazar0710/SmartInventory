# 5. Normalización

## 5.1 Relación inicial

Partimos de la planilla que el almacén usaba para registrar en una sola tabla lo que recibe y lo que despacha. Cada fila combina una línea de recepción con una línea de picking del mismo lote y ubicación:

```
RP( id_oc, fecha_oc, id_proveedor, nombre_proveedor, email_proveedor,
    nro_linea_oc, sku, nombre_producto, unidad, cantidad_pedida_oc,
    numero_lote, fecha_vencimiento, cantidad_recibida,
    id_bodega, nombre_bodega, codigo_ubicacion, zona,
    id_pedido, fecha_pedido, id_cliente, nombre_cliente,
    nro_linea_pedido, cantidad_solicitada, cantidad_pickeada )
```

Ejemplo con datos repetidos (extracto):

| id_oc | nombre_proveedor | sku | nombre_producto | numero_lote | fecha_venc. | bodega | ubicación | id_pedido | nombre_cliente | cant_pickeada |
|---|---|---|---|---|---|---|---|---|---|---|
| 6 | Lácteos Andinos S.A. | LAC-LECHE-1L | Leche UHT entera 1 L | LE-2410B | 2026-12-15 | UIO | A-01-01 | 8 | Tienda Don Pepe | 60 |
| 6 | Lácteos Andinos S.A. | LAC-LECHE-1L | Leche UHT entera 1 L | LE-2410B | 2026-12-15 | UIO | P-01 | 8 | Tienda Don Pepe | 10 |
| 6 | Lácteos Andinos S.A. | LAC-LECHE-1L | Leche UHT entera 1 L | LE-2410B | 2026-12-15 | UIO | P-01 | 10 | Farmacia Central | 40 |
| 6 | Lácteos Andinos S.A. | LAC-YOG-200 | Yogur natural 200 g | YO-2410B | 2026-11-30 | UIO | P-02 | 12 | Tienda Don Pepe | 5 |

El proveedor, el producto, el lote y el cliente se repiten en cada fila.

**Clave candidata.** Una fila representa un picking (pedido, línea, lote, ubicación) de un lote que llegó por una línea de OC. Como el número de lote solo es único dentro del SKU, la clave candidata es `(id_oc, nro_linea_oc, sku, numero_lote, codigo_ubicacion, id_bodega, id_pedido, nro_linea_pedido)`.

## 5.2 Dependencias funcionales

| # | Dependencia funcional | Significado |
|---|---|---|
| DF1 | id_oc → fecha_oc, id_proveedor, id_bodega | La cabecera de la OC |
| DF2 | id_proveedor → nombre_proveedor, email_proveedor | Datos del proveedor |
| DF3 | email_proveedor → id_proveedor | El correo identifica al proveedor (clave alternativa) |
| DF4 | sku → nombre_producto, unidad | Datos del producto |
| DF5 | (id_oc, nro_linea_oc) → sku, cantidad_pedida_oc | Línea de OC |
| DF6 | (id_oc, sku) → nro_linea_oc | Una línea por producto en cada OC |
| DF7 | (sku, numero_lote) → fecha_vencimiento | Datos del lote |
| DF8 | (id_oc, nro_linea_oc, numero_lote) → cantidad_recibida | Recepción de una línea en un lote |
| DF9 | id_bodega → nombre_bodega | Datos de la bodega |
| DF10 | (id_bodega, codigo_ubicacion) → zona | Datos de la ubicación |
| DF11 | id_pedido → fecha_pedido, id_cliente | Cabecera del pedido |
| DF12 | id_cliente → nombre_cliente | Datos del cliente |
| DF13 | (id_pedido, nro_linea_pedido) → sku, cantidad_solicitada | Línea del pedido |
| DF14 | (id_pedido, nro_linea_pedido, sku, numero_lote, id_bodega, codigo_ubicacion) → cantidad_pickeada | Cantidad tomada de cada lote y ubicación |

## 5.3 Anomalías

- **Inserción.** No se puede registrar un producto, un proveedor, una ubicación o un cliente nuevos sin inventar una OC y un pedido. Un lote recibido que todavía no se despacha obliga a dejar en NULL columnas que forman parte de la clave.
- **Actualización.** Si el proveedor cambia su correo, hay que modificar todas sus filas; si se omite una, el mismo proveedor queda con dos correos. Lo mismo ocurre con el nombre del producto o la fecha de vencimiento de un lote, que se repite en cada picking.
- **Borrado.** Al eliminar el único picking de un pedido se pierden también los datos del cliente y, si era la única fila del lote, la evidencia de su recepción y su vencimiento.
- **Hechos independientes mezclados.** Recepción y picking son hechos distintos que solo comparten el lote. Al ponerlos en la misma fila, cada recepción se combina con cada picking del mismo lote (dependencia multivaluada `numero_lote ↠ recepción | picking`), lo que multiplica filas y hace que `SUM(cantidad_recibida)` cuente varias veces la misma entrada.

## 5.4 Primera forma normal (1FN)

La planilla original traía celdas con listas, por ejemplo `lotes = "LE-2410B (60), LE-2410B@P-01 (10)"` cuando una línea se cubría con varios lotes. En 1FN cada valor es atómico: una fila por (línea de pedido, lote, ubicación) y las cantidades en columnas separadas. La relación RP de 5.1 ya cumple 1FN, pero conserva todas las dependencias parciales y transitivas anteriores.

## 5.5 Segunda forma normal (2FN)

Eliminamos las dependencias parciales: atributos no clave que dependen solo de una parte de la clave compuesta (DF1, DF2, DF4, DF5, DF7, DF9, DF10, DF11, DF13). Al separar cada determinante parcial en su propia relación queda:

- OC(**id_oc**, fecha_oc, id_proveedor, nombre_proveedor, email_proveedor, id_bodega, nombre_bodega)
- PRODUCTO(**sku**, nombre_producto, unidad)
- LINEA_OC(**id_oc, nro_linea_oc**, sku, cantidad_pedida_oc)
- LOTE(**sku, numero_lote**, fecha_vencimiento)
- RECEPCION_LOTE(**id_oc, nro_linea_oc, numero_lote**, cantidad_recibida)
- UBICACION(**id_bodega, codigo_ubicacion**, zona)
- PEDIDO(**id_pedido**, fecha_pedido, id_cliente, nombre_cliente)
- LINEA_PEDIDO(**id_pedido, nro_linea_pedido**, sku, cantidad_solicitada)
- PICKING(**id_pedido, nro_linea_pedido, sku, numero_lote, id_bodega, codigo_ubicacion**, cantidad_pickeada)

Todas cumplen 2FN porque cada atributo no clave depende de la clave completa. Siguen existiendo dependencias transitivas.

## 5.6 Tercera forma normal (3FN)

Quitamos las dependencias transitivas (un atributo no clave que depende de otro no clave):

- En OC: id_oc → id_proveedor → nombre_proveedor, email_proveedor, y id_oc → id_bodega → nombre_bodega.
- En PEDIDO: id_pedido → id_cliente → nombre_cliente.
- En PICKING, `sku` es redundante: (id_pedido, nro_linea_pedido) → sku. Se elimina de la clave.

Resultado en 3FN, que es la base de nuestro esquema:

| Relación 3FN | Tabla del esquema |
|---|---|
| PROVEEDOR(**id_proveedor**, nombre, email) | `proveedor` |
| BODEGA(**id_bodega**, nombre) | `bodega` |
| UBICACION(**id_bodega, codigo**, zona) | `ubicacion` (con clave sustituta `id_ubicacion`) |
| PRODUCTO(**sku**, nombre, unidad) | `producto` (con clave sustituta `id_producto`) |
| LOTE(**sku, numero_lote**, fecha_vencimiento) | `lote` (con clave sustituta `id_lote`) |
| ORDEN_COMPRA(**id_oc**, fecha, id_proveedor, id_bodega) | `orden_compra` |
| DETALLE_COMPRA(**id_oc, nro_linea**, sku, cantidad_pedida) | `detalle_compra` |
| RECEPCION_LINEA(**id_oc, nro_linea, numero_lote, ubicación**, cantidad_recibida) | `recepcion` + `recepcion_linea` |
| CLIENTE(**id_cliente**, nombre) | `cliente` |
| PEDIDO(**id_pedido**, fecha, id_cliente) | `pedido` |
| DETALLE_PEDIDO(**id_pedido, nro_linea**, sku, cantidad) | `detalle_pedido` |
| PICKING(**id_pedido, nro_linea, lote, ubicación**, cantidad) | `reserva` (asignación) + `movimiento` (salida física) |

**Descomposición sin pérdida.** Cada paso separa una relación R en R1 = (X ∪ Y) y R2 = (R − Y) usando una dependencia X → Y. Como la intersección de R1 y R2 es X, y X es clave de R1, el join natural reconstruye R exactamente (teorema de Heath). Por ejemplo, PEDIDO(id_pedido, fecha, id_cliente, nombre_cliente) se separa con DF12 en CLIENTE(id_cliente, nombre_cliente) y PEDIDO(id_pedido, fecha, id_cliente); la intersección {id_cliente} es la clave de CLIENTE.

**Preservación de dependencias.** Todas las DF de 5.2 quedan dentro de alguna relación del resultado (DF3 en PROVEEDOR como UNIQUE de email; DF6 en DETALLE_COMPRA como `UNIQUE (id_oc, id_producto)`), así que se pueden verificar sin joins.

## 5.7 Análisis BCNF

Una relación está en BCNF si, para toda dependencia no trivial X → Y, X es superclave. Lo analizamos en cuatro relaciones; las dos primeras cumplen BCNF, la tercera muestra un caso que está en 3FN pero no en BCNF, y la cuarta es una redundancia que decidimos conservar.

**a) LOTE(id_lote, id_producto, numero_lote, fecha_fabricacion, fecha_vencimiento, recibido_en)**

Dependencias: id_lote → todo; (id_producto, numero_lote) → todo. Claves candidatas: {id_lote} y {id_producto, numero_lote}. Los dos determinantes son claves, así que **LOTE está en BCNF**. La clave natural se conserva con `uq_lote_producto_numero`.

**b) DETALLE_PEDIDO(id_pedido, nro_linea, id_producto, cantidad)**

Dependencias: (id_pedido, nro_linea) → id_producto, cantidad; (id_pedido, id_producto) → nro_linea, cantidad (una línea por producto). Claves candidatas: {id_pedido, nro_linea} y {id_pedido, id_producto}. Ambos determinantes son superclave: **está en BCNF**. Lo mismo vale para DETALLE_COMPRA y para UBICACION, con claves {id_ubicacion} y {id_bodega, codigo}.

**c) Un caso en 3FN que no está en BCNF: ASIGNACION_PICKING(sku, id_bodega, ubicacion_picking)**

Durante el sprint 1 evaluamos guardar la ubicación de picking fija de cada SKU por bodega. Las reglas eran: cada SKU tiene una sola ubicación de picking por bodega, (sku, id_bodega) → ubicacion_picking, y cada ubicación pertenece a una bodega, ubicacion_picking → id_bodega.

- Claves candidatas: {sku, id_bodega} y {sku, ubicacion_picking}.
- Está en 3FN, porque en ubicacion_picking → id_bodega el lado derecho (id_bodega) es primo.
- **No está en BCNF**, porque ubicacion_picking no es superclave.
- Descomposición BCNF: R1(ubicacion_picking, id_bodega) y R2(sku, ubicacion_picking). Es sin pérdida, porque la intersección {ubicacion_picking} es clave de R1, pero **no preserva** (sku, id_bodega) → ubicacion_picking, ya que ninguna relación contiene esos tres atributos juntos. Para impedir dos ubicaciones de picking del mismo SKU en una bodega habría que hacer un join o usar un trigger.

Decisión: en nuestro esquema R1 ya existe (`ubicacion` con `id_bodega`) y no creamos una asignación fija, porque FEFO elige la ubicación según el lote y no según el SKU. Si en el futuro se agrega, la dejaríamos en 3FN como (id_producto, id_bodega, id_ubicacion) con `UNIQUE (id_producto, id_bodega)` y una FK compuesta `(id_ubicacion, id_bodega) → ubicacion(id_ubicacion, id_bodega)`: así se preservan ambas dependencias con restricciones declarativas, a costo de repetir id_bodega.

**d) Redundancia controlada en RESERVA y RECEPCION_LINEA**

`reserva` guarda `id_producto` aunque id_lote → id_producto (dependencia transitiva id_reserva → id_lote → id_producto). Con eso, RESERVA no está en 3FN en sentido estricto. La conservamos a propósito porque permite dos FK compuestas que hacen cumplir reglas sin triggers:

- `(id_pedido, nro_linea, id_producto) → detalle_pedido`: la reserva pertenece a una línea de ese producto.
- `(id_lote, id_producto) → lote`: el lote reservado es de ese mismo producto.

Juntas garantizan que nunca se reserve un lote de otro SKU (prueba T27). El control de consistencia es la propia FK: el valor repetido no puede divergir porque la base rechaza cualquier combinación que no exista en `lote`. Aplicamos el mismo patrón en `recepcion_linea` con `id_producto` e `id_oc`. Es la única redundancia del esquema, junto con el balance `existencia_lote`, cuya justificación está en la sección 1.3 de [`modelo.md`](modelo.md).
