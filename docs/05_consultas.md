# 7. Consultas SQL

Las ocho consultas están en `sql/03_queries.sql` y se ejecutan sobre los datos semilla con los parámetros por defecto (`dias = 30`, `sku = FAR-SUERO-500`, `cantidad = 6`, `bodega = UIO`, `pedido = 8`). Cumplen los requisitos de consultas avanzadas así:

| Requisito | Consultas que lo cumplen |
|---|---|
| Joins de tres o más tablas con agregación | Q1 (5 tablas, SUM/COUNT), Q4 (8 tablas, SUM), Q6 (6 tablas, SUM/COUNT), Q8 (4 tablas, SUM/COUNT con ROLLUP) |
| Función de ventana | Q3 (`row_number` y suma acumulada para asignar FEFO), Q6 (`bool_and … OVER (PARTITION BY id_oc)`), Q7 (saldo acumulado por SKU y mes) |

## Q1. Stock disponible por SKU, bodega y ubicación

**Necesidad.** Saber cuánto se puede vender de cada SKU en cada ubicación, descontando reservas vigentes y sin perder de vista lo que está físicamente pero no se puede vender.

{{SQL_Q1}}

{{RES_Q1}}

**Explicación.** El join parte de `existencia_lote` (el nivel de trazabilidad) y sube a lote, producto, ubicación y bodega. Los `FILTER` separan en una sola pasada lo bloqueado (lote vencido o ubicación en cuarentena) de lo disponible. El `UNION ALL` con `NOT EXISTS` agrega una fila en cero para los SKU activos sin existencias, como FER-CINTA-48. Se ve que el suero tiene 17 unidades físicas pero solo 7 disponibles, porque 10 pertenecen a un lote vencido.

## Q2. Lotes próximos a vencer

**Necesidad.** Priorizar la venta o la baja de los lotes que vencen dentro de una ventana de días.

{{SQL_Q2}}

{{RES_Q2}}

**Explicación.** Se filtra por `fecha_vencimiento <= current_date + :dias`, lo que deja fuera a los productos sin vencimiento (NULL). Los vencidos no se mezclan con los que están por vencer: van en una categoría separada que se ordena primero. `string_agg` lista todas las ubicaciones de cada lote.

## Q3. Plan de picking FEFO

**Necesidad.** Mostrar, antes de reservar, de qué lotes y ubicaciones saldrá un pedido de `:cantidad` unidades.

{{SQL_Q3}}

{{RES_Q3}}

**Explicación.** Solo entran lotes elegibles: no vencidos, fuera de cuarentena, con disponible mayor que cero y de la bodega pedida. La ventana `w` define el orden FEFO (vencimiento, luego fecha de recepción y número de lote como desempate determinista). `sum(disponible) OVER w − disponible` es lo acumulado antes de cada lote, y con eso se calcula cuánto asignar hasta cubrir la demanda. Para 6 unidades toma las 4 de SU-2411A y 2 de SU-2411B, y excluye SU-2410, que está vencido aunque tenga 10 unidades. Es el mismo plan que ejecuta la función `reservar_fefo` (prueba T33).

## Q4. Productos bajo mínimo y sugerencia de compra

**Necesidad.** Detectar qué comprar antes de que haya quiebre, sin duplicar lo que ya viene en camino.

{{SQL_Q4}}

{{RES_Q4}}

**Explicación.** Definimos **posición = físico vendible + pendiente en órdenes abiertas − reservado**. El pendiente se calcula como `cantidad_pedida − Σ cantidad_recibida` de las OC ABIERTAS o PARCIALES, así que una OC parcial solo aporta lo que falta. Se sugiere comprar cuando la posición cae bajo el mínimo, por la diferencia hasta el objetivo. La cinta tiene 60 unidades en una OC abierta, pero no le alcanzan para llegar al mínimo de 80, así que se sugieren 90 más. El supuesto es que el mínimo y el objetivo son de toda la red y no de cada bodega.

## Q5. Trazabilidad de un pedido

**Necesidad.** Responder de dónde salió cada unidad entregada a un cliente, por ejemplo ante un reclamo o un retiro de lote.

{{SQL_Q5}}

{{RES_Q5}}

**Explicación.** La cadena es pedido → líneas → reservas → lote y ubicación → movimiento de SALIDA, y con un `LATERAL` va hacia atrás: lote → recepción → OC → proveedor → guía de remisión. La línea de 70 unidades se cubrió con dos reservas del mismo lote en dos ubicaciones, y cada una tiene su propio movimiento de salida. Los `LEFT JOIN` hacen que un pedido todavía no reservado o no despachado también se pueda consultar.

## Q6. Recepciones parciales de órdenes de compra

**Necesidad.** Seguir lo ordenado, lo recibido y lo pendiente por línea, y saber qué órdenes ya se completaron.

{{SQL_Q6}}

{{RES_Q6}}

**Explicación.** El `LEFT JOIN` a `recepcion_linea` conserva las líneas sin recibir. `count(DISTINCT id_recepcion)` muestra que el yogur de la OC 6 llegó en dos entregas. La ventana `bool_and(...) OVER (PARTITION BY id_oc)` marca una OC como completada solo si todas sus líneas lo están, y coincide con el estado que mantiene el trigger de recepción.

## Q7. Rotación y movimientos por periodo

**Necesidad.** Medir qué tan rápido se mueve cada SKU mes a mes.

{{SQL_Q7}}

{{RES_Q7}}

**Explicación.** Definimos la **rotación mensual = unidades despachadas (SALIDA) en el mes / inventario promedio del mes**, con inventario promedio = (saldo inicial + saldo final) / 2. El saldo se reconstruye desde el libro: cada movimiento aporta `cantidad × (tiene destino − tiene origen)`, así que una entrada suma, una salida resta y un traslado da cero en la red. La función de ventana `sum(neto) OVER (PARTITION BY sku ORDER BY mes)` acumula ese neto para obtener el saldo final de cada mes. El `CROSS JOIN` con la serie de meses muestra también los meses sin movimiento. El inventario incluye unidades vencidas, por lo que la rotación del suero en noviembre aparece baja: ese stock inmóvil es justamente lo que el indicador debe hacer visible.

## Q8. Quiebres y nivel de servicio

**Necesidad.** Medir cuántas líneas comprometidas se entregaron completas y a tiempo.

{{SQL_Q8}}

{{RES_Q8}}

**Explicación.** El denominador son las líneas de pedido cuya fecha de compromiso ya pasó, dentro de los últimos 90 días, sin contar pedidos cancelados por el cliente. Una línea cuenta como atendida si las reservas consumidas cubren la cantidad solicitada y el despacho ocurrió a más tardar en la fecha comprometida. Reportamos también el **fill rate** (unidades despachadas / unidades solicitadas), que es menos severo. `ROLLUP` agrega la fila TOTAL: 72,7 % de nivel de servicio y 98,7 % de fill rate. El detalle muestra el único quiebre: la cinta del pedido 7, que no tenía stock.
