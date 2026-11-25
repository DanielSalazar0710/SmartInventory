-- =============================================================================
-- Smart Inventory · 03_queries.sql
-- Ocho consultas operativas y analíticas sobre el modelo normalizado.
-- Parámetros con variables de psql (valores por defecto si no se pasan):
--   psql -v dias=30 -v sku=FAR-SUERO-500 -v cantidad=6 -v bodega=UIO -v pedido=8 -f 03_queries.sql
-- Definiciones comunes:
--   * Disponible (vendible) por (lote, ubicación) = cantidad_fisica - cantidad_reservada,
--     solo si el lote no está vencido y la ubicación no es CUARENTENA ni está inactiva.
--   * Reservas vigentes = reservas en estado ACTIVA (ya sumadas en cantidad_reservada).
-- =============================================================================
\set ON_ERROR_STOP on
SET search_path = si, public;
\if :{?dias}     \else \set dias 30              \endif
\if :{?sku}      \else \set sku 'FAR-SUERO-500'   \endif
\if :{?cantidad} \else \set cantidad 6           \endif
\if :{?bodega}   \else \set bodega 'UIO'          \endif
\if :{?pedido}   \else \set pedido 8             \endif
\pset null '—'

-- -----------------------------------------------------------------------------
-- Q1. Stock disponible por SKU, bodega y ubicación.
-- Separa físico, reservado y bloqueado (lote vencido o ubicación en cuarentena)
-- para que el disponible sea trazable a lote y ubicación. Los SKU activos sin
-- existencias aparecen con una fila en cero (UNION ALL con NOT EXISTS).
-- Joins: existencia_lote, lote, producto, ubicacion, bodega (5 tablas) + SUM/COUNT.
-- -----------------------------------------------------------------------------
\echo '== Q1. Stock disponible por SKU, bodega y ubicación =='
WITH stock AS (
  SELECT p.sku, b.codigo AS bodega, u.codigo AS ubicacion, u.tipo,
         count(*)                   AS lotes,
         sum(e.cantidad_fisica)     AS fisico,
         sum(e.cantidad_reservada)  AS reservado,
         coalesce(sum(e.cantidad_fisica) FILTER (
                    WHERE u.tipo = 'CUARENTENA' OR NOT u.activa
                       OR l.fecha_vencimiento <= current_date), 0) AS bloqueado,
         coalesce(sum(e.cantidad_fisica - e.cantidad_reservada) FILTER (
                    WHERE u.tipo <> 'CUARENTENA' AND u.activa
                      AND (l.fecha_vencimiento IS NULL OR l.fecha_vencimiento > current_date)), 0) AS disponible
    FROM existencia_lote e
    JOIN lote l      ON l.id_lote = e.id_lote
    JOIN producto p  ON p.id_producto = l.id_producto
    JOIN ubicacion u ON u.id_ubicacion = e.id_ubicacion
    JOIN bodega b    ON b.id_bodega = u.id_bodega
   WHERE p.activo AND e.cantidad_fisica > 0
   GROUP BY p.sku, b.codigo, u.codigo, u.tipo
)
SELECT * FROM stock
UNION ALL
SELECT p.sku, '(sin stock)', NULL, NULL, 0, 0, 0, 0, 0
  FROM producto p
 WHERE p.activo AND NOT EXISTS (SELECT 1 FROM stock s WHERE s.sku = p.sku)
 ORDER BY sku, bodega, ubicacion;

-- -----------------------------------------------------------------------------
-- Q2. Lotes próximos a vencer (parámetro :dias). Los vencidos se muestran en una
-- categoría separada; los productos sin vencimiento no aplican. Solo lotes con
-- existencia física.
-- -----------------------------------------------------------------------------
\echo '== Q2. Lotes próximos a vencer (ventana de' :dias 'días) =='
SELECT CASE WHEN l.fecha_vencimiento <= current_date THEN '1-VENCIDO'
            ELSE '2-POR VENCER' END                         AS categoria,
       p.sku, l.numero_lote, l.fecha_vencimiento,
       l.fecha_vencimiento - current_date                     AS dias_restantes,
       string_agg(b.codigo || ':' || u.codigo, ', ' ORDER BY b.codigo, u.codigo) AS ubicaciones,
       sum(e.cantidad_fisica)                                  AS fisico,
       sum(e.cantidad_reservada)                               AS reservado
  FROM lote l
  JOIN producto p        ON p.id_producto = l.id_producto
  JOIN existencia_lote e ON e.id_lote = l.id_lote AND e.cantidad_fisica > 0
  JOIN ubicacion u       ON u.id_ubicacion = e.id_ubicacion
  JOIN bodega b          ON b.id_bodega = u.id_bodega
 WHERE l.fecha_vencimiento IS NOT NULL
   AND l.fecha_vencimiento <= current_date + :dias
 GROUP BY p.sku, l.numero_lote, l.fecha_vencimiento
 ORDER BY categoria, l.fecha_vencimiento, p.sku;

-- -----------------------------------------------------------------------------
-- Q3. Plan de picking FEFO (simulación de solo lectura) para :sku, :cantidad, :bodega.
-- Orden: vencimiento más cercano (sin vencimiento al final), luego fecha de
-- recepción y código de lote/ubicación como desempate determinista.
-- FUNCIÓN DE VENTANA: el acumulado de disponible permite saber cuánto toma
-- cada lote hasta cubrir la demanda o agotar el stock elegible.
-- -----------------------------------------------------------------------------
\echo '== Q3. Plan de picking FEFO para' :sku 'x' :cantidad 'en' :bodega '=='
WITH elegibles AS (
  SELECT l.numero_lote, u.codigo AS ubicacion, l.fecha_vencimiento, l.recibido_en,
         e.cantidad_fisica - e.cantidad_reservada AS disponible
    FROM existencia_lote e
    JOIN lote l      ON l.id_lote = e.id_lote
    JOIN producto p  ON p.id_producto = l.id_producto
    JOIN ubicacion u ON u.id_ubicacion = e.id_ubicacion
    JOIN bodega b    ON b.id_bodega = u.id_bodega
   WHERE p.sku = :'sku' AND b.codigo = :'bodega'
     AND u.tipo <> 'CUARENTENA' AND u.activa
     AND (l.fecha_vencimiento IS NULL OR l.fecha_vencimiento > current_date)
     AND e.cantidad_fisica - e.cantidad_reservada > 0
), plan AS (
  SELECT *,
         row_number() OVER w                    AS orden_fefo,
         sum(disponible) OVER w - disponible    AS acumulado_previo
    FROM elegibles
  WINDOW w AS (ORDER BY fecha_vencimiento NULLS LAST, recibido_en, numero_lote, ubicacion)
)
SELECT orden_fefo, numero_lote, ubicacion, fecha_vencimiento, disponible,
       greatest(least(disponible, :cantidad - acumulado_previo), 0) AS asignar,
       greatest(:cantidad - acumulado_previo - disponible, 0)       AS pendiente_despues
  FROM plan
 ORDER BY orden_fefo;

-- -----------------------------------------------------------------------------
-- Q4. Productos bajo mínimo y sugerencia de compra (red completa).
-- Posición = físico vendible + en órdenes abiertas - reservado.
-- Se sugiere comprar cuando posición < mínimo, por la diferencia hasta el objetivo.
-- Joins: producto, lote, existencia_lote, ubicacion, detalle_compra, orden_compra,
-- recepcion_linea, proveedor + agregaciones.
-- -----------------------------------------------------------------------------
\echo '== Q4. Reposición: productos bajo mínimo y sugerencia de compra =='
WITH stock AS (
  SELECT l.id_producto,
         sum(e.cantidad_fisica)    AS fisico_vendible,
         sum(e.cantidad_reservada) AS reservado
    FROM existencia_lote e
    JOIN lote l      ON l.id_lote = e.id_lote
    JOIN ubicacion u ON u.id_ubicacion = e.id_ubicacion
   WHERE u.tipo <> 'CUARENTENA' AND u.activa
     AND (l.fecha_vencimiento IS NULL OR l.fecha_vencimiento > current_date)
   GROUP BY l.id_producto
), transito AS (
  SELECT d.id_producto,
         sum(d.cantidad_pedida - coalesce(r.recibido, 0)) AS en_ordenes_abiertas
    FROM detalle_compra d
    JOIN orden_compra oc ON oc.id_oc = d.id_oc AND oc.estado IN ('ABIERTA','PARCIAL')
    LEFT JOIN (SELECT id_oc, nro_linea_oc, sum(cantidad_recibida) AS recibido
                 FROM recepcion_linea GROUP BY id_oc, nro_linea_oc) r
           ON r.id_oc = d.id_oc AND r.nro_linea_oc = d.nro_linea
   GROUP BY d.id_producto
), posicion AS (
  SELECT p.sku, p.nombre, p.stock_minimo, p.stock_objetivo, p.id_proveedor_pref,
         coalesce(s.fisico_vendible, 0)     AS fisico_vendible,
         coalesce(t.en_ordenes_abiertas, 0) AS en_ordenes_abiertas,
         coalesce(s.reservado, 0)           AS reservado,
         coalesce(s.fisico_vendible, 0) + coalesce(t.en_ordenes_abiertas, 0)
           - coalesce(s.reservado, 0)       AS posicion
    FROM producto p
    LEFT JOIN stock s    ON s.id_producto = p.id_producto
    LEFT JOIN transito t ON t.id_producto = p.id_producto
   WHERE p.activo
)
SELECT po.sku, po.fisico_vendible, po.en_ordenes_abiertas, po.reservado, po.posicion,
       po.stock_minimo AS minimo, po.stock_objetivo AS objetivo,
       po.stock_objetivo - po.posicion AS sugerencia_compra,
       pr.nombre AS proveedor, pr.lead_time_dias,
       current_date + pr.lead_time_dias AS llegada_estimada
  FROM posicion po
  LEFT JOIN proveedor pr ON pr.id_proveedor = po.id_proveedor_pref
 WHERE po.posicion < po.stock_minimo
 ORDER BY (po.posicion::numeric / nullif(po.stock_minimo, 0)), po.sku;

-- -----------------------------------------------------------------------------
-- Q5. Trazabilidad de un pedido (:pedido).
-- Pedido -> líneas -> reservas -> lotes/ubicaciones -> movimiento de SALIDA,
-- y hacia atrás: lote -> recepción -> orden de compra -> proveedor.
-- Una línea puede aparecer varias veces si usó varios lotes o ubicaciones.
-- -----------------------------------------------------------------------------
\echo '== Q5. Trazabilidad del pedido' :pedido '=='
SELECT pe.id_pedido, c.nombre AS cliente, pe.estado,
       d.nro_linea, p.sku, d.cantidad AS solicitado,
       r.id_reserva, r.estado AS estado_reserva, r.cantidad AS asignado,
       l.numero_lote, l.fecha_vencimiento, u.codigo AS ubicacion,
       m.id_movimiento AS mov_salida, m.ocurrido_en::date AS fecha_salida,
       ent.origen AS origen_del_lote
  FROM pedido pe
  JOIN cliente c         ON c.id_cliente = pe.id_cliente
  JOIN detalle_pedido d  ON d.id_pedido = pe.id_pedido
  JOIN producto p        ON p.id_producto = d.id_producto
  LEFT JOIN reserva r    ON r.id_pedido = d.id_pedido AND r.nro_linea = d.nro_linea
  LEFT JOIN lote l       ON l.id_lote = r.id_lote
  LEFT JOIN ubicacion u  ON u.id_ubicacion = r.id_ubicacion
  LEFT JOIN movimiento m ON m.id_reserva = r.id_reserva AND m.tipo = 'SALIDA'
  LEFT JOIN LATERAL (
        SELECT string_agg(DISTINCT 'OC ' || rl.id_oc || ' / ' || pr.codigo || ' / GR ' ||
                          coalesce(rc.guia_remision, 's/n'), '; ') AS origen
          FROM recepcion_linea rl
          JOIN recepcion rc    ON rc.id_recepcion = rl.id_recepcion
          JOIN orden_compra oc ON oc.id_oc = rl.id_oc
          JOIN proveedor pr    ON pr.id_proveedor = oc.id_proveedor
         WHERE rl.id_lote = l.id_lote) ent ON true
 WHERE pe.id_pedido = :pedido
 ORDER BY d.nro_linea, r.id_reserva;

-- -----------------------------------------------------------------------------
-- Q6. Recepciones parciales de órdenes de compra.
-- Cantidad ordenada, recibida y pendiente por línea; número de recepciones;
-- y, con una función de ventana, si la OC completa quedó cubierta.
-- Joins: orden_compra, proveedor, detalle_compra, producto, recepcion_linea + agregación.
-- -----------------------------------------------------------------------------
\echo '== Q6. Recepciones parciales y órdenes completadas =='
SELECT oc.id_oc, pr.codigo AS proveedor, b.codigo AS bodega, oc.estado AS estado_oc,
       d.nro_linea, p.sku,
       d.cantidad_pedida                                  AS ordenado,
       coalesce(sum(rl.cantidad_recibida), 0)             AS recibido,
       d.cantidad_pedida - coalesce(sum(rl.cantidad_recibida), 0) AS pendiente,
       count(DISTINCT rl.id_recepcion)                    AS recepciones,
       CASE WHEN coalesce(sum(rl.cantidad_recibida), 0) = 0 THEN 'SIN RECIBIR'
            WHEN sum(rl.cantidad_recibida) < d.cantidad_pedida THEN 'PARCIAL'
            ELSE 'COMPLETA' END                           AS estado_linea,
       bool_and(coalesce(sum(rl.cantidad_recibida), 0) >= d.cantidad_pedida)
         OVER (PARTITION BY oc.id_oc)                     AS oc_completada
  FROM orden_compra oc
  JOIN proveedor pr       ON pr.id_proveedor = oc.id_proveedor
  JOIN bodega b           ON b.id_bodega = oc.id_bodega
  JOIN detalle_compra d   ON d.id_oc = oc.id_oc
  JOIN producto p         ON p.id_producto = d.id_producto
  LEFT JOIN recepcion_linea rl ON rl.id_oc = d.id_oc AND rl.nro_linea_oc = d.nro_linea
 WHERE oc.estado <> 'CANCELADA'
 GROUP BY oc.id_oc, pr.codigo, b.codigo, oc.estado, d.nro_linea, p.sku, d.cantidad_pedida
 ORDER BY oc_completada, oc.id_oc, d.nro_linea;

-- -----------------------------------------------------------------------------
-- Q7. Rotación y movimientos por SKU y mes.
-- Efecto neto de cada movimiento en la red = cantidad * (tiene destino - tiene origen):
-- ENTRADA suma, SALIDA resta, TRASLADO es neutro, AJUSTE/REVERSO según su sentido.
-- Saldo final del mes = suma acumulada del neto (FUNCIÓN DE VENTANA).
-- Rotación mensual = unidades despachadas (SALIDA) / inventario promedio,
-- con inventario promedio = (saldo inicial + saldo final) / 2.
-- -----------------------------------------------------------------------------
\echo '== Q7. Rotación y movimientos por SKU y mes =='
WITH meses AS (
  SELECT generate_series(date_trunc('month', (SELECT min(ocurrido_en) FROM movimiento)),
                         date_trunc('month', now()), interval '1 month') AS mes
), mov AS (
  SELECT l.id_producto, date_trunc('month', m.ocurrido_en) AS mes,
         sum(m.cantidad) FILTER (WHERE m.tipo = 'ENTRADA') AS entradas,
         sum(m.cantidad) FILTER (WHERE m.tipo = 'SALIDA')  AS salidas,
         count(*)                                           AS n_movimientos,
         sum(m.cantidad * ((m.id_ubicacion_destino IS NOT NULL)::int
                         - (m.id_ubicacion_origen  IS NOT NULL)::int)) AS neto
    FROM movimiento m
    JOIN lote l ON l.id_lote = m.id_lote
   GROUP BY l.id_producto, date_trunc('month', m.ocurrido_en)
), serie AS (
  SELECT p.sku, me.mes,
         coalesce(mv.entradas, 0) AS entradas, coalesce(mv.salidas, 0) AS salidas,
         coalesce(mv.n_movimientos, 0) AS n_movimientos,
         sum(coalesce(mv.neto, 0)) OVER (PARTITION BY p.sku ORDER BY me.mes) AS saldo_final,
         coalesce(mv.neto, 0) AS neto
    FROM producto p
   CROSS JOIN meses me
    LEFT JOIN mov mv ON mv.id_producto = p.id_producto AND mv.mes = me.mes
)
SELECT sku, to_char(mes, 'YYYY-MM') AS mes, n_movimientos, entradas, salidas,
       saldo_final - neto AS saldo_inicial, saldo_final,
       round((saldo_final - neto + saldo_final) / 2.0, 1) AS inventario_promedio,
       round(salidas / nullif((saldo_final - neto + saldo_final) / 2.0, 0), 2) AS rotacion
  FROM serie
 WHERE n_movimientos > 0 OR saldo_final > 0
 ORDER BY sku, mes;

-- -----------------------------------------------------------------------------
-- Q8. Quiebres y nivel de servicio por mes de compromiso.
-- Periodo: líneas cuyo compromiso ya venció (fecha_compromiso < hoy) en los
-- últimos 90 días; se excluyen pedidos cancelados por el cliente.
-- Denominador = líneas comprometidas en el periodo.
-- Línea atendida = unidades consumidas (reservas CONSUMIDA) = solicitadas
-- y despachada a más tardar en la fecha de compromiso.
-- Fill rate = unidades despachadas / unidades solicitadas.
-- -----------------------------------------------------------------------------
\echo '== Q8. Quiebres y nivel de servicio =='
WITH lineas AS (
  SELECT pe.id_pedido, d.nro_linea, p.sku, d.cantidad AS solicitado,
         date_trunc('month', pe.fecha_compromiso) AS mes,
         coalesce(sum(r.cantidad) FILTER (WHERE r.estado = 'CONSUMIDA'), 0) AS despachado,
         pe.despachado_en IS NOT NULL AND pe.despachado_en::date <= pe.fecha_compromiso AS a_tiempo
    FROM pedido pe
    JOIN detalle_pedido d ON d.id_pedido = pe.id_pedido
    JOIN producto p       ON p.id_producto = d.id_producto
    LEFT JOIN reserva r   ON r.id_pedido = d.id_pedido AND r.nro_linea = d.nro_linea
   WHERE pe.estado <> 'CANCELADO'
     AND pe.fecha_compromiso <  current_date
     AND pe.fecha_compromiso >= current_date - 90
   GROUP BY pe.id_pedido, d.nro_linea, p.sku, d.cantidad, pe.fecha_compromiso, pe.despachado_en
), clasif AS (
  SELECT *, CASE WHEN despachado = 0 THEN 'NO ATENDIDA'
                 WHEN despachado < solicitado THEN 'PARCIAL'
                 WHEN NOT a_tiempo THEN 'COMPLETA TARDE'
                 ELSE 'COMPLETA A TIEMPO' END AS resultado
    FROM lineas
)
SELECT coalesce(to_char(mes, 'YYYY-MM'), 'TOTAL')                         AS mes,
       count(*)                                                            AS lineas,
       count(*) FILTER (WHERE resultado = 'COMPLETA A TIEMPO')             AS a_tiempo_completas,
       count(*) FILTER (WHERE resultado = 'COMPLETA TARDE')                AS tarde,
       count(*) FILTER (WHERE resultado = 'PARCIAL')                       AS parciales,
       count(*) FILTER (WHERE resultado = 'NO ATENDIDA')                   AS no_atendidas,
       round(100.0 * count(*) FILTER (WHERE resultado = 'COMPLETA A TIEMPO') / count(*), 1) AS nivel_servicio_pct,
       round(100.0 * sum(despachado) / sum(solicitado), 1)                 AS fill_rate_pct
  FROM clasif
 GROUP BY ROLLUP (mes)
 ORDER BY mes NULLS LAST;

\echo '-- Detalle de quiebres (líneas no atendidas o parciales)'
WITH lineas AS (
  SELECT pe.id_pedido, d.nro_linea, p.sku, d.cantidad AS solicitado, pe.fecha_compromiso,
         coalesce(sum(r.cantidad) FILTER (WHERE r.estado = 'CONSUMIDA'), 0) AS despachado
    FROM pedido pe
    JOIN detalle_pedido d ON d.id_pedido = pe.id_pedido
    JOIN producto p       ON p.id_producto = d.id_producto
    LEFT JOIN reserva r   ON r.id_pedido = d.id_pedido AND r.nro_linea = d.nro_linea
   WHERE pe.estado <> 'CANCELADO' AND pe.fecha_compromiso < current_date
     AND pe.fecha_compromiso >= current_date - 90
   GROUP BY pe.id_pedido, d.nro_linea, p.sku, d.cantidad, pe.fecha_compromiso
)
SELECT id_pedido, nro_linea, sku, fecha_compromiso, solicitado, despachado,
       solicitado - despachado AS faltante
  FROM lineas WHERE despachado < solicitado
 ORDER BY fecha_compromiso, id_pedido;
