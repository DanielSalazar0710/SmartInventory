-- =============================================================================
-- Smart Inventory · benchmarks/seed_volumen.sql
-- Datos sintéticos de volumen para medir planes de ejecución. Se cargan en una
-- base aparte (smart_inventory_perf) después de 01_schema.sql y 05_indexes_views.sql.
-- Todo entra por las tablas y funciones de negocio, así que los triggers
-- mantienen el balance igual que en operación.
-- Volumen obtenido: 3 bodegas, 300 ubicaciones, 2 000 SKU, 24 000 lotes, 26 384 saldos,
-- 20 000 pedidos, 50 000 líneas, 49 901 reservas y 74 530 movimientos (carga: ~9 min).
-- =============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET search_path = si, public;
SELECT setseed(0.42);

INSERT INTO bodega (codigo, nombre, ciudad) VALUES
  ('UIO','CD Quito','Quito'), ('GYE','CD Guayaquil','Guayaquil'), ('CUE','CD Cuenca','Cuenca');

INSERT INTO ubicacion (id_bodega, codigo, zona, tipo)
SELECT b.id_bodega, format('%s-%s', CASE WHEN g <= 2 THEN 'Q' WHEN g <= 30 THEN 'P' ELSE 'R' END, lpad(g::text, 3, '0')),
       CASE WHEN g <= 2 THEN 'CUARENTENA' WHEN g <= 30 THEN 'PICKING' ELSE 'RACK' END,
       CASE WHEN g <= 2 THEN 'CUARENTENA' WHEN g <= 30 THEN 'PICKING' ELSE 'RACK' END
  FROM bodega b CROSS JOIN generate_series(1, 100) g;

INSERT INTO proveedor (codigo, nombre, lead_time_dias)
SELECT format('PRV-%s', lpad(g::text, 3, '0')), format('Proveedor %s', g), 2 + (g % 10)
  FROM generate_series(1, 20) g;

INSERT INTO producto (sku, nombre, controla_vencimiento, stock_minimo, stock_objetivo, id_proveedor_pref)
SELECT format('SKU-%s', lpad(g::text, 5, '0')), format('Producto %s', g), g % 5 <> 0,
       20 + g % 50, 100 + g % 200, 1 + g % 20
  FROM generate_series(1, 2000) g;

INSERT INTO cliente (codigo, nombre)
SELECT format('C-%s', lpad(g::text, 5, '0')), format('Cliente %s', g) FROM generate_series(1, 500) g;

-- 6 000 órdenes de compra de 4 líneas, emitidas durante el último año
INSERT INTO orden_compra (id_proveedor, id_bodega, fecha_emision, fecha_esperada, estado)
SELECT 1 + g % 20, 1 + g % 3, current_date - 365 + (g * 360 / 6000), current_date - 360 + (g * 360 / 6000), 'ABIERTA'
  FROM generate_series(1, 6000) g;

INSERT INTO detalle_compra (id_oc, nro_linea, id_producto, cantidad_pedida, costo_unitario)
SELECT oc.id_oc, n, 1 + ((oc.id_oc * 7 + n * 499) % 2000), 300 + (oc.id_oc * n) % 700, 1.00 + n
  FROM orden_compra oc CROSS JOIN generate_series(1, 4) n;

-- Un lote por línea de OC
INSERT INTO lote (id_producto, numero_lote, fecha_fabricacion, fecha_vencimiento, recibido_en)
SELECT d.id_producto, format('L%s-%s', d.id_oc, d.nro_linea), oc.fecha_emision - 20,
       CASE WHEN p.controla_vencimiento THEN oc.fecha_esperada + 30 + ((d.id_oc * 13 + d.nro_linea * 17) % 370) END,
       oc.fecha_esperada + time '09:00'
  FROM detalle_compra d JOIN orden_compra oc USING (id_oc) JOIN producto p USING (id_producto);

INSERT INTO recepcion (id_oc, id_bodega, recibido_en, guia_remision)
SELECT id_oc, id_bodega, fecha_esperada + time '09:00', 'GR-' || id_oc
  FROM orden_compra WHERE id_oc % 10 <> 0 AND fecha_esperada < current_date;  -- 10 % quedan sin recibir

-- 85 % de las líneas se reciben completas, el resto parcialmente
INSERT INTO recepcion_linea (id_recepcion, id_oc, nro_linea_oc, id_producto, id_lote, id_ubicacion, cantidad_recibida)
SELECT r.id_recepcion, d.id_oc, d.nro_linea, d.id_producto, l.id_lote,
       (SELECT u.id_ubicacion FROM ubicacion u
         WHERE u.id_bodega = r.id_bodega AND u.tipo <> 'CUARENTENA'
         ORDER BY u.id_ubicacion OFFSET (d.id_oc * 3 + d.nro_linea) % 98 LIMIT 1),
       CASE WHEN (d.id_oc + d.nro_linea) % 7 = 0 THEN d.cantidad_pedida / 2 ELSE d.cantidad_pedida END
  FROM detalle_compra d
  JOIN recepcion r ON r.id_oc = d.id_oc
  JOIN lote l      ON l.id_producto = d.id_producto AND l.numero_lote = format('L%s-%s', d.id_oc, d.nro_linea)
 ORDER BY r.recibido_en;

-- Reubicaciones: 6 000 lotes se reparten en una segunda ubicación
SELECT count(trasladar(x.id_lote, x.id_ubicacion,
                       (SELECT u.id_ubicacion FROM ubicacion u
                         WHERE u.id_bodega = x.id_bodega AND u.tipo = 'PICKING' AND u.id_ubicacion <> x.id_ubicacion
                         ORDER BY u.id_ubicacion OFFSET x.id_lote % 27 LIMIT 1),
                       x.cantidad_recibida / 3, NULL, x.recibido_en + interval '1 day'))
  FROM (SELECT rl.id_lote, rl.id_ubicacion, u.id_bodega, rl.cantidad_recibida, r.recibido_en
          FROM recepcion_linea rl JOIN recepcion r USING (id_recepcion) JOIN ubicacion u USING (id_ubicacion)
         WHERE rl.id_lote % 4 = 0 AND r.recibido_en + interval '1 day' < now()) x;

-- 20 000 pedidos con 1 a 4 líneas a lo largo del año
INSERT INTO pedido (id_cliente, id_bodega, creado_en, fecha_compromiso)
SELECT 1 + g % 500, 1 + g % 3, ts, ts::date + 1 + g % 3
  FROM (SELECT g, now() - interval '360 days' + (g * interval '360 days' / 20000) - interval '1 hour' AS ts
          FROM generate_series(1, 20000) g) x;

INSERT INTO detalle_pedido (id_pedido, nro_linea, id_producto, cantidad)
SELECT p.id_pedido, n, 1 + ((p.id_pedido * 31 + n * 577) % 2000), 1 + (p.id_pedido + n) % 25
  FROM pedido p CROSS JOIN generate_series(1, 4) n
 WHERE n <= 1 + p.id_pedido % 4;

-- Reserva (parcial permitida) y despacho en orden cronológico; los pedidos de
-- los últimos 2 días quedan reservados sin despachar y el 3 % se cancela.
DO $$
DECLARE r record; est varchar;
BEGIN
  FOR r IN SELECT id_pedido, creado_en, fecha_compromiso FROM pedido ORDER BY creado_en LOOP
    est := reservar_pedido(r.id_pedido, true, r.creado_en);
    IF r.id_pedido % 33 = 0 THEN
      PERFORM cancelar_pedido(r.id_pedido, r.creado_en + interval '2 hours');
    ELSIF r.creado_en < now() - interval '2 days' THEN
      PERFORM despachar_pedido(r.id_pedido,
        least(r.creado_en + interval '20 hours' + (r.id_pedido % 5) * interval '12 hours', now()));
    END IF;
  END LOOP;
END $$;

ANALYZE;

SELECT 'producto' AS tabla, count(*) FROM producto UNION ALL
SELECT 'lote', count(*) FROM lote UNION ALL
SELECT 'existencia_lote', count(*) FROM existencia_lote UNION ALL
SELECT 'pedido', count(*) FROM pedido UNION ALL
SELECT 'detalle_pedido', count(*) FROM detalle_pedido UNION ALL
SELECT 'reserva', count(*) FROM reserva UNION ALL
SELECT 'movimiento', count(*) FROM movimiento UNION ALL
SELECT 'divergencias', (SELECT count(*) FROM v_conciliacion_fisico) + (SELECT count(*) FROM v_conciliacion_reservado);
