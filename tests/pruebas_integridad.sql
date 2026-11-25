-- =============================================================================
-- Smart Inventory · Pruebas de integridad (matriz regla–restricción–prueba)
-- Ejecutar después de 01_schema.sql y 02_seed.sql:
--     psql -f tests/pruebas_integridad.sql
-- Cada prueba se ejecuta en una subtransacción y SIEMPRE se deshace, por lo
-- que el script es repetible y no altera los datos semilla.
-- Resultado: OK si el SQLSTATE obtenido coincide con el esperado
-- ('00000' = la operación debía ser aceptada).
-- =============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET search_path = si, public;

CREATE TEMP TABLE resultado_prueba (
  id text, regla text, descripcion text, esperado text, obtenido text, mensaje text
) ON COMMIT PRESERVE ROWS;

CREATE FUNCTION pg_temp.probar(p_id text, p_regla text, p_desc text, p_esperado text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_estado text := '00000'; v_msg text := 'aceptada';
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'deshacer prueba' USING ERRCODE = 'ZZ999';
  EXCEPTION
    WHEN SQLSTATE 'ZZ999' THEN NULL;                      -- éxito: se deshace igual
    WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_estado = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  INSERT INTO resultado_prueba VALUES (p_id, p_regla, p_desc, p_esperado, v_estado, v_msg);
END $$;

-- Atajos para escribir las pruebas
CREATE FUNCTION pg_temp.lote(p_sku text, p_num text) RETURNS int LANGUAGE sql AS $$
  SELECT l.id_lote FROM si.lote l JOIN si.producto p USING (id_producto)
   WHERE p.sku = p_sku AND l.numero_lote = p_num $$;
CREATE FUNCTION pg_temp.ubi(p_bod text, p_cod text) RETURNS int LANGUAGE sql AS $$
  SELECT u.id_ubicacion FROM si.ubicacion u JOIN si.bodega b USING (id_bodega)
   WHERE b.codigo = p_bod AND u.codigo = p_cod $$;

\o /dev/null
-- ---------------------------------------------------------------- mínimas del enunciado
SELECT pg_temp.probar('T01','R13','FK inválida: línea de pedido con producto inexistente','23503',
  $q$ INSERT INTO detalle_pedido (id_pedido, nro_linea, id_producto, cantidad) VALUES (12, 9, 99999, 1) $q$);

SELECT pg_temp.probar('T02','R06','Cantidad negativa en línea de orden de compra','23514',
  $q$ INSERT INTO detalle_compra (id_oc, nro_linea, id_producto, cantidad_pedida, costo_unitario)
      VALUES (10, 9, (SELECT id_producto FROM producto WHERE sku='LAC-LECHE-1L'), -5, 1) $q$);

SELECT pg_temp.probar('T03','R03','Clave duplicada: mismo número de lote para el mismo producto','23505',
  $q$ INSERT INTO lote (id_producto, numero_lote, fecha_fabricacion, fecha_vencimiento)
      SELECT id_producto, 'LE-2409A', current_date, current_date + 90 FROM producto WHERE sku='LAC-LECHE-1L' $q$);

SELECT pg_temp.probar('T04','R04','Fecha inconsistente: vencimiento anterior a la fabricación','23514',
  $q$ INSERT INTO lote (id_producto, numero_lote, fecha_fabricacion, fecha_vencimiento)
      SELECT id_producto, 'LE-X', current_date, current_date - 1 FROM producto WHERE sku='LAC-LECHE-1L' $q$);

SELECT pg_temp.probar('T05','R11','Transición no permitida: pedido DESPACHADO vuelve a ABIERTO','23514',
  $q$ UPDATE pedido SET estado = 'ABIERTO', despachado_en = NULL WHERE id_pedido = 1 $q$);

-- ---------------------------------------------------------------- dominio y claves
SELECT pg_temp.probar('T06','R11','Estado de pedido fuera del dominio','23514',
  $q$ INSERT INTO pedido (id_cliente, id_bodega, fecha_compromiso, estado) VALUES (1, 1, current_date, 'ENVIADO') $q$);

SELECT pg_temp.probar('T07','R02','SKU duplicado','23505',
  $q$ INSERT INTO producto (sku, nombre) VALUES ('LAC-LECHE-1L', 'Duplicado') $q$);

SELECT pg_temp.probar('T08','R02','Código de ubicación duplicado dentro de la misma bodega','23505',
  $q$ INSERT INTO ubicacion (id_bodega, codigo, zona, tipo)
      SELECT id_bodega, 'P-01', 'X', 'RACK' FROM bodega WHERE codigo = 'UIO' $q$);

SELECT pg_temp.probar('T09','R02','El mismo código de ubicación sí se permite en otra bodega','00000',
  $q$ INSERT INTO ubicacion (id_bodega, codigo, zona, tipo)
      SELECT id_bodega, 'P-02', 'PICKING', 'PICKING' FROM bodega WHERE codigo = 'GYE' $q$);

SELECT pg_temp.probar('T10','R18','Stock objetivo menor que el mínimo','23514',
  $q$ INSERT INTO producto (sku, nombre, stock_minimo, stock_objetivo) VALUES ('NUEVO-01', 'X', 50, 10) $q$);

SELECT pg_temp.probar('T11','R05','Producto con vencimiento exige fecha de vencimiento en el lote','23514',
  $q$ INSERT INTO lote (id_producto, numero_lote) SELECT id_producto, 'SIN-FECHA' FROM producto WHERE sku='FAR-PARA-500' $q$);

SELECT pg_temp.probar('T12','R05','Producto sin vencimiento acepta lote sin fecha','00000',
  $q$ INSERT INTO lote (id_producto, numero_lote) SELECT id_producto, 'TO-9999' FROM producto WHERE sku='FER-TORN-M6' $q$);

SELECT pg_temp.probar('T13','R19','Producto inactivo no admite nuevas líneas de pedido','23514',
  $q$ INSERT INTO detalle_pedido (id_pedido, nro_linea, id_producto, cantidad)
      SELECT 12, 9, id_producto, 1 FROM producto WHERE sku='LAC-QUESO-500' $q$);

SELECT pg_temp.probar('T14','R19','Producto con historial no se puede borrar','23503',
  $q$ DELETE FROM producto WHERE sku = 'LAC-QUESO-500' $q$);

-- ---------------------------------------------------------------- saldo y libro
SELECT pg_temp.probar('T15','R01','Ajuste de salida mayor que el saldo físico (stock negativo)','23514',
  $q$ INSERT INTO movimiento (tipo, id_lote, id_ubicacion_origen, cantidad, motivo)
      VALUES ('AJUSTE', pg_temp.lote('FAR-SUERO-500','SU-2411B'), pg_temp.ubi('UIO','P-01'), 4, 'merma') $q$);

SELECT pg_temp.probar('T16','R01','Traslado que dejaría lo reservado por encima del físico','23514',
  $q$ SELECT trasladar(pg_temp.lote('LAC-LECHE-1L','LE-2410B'), pg_temp.ubi('UIO','P-01'), pg_temp.ubi('UIO','P-02'), 20) $q$);

SELECT pg_temp.probar('T17','R07','Libro inmutable: UPDATE sobre movimiento','P0001',
  $q$ UPDATE movimiento SET cantidad = 1 WHERE id_movimiento = 1 $q$);

SELECT pg_temp.probar('T18','R07','Libro inmutable: DELETE sobre movimiento','P0001',
  $q$ DELETE FROM movimiento WHERE id_movimiento = 1 $q$);

SELECT pg_temp.probar('T19','R07','Libro inmutable: TRUNCATE sobre movimiento','P0001',
  $q$ TRUNCATE movimiento CASCADE $q$);

SELECT pg_temp.probar('T20','R08','La aplicación no puede escribir el saldo directamente','42501',
  $q$ SET LOCAL ROLE si_app; UPDATE existencia_lote SET cantidad_fisica = 999 $q$);

SELECT pg_temp.probar('T21','R08','La aplicación sí registra movimientos y el trigger actualiza el saldo','00000',
  $q$ SET LOCAL ROLE si_app;
      INSERT INTO movimiento (tipo, id_lote, id_ubicacion_destino, cantidad, motivo)
      VALUES ('AJUSTE', pg_temp.lote('FER-TORN-M6','TO-0001'), pg_temp.ubi('UIO','A-01-02'), 1, 'conteo');
      DO $d$ BEGIN
        IF (SELECT count(*) FROM si.v_conciliacion_fisico) <> 0 THEN RAISE EXCEPTION 'divergencia'; END IF;
      END $d$ $q$);

SELECT pg_temp.probar('T22','R06','SALIDA sin reserva asociada','23514',
  $q$ INSERT INTO movimiento (tipo, id_lote, id_ubicacion_origen, cantidad)
      VALUES ('SALIDA', pg_temp.lote('LAC-LECHE-1L','LE-2409A'), pg_temp.ubi('UIO','A-01-01'), 1) $q$);

SELECT pg_temp.probar('T23','R06','Tipo de movimiento fuera del dominio','23514',
  $q$ INSERT INTO movimiento (tipo, id_lote, id_ubicacion_destino, cantidad, motivo)
      VALUES ('REGALO', pg_temp.lote('LAC-LECHE-1L','LE-2409A'), pg_temp.ubi('UIO','A-01-01'), 1, 'x') $q$);

SELECT pg_temp.probar('T24','R20','Reverso que no es espejo del movimiento original','23514',
  $q$ INSERT INTO movimiento (tipo, id_lote, id_ubicacion_origen, cantidad, id_movimiento_revertido, motivo)
      SELECT 'REVERSO', id_lote, id_ubicacion_destino, cantidad - 1, id_movimiento, 'x'
        FROM movimiento WHERE tipo = 'ENTRADA' ORDER BY id_movimiento LIMIT 1 $q$);

SELECT pg_temp.probar('T25','R20','Un movimiento no se revierte dos veces','23505',
  $q$ INSERT INTO movimiento (tipo, id_lote, id_ubicacion_origen, id_ubicacion_destino, cantidad,
                              id_movimiento_revertido, motivo)
      SELECT 'REVERSO', id_lote, id_ubicacion_destino, id_ubicacion_origen, cantidad, id_movimiento, 'x'
        FROM movimiento WHERE id_movimiento = (SELECT id_movimiento_revertido FROM movimiento
                                                WHERE tipo = 'REVERSO' LIMIT 1) $q$);

-- ---------------------------------------------------------------- reservas
SELECT pg_temp.probar('T26','R09','Sobreasignación: reservar más que el disponible del lote','23514',
  $q$ INSERT INTO reserva (id_pedido, nro_linea, id_producto, id_lote, id_ubicacion, cantidad)
      SELECT 12, 1, id_producto, pg_temp.lote('LAC-LECHE-1L','LE-2410B'), pg_temp.ubi('UIO','P-01'), 11
        FROM producto WHERE sku = 'LAC-LECHE-1L' $q$);

SELECT pg_temp.probar('T27','R12','Reservar un lote de otro producto','23503',
  $q$ INSERT INTO reserva (id_pedido, nro_linea, id_producto, id_lote, id_ubicacion, cantidad)
      SELECT 12, 1, id_producto, pg_temp.lote('LAC-YOG-200','YO-2410C'), pg_temp.ubi('UIO','P-02'), 1
        FROM producto WHERE sku = 'LAC-LECHE-1L' $q$);

SELECT pg_temp.probar('T28','R10','Reservar un lote en una ubicación donde no existe','23503',
  $q$ INSERT INTO reserva (id_pedido, nro_linea, id_producto, id_lote, id_ubicacion, cantidad)
      SELECT 12, 1, id_producto, pg_temp.lote('LAC-LECHE-1L','LE-2409A'), pg_temp.ubi('UIO','P-02'), 1
        FROM producto WHERE sku = 'LAC-LECHE-1L' $q$);

SELECT pg_temp.probar('T29','R14','Reservar un lote vencido','23514',
  $q$ INSERT INTO pedido (id_cliente, id_bodega, fecha_compromiso) VALUES (1, 1, current_date + 1);
      INSERT INTO detalle_pedido VALUES (currval('si.pedido_id_pedido_seq'), 1,
             (SELECT id_producto FROM producto WHERE sku='LAC-YOG-200'), 1);
      INSERT INTO reserva (id_pedido, nro_linea, id_producto, id_lote, id_ubicacion, cantidad)
      VALUES (currval('si.pedido_id_pedido_seq'), 1, (SELECT id_producto FROM producto WHERE sku='LAC-YOG-200'),
              pg_temp.lote('LAC-YOG-200','YO-2409A'), pg_temp.ubi('UIO','P-02'), 1) $q$);

SELECT pg_temp.probar('T30','R14','Reservar stock en cuarentena','23514',
  $q$ INSERT INTO pedido (id_cliente, id_bodega, fecha_compromiso) VALUES (1, 1, current_date + 1);
      INSERT INTO detalle_pedido VALUES (currval('si.pedido_id_pedido_seq'), 1,
             (SELECT id_producto FROM producto WHERE sku='FAR-PARA-500'), 1);
      INSERT INTO reserva (id_pedido, nro_linea, id_producto, id_lote, id_ubicacion, cantidad)
      VALUES (currval('si.pedido_id_pedido_seq'), 1, (SELECT id_producto FROM producto WHERE sku='FAR-PARA-500'),
              pg_temp.lote('FAR-PARA-500','PA-2410'), pg_temp.ubi('UIO','Q-01'), 1) $q$);

SELECT pg_temp.probar('T31','R15','Una reserva CONSUMIDA no vuelve a ACTIVA','23514',
  $q$ UPDATE reserva SET estado = 'ACTIVA', cerrada_en = NULL WHERE estado = 'CONSUMIDA' $q$);

SELECT pg_temp.probar('T32','R16','Cancelar un pedido libera sus reservas y el saldo reservado vuelve','00000',
  $q$ SELECT cancelar_pedido(10);
      DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM si.reserva WHERE id_pedido = 10 AND estado = 'ACTIVA')
           OR (SELECT count(*) FROM si.v_conciliacion_reservado) <> 0
           OR (SELECT sum(cantidad_reservada) FROM si.existencia_lote e JOIN si.ubicacion u USING (id_ubicacion)
                WHERE u.id_bodega = 1) <> 0
        THEN RAISE EXCEPTION 'la cancelación no liberó el saldo'; END IF;
      END $d$ $q$);

-- ---------------------------------------------------------------- FEFO y atomicidad
SELECT pg_temp.probar('T33','R17','FEFO: toma primero el lote que vence antes y excluye el vencido','00000',
  $q$ INSERT INTO pedido (id_cliente, id_bodega, fecha_compromiso) VALUES (2, 1, current_date + 1);
      INSERT INTO detalle_pedido VALUES (currval('si.pedido_id_pedido_seq'), 1,
             (SELECT id_producto FROM producto WHERE sku='FAR-SUERO-500'), 6);
      DO $d$ DECLARE plan text; BEGIN
        PERFORM si.reservar_pedido(currval('si.pedido_id_pedido_seq')::int);
        SELECT string_agg(l.numero_lote || '=' || r.cantidad, ',' ORDER BY r.id_reserva) INTO plan
          FROM si.reserva r JOIN si.lote l USING (id_lote)
         WHERE r.id_pedido = currval('si.pedido_id_pedido_seq');
        IF plan <> 'SU-2411A=4,SU-2411B=2' THEN RAISE EXCEPTION 'plan FEFO inesperado: %', plan; END IF;
      END $d$ $q$);

SELECT pg_temp.probar('T34','R17','Fallo parcial: si una línea no se cubre, no queda ninguna reserva','00000',
  $q$ INSERT INTO pedido (id_cliente, id_bodega, fecha_compromiso) VALUES (2, 1, current_date + 1);
      INSERT INTO detalle_pedido VALUES
        (currval('si.pedido_id_pedido_seq'), 1, (SELECT id_producto FROM producto WHERE sku='LAC-LECHE-1L'), 5),
        (currval('si.pedido_id_pedido_seq'), 2, (SELECT id_producto FROM producto WHERE sku='FAR-SUERO-500'), 50);
      DO $d$ BEGIN
        BEGIN
          PERFORM si.reservar_pedido(currval('si.pedido_id_pedido_seq')::int);
          RAISE EXCEPTION 'debía fallar';
        EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
        END;
        IF EXISTS (SELECT 1 FROM si.reserva WHERE id_pedido = currval('si.pedido_id_pedido_seq'))
           OR (SELECT estado FROM si.pedido WHERE id_pedido = currval('si.pedido_id_pedido_seq')) <> 'ABIERTO'
        THEN RAISE EXCEPTION 'quedaron cambios parciales'; END IF;
      END $d$ $q$);

-- ---------------------------------------------------------------- compras y recepción
SELECT pg_temp.probar('T35','R21','Recepción parcial válida deja la OC en PARCIAL y genera ENTRADA','00000',
  $q$ INSERT INTO recepcion (id_oc, id_bodega) VALUES (10, 1);
      INSERT INTO lote (id_producto, numero_lote) SELECT id_producto, 'CI-0001' FROM producto WHERE sku='FER-CINTA-48';
      INSERT INTO recepcion_linea (id_recepcion, id_oc, nro_linea_oc, id_producto, id_lote, id_ubicacion, cantidad_recibida)
      SELECT currval('si.recepcion_id_recepcion_seq'), 10, 1, l.id_producto, l.id_lote, pg_temp.ubi('UIO','REC-01'), 25
        FROM lote l WHERE l.numero_lote = 'CI-0001';
      DO $d$ BEGIN
        IF (SELECT estado FROM si.orden_compra WHERE id_oc = 10) <> 'PARCIAL'
           OR NOT EXISTS (SELECT 1 FROM si.movimiento m JOIN si.recepcion_linea rl USING (id_recepcion_linea)
                           WHERE rl.id_oc = 10 AND m.tipo = 'ENTRADA' AND m.cantidad = 25)
        THEN RAISE EXCEPTION 'recepción parcial mal registrada'; END IF;
      END $d$ $q$);

SELECT pg_temp.probar('T36','R21','Sobre-recepción: recibir más de lo ordenado','23514',
  $q$ INSERT INTO recepcion (id_oc, id_bodega) VALUES (10, 1);
      INSERT INTO lote (id_producto, numero_lote) SELECT id_producto, 'CI-0002' FROM producto WHERE sku='FER-CINTA-48';
      INSERT INTO recepcion_linea (id_recepcion, id_oc, nro_linea_oc, id_producto, id_lote, id_ubicacion, cantidad_recibida)
      SELECT currval('si.recepcion_id_recepcion_seq'), 10, 1, l.id_producto, l.id_lote, pg_temp.ubi('UIO','REC-01'), 61
        FROM lote l WHERE l.numero_lote = 'CI-0002' $q$);

SELECT pg_temp.probar('T37','R21','Recepción de un producto que no está en esa línea de la OC','23503',
  $q$ INSERT INTO recepcion (id_oc, id_bodega) VALUES (10, 1);
      INSERT INTO recepcion_linea (id_recepcion, id_oc, nro_linea_oc, id_producto, id_lote, id_ubicacion, cantidad_recibida)
      SELECT currval('si.recepcion_id_recepcion_seq'), 10, 1, l.id_producto, l.id_lote, pg_temp.ubi('UIO','REC-01'), 1
        FROM lote l WHERE l.numero_lote = 'LE-2409A' $q$);

SELECT pg_temp.probar('T38','R21','Recepción en una OC cancelada','23514',
  $q$ INSERT INTO recepcion (id_oc, id_bodega) VALUES (7, 1);
      INSERT INTO recepcion_linea (id_recepcion, id_oc, nro_linea_oc, id_producto, id_lote, id_ubicacion, cantidad_recibida)
      SELECT currval('si.recepcion_id_recepcion_seq'), 7, 1, l.id_producto, l.id_lote, pg_temp.ubi('UIO','REC-01'), 1
        FROM lote l WHERE l.numero_lote = 'PA-2410' $q$);

SELECT pg_temp.probar('T39','R08','Conciliación final: libro y balance coinciden (0 filas)','00000',
  $q$ DO $d$ BEGIN
        IF (SELECT count(*) FROM si.v_conciliacion_fisico) + (SELECT count(*) FROM si.v_conciliacion_reservado) <> 0
        THEN RAISE EXCEPTION 'hay divergencias'; END IF;
      END $d$ $q$);

\o
-- ---------------------------------------------------------------- resumen
\pset null '—'
SELECT id, regla, descripcion, esperado, obtenido,
       CASE WHEN esperado = obtenido THEN 'OK' ELSE 'FALLA' END AS resultado,
       left(mensaje, 90) AS mensaje
  FROM resultado_prueba ORDER BY id;

SELECT count(*) AS pruebas,
       count(*) FILTER (WHERE esperado = obtenido) AS ok,
       count(*) FILTER (WHERE esperado <> obtenido) AS fallas
  FROM resultado_prueba;
