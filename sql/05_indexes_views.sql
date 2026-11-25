-- =============================================================================
-- Smart Inventory · 05_indexes_views.sql
-- Vistas de lectura para el dashboard e índices propuestos.
-- La justificación con planes medidos está en benchmarks/ y en el informe.
-- =============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET search_path = si, public;

-- =============================================================================
-- 1. Vistas del dashboard
-- Son vistas normales (no materializadas): se recalculan en cada lectura, por lo
-- que reflejan el último COMMIT sin proceso de refresco. Si el volumen creciera,
-- v_nivel_servicio_mensual es candidata a vista materializada con
-- REFRESH MATERIALIZED VIEW CONCURRENTLY cada 15 minutos, porque es histórica.
--
-- Ninguna es fuente de escritura: contienen agregaciones y joins (PostgreSQL
-- no las puede actualizar automáticamente) y además el rol si_app solo tiene
-- SELECT sobre ellas. Toda escritura pasa por el libro y las funciones de
-- negocio; si el dashboard escribiera sobre un agregado, el saldo dejaría de
-- ser trazable a lote y ubicación.
-- =============================================================================

-- 1.1 Disponibilidad por SKU y bodega (tarjetas y tabla principal del dashboard)
CREATE OR REPLACE VIEW v_stock_disponible AS
WITH saldo AS (
  SELECT l.id_producto, u.id_bodega,
         sum(e.cantidad_fisica)    AS fisico,
         sum(e.cantidad_reservada) AS reservado,
         sum(e.cantidad_fisica) FILTER (
            WHERE u.tipo = 'CUARENTENA' OR NOT u.activa OR l.fecha_vencimiento <= current_date) AS bloqueado,
         sum(e.cantidad_fisica - e.cantidad_reservada) FILTER (
            WHERE u.tipo <> 'CUARENTENA' AND u.activa
              AND (l.fecha_vencimiento IS NULL OR l.fecha_vencimiento > current_date)) AS disponible,
         min(l.fecha_vencimiento) FILTER (WHERE l.fecha_vencimiento > current_date) AS proximo_vencimiento,
         count(DISTINCT e.id_lote) AS lotes_con_saldo
    FROM existencia_lote e
    JOIN lote l      ON l.id_lote = e.id_lote
    JOIN ubicacion u ON u.id_ubicacion = e.id_ubicacion
   WHERE e.cantidad_fisica > 0
   GROUP BY l.id_producto, u.id_bodega
)
SELECT p.id_producto, p.sku, p.nombre, b.id_bodega, b.codigo AS bodega,
       coalesce(s.fisico, 0)     AS fisico,
       coalesce(s.reservado, 0)  AS reservado,
       coalesce(s.bloqueado, 0)  AS bloqueado,
       coalesce(s.disponible, 0) AS disponible,
       s.proximo_vencimiento,
       coalesce(s.lotes_con_saldo, 0) AS lotes_con_saldo
  FROM producto p
 CROSS JOIN bodega b
  LEFT JOIN saldo s ON s.id_producto = p.id_producto AND s.id_bodega = b.id_bodega
 WHERE p.activo AND b.activa;

-- 1.2 Alertas de reposición (misma definición que la consulta Q4)
CREATE OR REPLACE VIEW v_reposicion_sugerida AS
WITH stock AS (
  SELECT l.id_producto, sum(e.cantidad_fisica) AS fisico_vendible, sum(e.cantidad_reservada) AS reservado
    FROM existencia_lote e
    JOIN lote l      ON l.id_lote = e.id_lote
    JOIN ubicacion u ON u.id_ubicacion = e.id_ubicacion
   WHERE u.tipo <> 'CUARENTENA' AND u.activa
     AND (l.fecha_vencimiento IS NULL OR l.fecha_vencimiento > current_date)
   GROUP BY l.id_producto
), transito AS (
  SELECT d.id_producto, sum(d.cantidad_pedida - coalesce(r.recibido, 0)) AS en_ordenes_abiertas
    FROM detalle_compra d
    JOIN orden_compra oc ON oc.id_oc = d.id_oc AND oc.estado IN ('ABIERTA','PARCIAL')
    LEFT JOIN (SELECT id_oc, nro_linea_oc, sum(cantidad_recibida) AS recibido
                 FROM recepcion_linea GROUP BY id_oc, nro_linea_oc) r
           ON r.id_oc = d.id_oc AND r.nro_linea_oc = d.nro_linea
   GROUP BY d.id_producto
)
SELECT p.sku, p.nombre,
       coalesce(s.fisico_vendible, 0) AS fisico_vendible,
       coalesce(t.en_ordenes_abiertas, 0) AS en_ordenes_abiertas,
       coalesce(s.reservado, 0) AS reservado,
       coalesce(s.fisico_vendible, 0) + coalesce(t.en_ordenes_abiertas, 0) - coalesce(s.reservado, 0) AS posicion,
       p.stock_minimo, p.stock_objetivo,
       greatest(p.stock_objetivo - (coalesce(s.fisico_vendible, 0) + coalesce(t.en_ordenes_abiertas, 0)
                                    - coalesce(s.reservado, 0)), 0) AS sugerencia_compra,
       pr.nombre AS proveedor
  FROM producto p
  LEFT JOIN stock s      ON s.id_producto = p.id_producto
  LEFT JOIN transito t   ON t.id_producto = p.id_producto
  LEFT JOIN proveedor pr ON pr.id_proveedor = p.id_proveedor_pref
 WHERE p.activo
   AND coalesce(s.fisico_vendible, 0) + coalesce(t.en_ordenes_abiertas, 0) - coalesce(s.reservado, 0) < p.stock_minimo;

-- 1.3 Nivel de servicio mensual (misma definición que la consulta Q8, sin límite de periodo)
CREATE OR REPLACE VIEW v_nivel_servicio_mensual AS
WITH lineas AS (
  SELECT date_trunc('month', pe.fecha_compromiso)::date AS mes, d.cantidad AS solicitado,
         coalesce(sum(r.cantidad) FILTER (WHERE r.estado = 'CONSUMIDA'), 0) AS despachado,
         pe.despachado_en IS NOT NULL AND pe.despachado_en::date <= pe.fecha_compromiso AS a_tiempo
    FROM pedido pe
    JOIN detalle_pedido d ON d.id_pedido = pe.id_pedido
    LEFT JOIN reserva r   ON r.id_pedido = d.id_pedido AND r.nro_linea = d.nro_linea
   WHERE pe.estado <> 'CANCELADO' AND pe.fecha_compromiso < current_date
   GROUP BY pe.id_pedido, d.nro_linea, d.cantidad, pe.fecha_compromiso, pe.despachado_en
)
SELECT mes, count(*) AS lineas,
       count(*) FILTER (WHERE despachado >= solicitado AND a_tiempo) AS completas_a_tiempo,
       count(*) FILTER (WHERE despachado < solicitado) AS con_quiebre,
       round(100.0 * count(*) FILTER (WHERE despachado >= solicitado AND a_tiempo) / count(*), 1) AS nivel_servicio_pct,
       round(100.0 * sum(despachado) / nullif(sum(solicitado), 0), 1) AS fill_rate_pct
  FROM lineas
 GROUP BY mes;

GRANT SELECT ON v_stock_disponible, v_reposicion_sugerida, v_nivel_servicio_mensual,
                v_conciliacion_fisico, v_conciliacion_reservado TO si_app;
REVOKE INSERT, UPDATE, DELETE ON v_stock_disponible, v_reposicion_sugerida, v_nivel_servicio_mensual FROM si_app, PUBLIC;

-- =============================================================================
-- 2. Índices propuestos
-- PostgreSQL crea índices para PK y UNIQUE, pero NO para las FK. Se indexan
-- las búsquedas frecuentes y las FK que se usan en joins o en verificaciones
-- de borrado. Cada índice agrega costo a cada INSERT/UPDATE de su tabla, por
-- eso se evita indexar lo que ya cubre un índice existente (prefijo de una PK
-- o de un UNIQUE).
-- =============================================================================

-- 2.1 FEFO (consulta crítica 1). Se evaluó lote(id_producto, fecha_vencimiento,
-- recibido_en, numero_lote) y se DESCARTÓ: el plan medido no mejoró porque
-- uq_lote_producto_numero (id_producto, numero_lote) ya resuelve la búsqueda por
-- producto y cada SKU tiene pocos lotes vivos; ordenar 3–10 filas en memoria es
-- más barato que mantener otro índice en cada recepción (ver benchmarks/).
-- Se conserva solo el índice parcial sobre el saldo con disponible.

-- 2.2 FEFO: solo filas de saldo con disponible > 0. Índice parcial: la mayoría de
-- las filas históricas quedan en cero y no ocupan espacio en el índice.
CREATE INDEX IF NOT EXISTS ix_existencia_con_disponible
  ON existencia_lote (id_lote, id_ubicacion)
  INCLUDE (cantidad_fisica, cantidad_reservada)
  WHERE cantidad_fisica > cantidad_reservada;

-- 2.3 Vencimientos (consulta crítica 2): rango de fechas sobre lotes que vencen.
CREATE INDEX IF NOT EXISTS ix_lote_vencimiento
  ON lote (fecha_vencimiento) WHERE fecha_vencimiento IS NOT NULL;

-- 2.4 Trazabilidad (consulta crítica 3): reservas por línea de pedido (FK) ...
CREATE INDEX IF NOT EXISTS ix_reserva_linea
  ON reserva (id_pedido, nro_linea);
-- ... y recepciones de un lote (FK, también usada al rastrear el origen del lote).
CREATE INDEX IF NOT EXISTS ix_recepcion_linea_lote
  ON recepcion_linea (id_lote);

-- 2.5 FK usadas por la conciliación, la rotación y las verificaciones de borrado.
CREATE INDEX IF NOT EXISTS ix_movimiento_lote_fecha  ON movimiento (id_lote, ocurrido_en);
CREATE INDEX IF NOT EXISTS ix_reserva_existencia     ON reserva (id_lote, id_ubicacion) WHERE estado = 'ACTIVA';
CREATE INDEX IF NOT EXISTS ix_recepcion_linea_oc     ON recepcion_linea (id_oc, nro_linea_oc);
CREATE INDEX IF NOT EXISTS ix_detalle_pedido_producto ON detalle_pedido (id_producto);

-- 2.6 Pedidos por fecha de compromiso (nivel de servicio) y pedidos vivos.
CREATE INDEX IF NOT EXISTS ix_pedido_compromiso ON pedido (fecha_compromiso);
CREATE INDEX IF NOT EXISTS ix_pedido_abiertos   ON pedido (id_bodega, creado_en)
  WHERE estado IN ('ABIERTO','PARCIAL','RESERVADO');

-- Índices que NO se crean porque serían redundantes:
--   * existencia_lote(id_lote): prefijo de la PK (id_lote, id_ubicacion).
--   * detalle_compra(id_oc), detalle_pedido(id_pedido): prefijos de sus PK.
--   * lote(id_producto) solo: prefijo de uq_lote_producto_numero.
--   * movimiento(id_reserva), movimiento(id_recepcion_linea): ya tienen UNIQUE.
--   * producto(sku), ubicacion(id_bodega, codigo): ya tienen UNIQUE.

ANALYZE;
