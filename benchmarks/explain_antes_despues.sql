-- =============================================================================
-- Smart Inventory · benchmarks/explain_antes_despues.sql
-- Compara EXPLAIN (ANALYZE, BUFFERS) de tres consultas críticas sin y con los
-- índices propuestos en 05_indexes_views.sql, y mide el costo de escritura.
-- Ejecutar sobre la base de volumen (ver README):
--     psql -d smart_inventory_perf -f benchmarks/explain_antes_despues.sql > evidencias/explain_antes_despues.txt
-- Cada consulta se ejecuta una vez para calentar caché y luego se mide, de modo
-- que ambas fases comparan con la caché caliente.
-- =============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET search_path = si, public;
SET max_parallel_workers_per_gather = 0;   -- planes comparables y legibles
\pset pager off

\set sku 'SKU-00823'
\set pedido 16403

-- ---------------------------------------------------------------- consultas críticas
-- C1 · Búsqueda FEFO (la ejecuta cada reserva; es la más sensible a latencia)
\set c1 'SELECT e.id_lote, l.numero_lote, e.id_ubicacion, l.fecha_vencimiento, e.cantidad_fisica - e.cantidad_reservada AS disponible FROM existencia_lote e JOIN lote l ON l.id_lote = e.id_lote JOIN ubicacion u ON u.id_ubicacion = e.id_ubicacion WHERE l.id_producto = (SELECT id_producto FROM producto WHERE sku = ' :'sku' ') AND u.id_bodega = 1 AND u.tipo <> ''CUARENTENA'' AND (l.fecha_vencimiento IS NULL OR l.fecha_vencimiento > current_date) AND e.cantidad_fisica > e.cantidad_reservada ORDER BY l.fecha_vencimiento NULLS LAST, l.recibido_en, l.numero_lote'
-- C2 · Lotes por vencer en 30 días (Q2)
\set c2 'SELECT p.sku, l.numero_lote, l.fecha_vencimiento, sum(e.cantidad_fisica) AS fisico FROM lote l JOIN producto p ON p.id_producto = l.id_producto JOIN existencia_lote e ON e.id_lote = l.id_lote AND e.cantidad_fisica > 0 WHERE l.fecha_vencimiento > current_date AND l.fecha_vencimiento <= current_date + 30 GROUP BY p.sku, l.numero_lote, l.fecha_vencimiento ORDER BY l.fecha_vencimiento'
-- C3 · Trazabilidad de un pedido (Q5 sin el origen del lote)
\set c3 'SELECT d.nro_linea, r.id_reserva, r.cantidad, l.numero_lote, m.id_movimiento, rl.id_oc FROM detalle_pedido d LEFT JOIN reserva r ON r.id_pedido = d.id_pedido AND r.nro_linea = d.nro_linea LEFT JOIN lote l ON l.id_lote = r.id_lote LEFT JOIN movimiento m ON m.id_reserva = r.id_reserva LEFT JOIN recepcion_linea rl ON rl.id_lote = l.id_lote WHERE d.id_pedido = ' :pedido

\echo '############## CARDINALIDADES DEL DATASET ##############'
SELECT relname AS tabla, n_live_tup AS filas
  FROM pg_stat_user_tables WHERE schemaname = 'si' ORDER BY n_live_tup DESC;

-- ================================================================ FASE 1: SIN ÍNDICES
DROP INDEX IF EXISTS ix_lote_producto_fefo, ix_existencia_con_disponible, ix_lote_vencimiento,
                     ix_reserva_linea, ix_recepcion_linea_lote, ix_movimiento_lote_fecha,
                     ix_reserva_existencia, ix_recepcion_linea_oc, ix_detalle_pedido_producto,
                     ix_pedido_compromiso, ix_pedido_abiertos;
ANALYZE;

\echo '############## FASE 1 · SIN ÍNDICES PROPUESTOS ##############'
\echo '---- C1 FEFO'
:c1 \g /dev/null
EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING) :c1;
\echo '---- C2 Vencimientos'
:c2 \g /dev/null
EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING) :c2;
\echo '---- C3 Trazabilidad'
:c3 \g /dev/null
EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING) :c3;

\echo '---- Costo de escritura sin índices: 2 000 traslados (se deshacen)'
\timing on
BEGIN;
SELECT count(trasladar(e.id_lote, e.id_ubicacion,
         (SELECT u2.id_ubicacion FROM ubicacion u2 WHERE u2.id_bodega = u.id_bodega AND u2.tipo = 'RACK'
           AND u2.id_ubicacion <> e.id_ubicacion LIMIT 1), 1))
  FROM (SELECT * FROM existencia_lote WHERE cantidad_fisica - cantidad_reservada > 1 ORDER BY id_lote LIMIT 2000) e
  JOIN ubicacion u ON u.id_ubicacion = e.id_ubicacion;
ROLLBACK;
\timing off

-- ================================================================ FASE 2: CON ÍNDICES
\echo '############## FASE 2 · CON ÍNDICES PROPUESTOS ##############'
\ir ../sql/05_indexes_views.sql
SET search_path = si, public;
SET max_parallel_workers_per_gather = 0;

\echo '---- C1 FEFO'
:c1 \g /dev/null
EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING) :c1;
\echo '---- C2 Vencimientos'
:c2 \g /dev/null
EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING) :c2;
\echo '---- C3 Trazabilidad'
:c3 \g /dev/null
EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING) :c3;

\echo '---- Costo de escritura con índices: 2 000 traslados (se deshacen)'
\timing on
BEGIN;
SELECT count(trasladar(e.id_lote, e.id_ubicacion,
         (SELECT u2.id_ubicacion FROM ubicacion u2 WHERE u2.id_bodega = u.id_bodega AND u2.tipo = 'RACK'
           AND u2.id_ubicacion <> e.id_ubicacion LIMIT 1), 1))
  FROM (SELECT * FROM existencia_lote WHERE cantidad_fisica - cantidad_reservada > 1 ORDER BY id_lote LIMIT 2000) e
  JOIN ubicacion u ON u.id_ubicacion = e.id_ubicacion;
ROLLBACK;
\timing off

\echo '---- Tamaño de los índices propuestos'
SELECT c.relname AS indice, t.relname AS tabla, pg_size_pretty(pg_relation_size(c.oid)) AS tamano
  FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_class t ON t.oid = i.indrelid
 WHERE c.relname LIKE 'ix\_%' ORDER BY pg_relation_size(c.oid) DESC;
