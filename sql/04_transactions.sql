-- =============================================================================
-- Smart Inventory · 04_transactions.sql
-- Transacciones: reserva FEFO atómica, fallo parcial con ROLLBACK, despacho con
-- COMMIT y la función de laboratorio usada en el experimento de concurrencia.
--
-- Requisito: 01_schema.sql y 02_seed.sql cargados.
-- Experimento automático con dos sesiones: tests/concurrencia/experimento.py
-- Guion manual (dos ventanas de psql/DBeaver): sección 5 de este archivo.
-- =============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = notice;
SET search_path = si, public;
\pset null '—'

-- -----------------------------------------------------------------------------
-- 1. Función de laboratorio para el experimento.
-- Misma lógica que si.reservar_fefo, con dos perillas:
--   p_bloquear = false -> lee el disponible SIN bloquear (patrón ingenuo
--                         "leer, decidir, escribir");
--   p_bloquear = true  -> SELECT ... FOR UPDATE en orden FEFO (estrategia elegida).
--   p_pausa            -> segundos de espera entre la lectura y la escritura, para
--                         abrir a propósito la ventana de carrera entre sesiones.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reservar_fefo_lab(p_id_pedido int, p_nro_linea smallint,
                                             p_bloquear boolean, p_pausa numeric DEFAULT 0)
RETURNS TABLE (numero_lote varchar, cantidad int)
LANGUAGE plpgsql AS $$
DECLARE v_prod int; v_cant int; v_bodega int; v_pend int; v_toma int; c record;
        v_plan jsonb := '[]';
BEGIN
  SELECT d.id_producto, d.cantidad, p.id_bodega INTO v_prod, v_cant, v_bodega
    FROM detalle_pedido d JOIN pedido p USING (id_pedido)
   WHERE d.id_pedido = p_id_pedido AND d.nro_linea = p_nro_linea;
  v_pend := v_cant;

  IF p_bloquear THEN
    FOR c IN
      SELECT e.id_lote, l.numero_lote, e.id_ubicacion, e.cantidad_fisica - e.cantidad_reservada AS disp
        FROM existencia_lote e JOIN lote l ON l.id_lote = e.id_lote
        JOIN ubicacion u ON u.id_ubicacion = e.id_ubicacion
       WHERE l.id_producto = v_prod AND u.id_bodega = v_bodega AND u.tipo <> 'CUARENTENA'
         AND (l.fecha_vencimiento IS NULL OR l.fecha_vencimiento > current_date)
         AND e.cantidad_fisica - e.cantidad_reservada > 0
       ORDER BY l.fecha_vencimiento NULLS LAST, l.recibido_en, l.numero_lote, u.codigo
         FOR UPDATE OF e
    LOOP
      EXIT WHEN v_pend <= 0;
      v_toma := least(c.disp, v_pend);
      v_plan := v_plan || jsonb_build_object('lote', c.id_lote, 'num', c.numero_lote,
                                             'ubi', c.id_ubicacion, 'q', v_toma);
      v_pend := v_pend - v_toma;
    END LOOP;
  ELSE
    FOR c IN
      SELECT e.id_lote, l.numero_lote, e.id_ubicacion, e.cantidad_fisica - e.cantidad_reservada AS disp
        FROM existencia_lote e JOIN lote l ON l.id_lote = e.id_lote
        JOIN ubicacion u ON u.id_ubicacion = e.id_ubicacion
       WHERE l.id_producto = v_prod AND u.id_bodega = v_bodega AND u.tipo <> 'CUARENTENA'
         AND (l.fecha_vencimiento IS NULL OR l.fecha_vencimiento > current_date)
         AND e.cantidad_fisica - e.cantidad_reservada > 0
       ORDER BY l.fecha_vencimiento NULLS LAST, l.recibido_en, l.numero_lote, u.codigo
    LOOP
      EXIT WHEN v_pend <= 0;
      v_toma := least(c.disp, v_pend);
      v_plan := v_plan || jsonb_build_object('lote', c.id_lote, 'num', c.numero_lote,
                                             'ubi', c.id_ubicacion, 'q', v_toma);
      v_pend := v_pend - v_toma;
    END LOOP;
  END IF;

  IF v_pend > 0 THEN
    RAISE EXCEPTION 'Stock insuficiente para pedido % línea %: faltan % unidades',
      p_id_pedido, p_nro_linea, v_pend USING ERRCODE = 'P0002';
  END IF;

  PERFORM pg_sleep(p_pausa);   -- ventana de carrera: la decisión ya está tomada

  FOR c IN SELECT * FROM jsonb_to_recordset(v_plan) AS x(lote int, num varchar, ubi int, q int) LOOP
    INSERT INTO reserva (id_pedido, nro_linea, id_producto, id_lote, id_ubicacion, cantidad)
    VALUES (p_id_pedido, p_nro_linea, v_prod, c.lote, c.ubi, c.q);
    numero_lote := c.num; cantidad := c.q;
    RETURN NEXT;
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Reserva FEFO atómica que divide la demanda entre lotes y excluye el vencido.
-- Caso del enunciado: FAR-SUERO-500 tiene SU-2410 (vencido, 10 u), SU-2411A
-- (vence en 15 días, 4 u) y SU-2411B (vence en 40 días, 3 u). Se piden 6.
-- Se termina con ROLLBACK para dejar intacto el escenario del experimento.
-- -----------------------------------------------------------------------------
\echo '== 2. Reserva FEFO atómica (6 unidades de FAR-SUERO-500) =='
BEGIN;
  INSERT INTO pedido (id_cliente, id_bodega, fecha_compromiso)
  SELECT c.id_cliente, b.id_bodega, current_date + 1
    FROM cliente c, bodega b WHERE c.codigo = 'CLI-002' AND b.codigo = 'UIO';
  INSERT INTO detalle_pedido (id_pedido, nro_linea, id_producto, cantidad)
  SELECT currval('pedido_id_pedido_seq'), 1, id_producto, 6 FROM producto WHERE sku = 'FAR-SUERO-500';

  SELECT * FROM reservar_fefo(currval('pedido_id_pedido_seq')::int, 1::smallint);

  -- saldo después de reservar (dentro de la misma transacción)
  SELECT l.numero_lote, l.fecha_vencimiento, e.cantidad_fisica, e.cantidad_reservada,
         e.cantidad_fisica - e.cantidad_reservada AS disponible
    FROM existencia_lote e JOIN lote l USING (id_lote)
   WHERE l.id_producto = (SELECT id_producto FROM producto WHERE sku = 'FAR-SUERO-500')
   ORDER BY l.fecha_vencimiento;
ROLLBACK;

-- -----------------------------------------------------------------------------
-- 3. Fallo parcial. La línea 1 se puede cubrir, la línea 2 no. reservar_pedido
-- lanza P0002 y la transacción completa vuelve atrás: no queda reserva de la
-- línea 1, el saldo reservado no cambia y el pedido sigue ABIERTO.
-- Tablas que deben volver juntas: reserva, existencia_lote (cantidad_reservada)
-- y pedido (estado). Por eso todo ocurre en una sola transacción.
-- -----------------------------------------------------------------------------
\echo '== 3. Fallo parcial: la última asignación falla y todo vuelve atrás =='
CREATE TEMP TABLE antes AS SELECT sum(cantidad_reservada) AS reservado FROM existencia_lote;
INSERT INTO pedido (id_cliente, id_bodega, fecha_compromiso)
SELECT c.id_cliente, b.id_bodega, current_date + 1
  FROM cliente c, bodega b WHERE c.codigo = 'CLI-001' AND b.codigo = 'UIO';
SELECT currval('pedido_id_pedido_seq') AS p_fallo \gset
INSERT INTO detalle_pedido (id_pedido, nro_linea, id_producto, cantidad)
SELECT :p_fallo, 1, id_producto, 5  FROM producto WHERE sku = 'LAC-LECHE-1L' UNION ALL
SELECT :p_fallo, 2, id_producto, 50 FROM producto WHERE sku = 'FAR-SUERO-500';

\set ON_ERROR_STOP off
BEGIN;
  SELECT reservar_pedido(:p_fallo);        -- falla en la línea 2 (P0002)
COMMIT;                                     -- en una transacción abortada COMMIT equivale a ROLLBACK
\set ON_ERROR_STOP on

SELECT (SELECT count(*) FROM reserva WHERE id_pedido = :p_fallo) AS reservas_del_pedido,
       (SELECT estado FROM pedido WHERE id_pedido = :p_fallo)    AS estado_pedido,
       (SELECT reservado FROM antes) = (SELECT sum(cantidad_reservada) FROM existencia_lote) AS saldo_reservado_intacto;
SELECT cancelar_pedido(:p_fallo);           -- el pedido de prueba se cierra
DROP TABLE antes;

-- -----------------------------------------------------------------------------
-- 4. Camino feliz con COMMIT: el pedido 12 (ABIERTO) se reserva y se despacha.
-- Cada paso es una transacción: reservar (bloquea filas de saldo un instante)
-- y despachar (consume reservas y registra SALIDAS en el libro).
-- -----------------------------------------------------------------------------
\echo '== 4. Reserva y despacho del pedido 12 con COMMIT =='
BEGIN;
  SELECT reservar_pedido(12) AS estado_pedido;
COMMIT;
BEGIN;
  SELECT despachar_pedido(12) AS reservas_consumidas;
COMMIT;
SELECT r.nro_linea, l.numero_lote, u.codigo AS ubicacion, r.cantidad, r.estado, m.id_movimiento AS salida
  FROM reserva r JOIN lote l USING (id_lote) JOIN ubicacion u USING (id_ubicacion)
  LEFT JOIN movimiento m ON m.id_reserva = r.id_reserva
 WHERE r.id_pedido = 12 ORDER BY r.nro_linea, r.id_reserva;
SELECT (SELECT count(*) FROM v_conciliacion_fisico)    AS divergencias_fisico,
       (SELECT count(*) FROM v_conciliacion_reservado) AS divergencias_reservado;

-- -----------------------------------------------------------------------------
-- 5. Guion manual con dos sesiones (abrir dos ventanas de psql o DBeaver).
--    Recargar 01_schema.sql y 02_seed.sql antes de cada escenario.
--    Preparación (cualquier sesión):
--      INSERT INTO si.pedido (id_cliente, id_bodega, fecha_compromiso) VALUES (1,1,current_date+1),(2,1,current_date+1);
--      -- supongamos que se crearon los pedidos 13 (A) y 14 (B)
--      INSERT INTO si.detalle_pedido VALUES (13,1,5,5), (14,1,5,5);   -- id_producto 5 = FAR-SUERO-500
--
--  Escenario 1 · READ COMMITTED sin bloqueo (patrón ingenuo)
--    A: BEGIN; SELECT * FROM si.reservar_fefo_lab(13,1::smallint,false,8);   -- decide y espera 8 s
--    B: BEGIN; SELECT * FROM si.reservar_fefo_lab(14,1::smallint,false,0);   -- decide con el mismo saldo
--    B: COMMIT;          A: COMMIT;   -> A falla con 23514 al escribir (el CHECK evita la sobreventa,
--                                       pero la decisión de A se tomó con datos obsoletos)
--
--  Escenario 2 · READ COMMITTED + SELECT ... FOR UPDATE (estrategia elegida)
--    A: BEGIN; SELECT * FROM si.reservar_fefo_lab(13,1::smallint,true,8);    -- bloquea los lotes FEFO
--    B: BEGIN; SELECT * FROM si.reservar_fefo_lab(14,1::smallint,true,0);    -- queda ESPERANDO
--    A: COMMIT;          -> B se despierta, re-evalúa el saldo confirmado y falla limpio con P0002
--    B: ROLLBACK;
--
--  Escenario 3 · SERIALIZABLE sin bloqueo explícito
--    A: BEGIN ISOLATION LEVEL SERIALIZABLE; SELECT * FROM si.reservar_fefo_lab(13,1::smallint,false,8);
--    B: BEGIN ISOLATION LEVEL SERIALIZABLE; SELECT * FROM si.reservar_fefo_lab(14,1::smallint,false,0);
--    B: COMMIT;          A: COMMIT;   -> una de las dos recibe 40001 y el cliente debe reintentar
--
--  Escenario 4 · Deadlock por orden de bloqueo inconsistente
--    A: BEGIN; SELECT 1 FROM si.existencia_lote WHERE id_lote = <SU-2411A> FOR UPDATE;
--    B: BEGIN; SELECT 1 FROM si.existencia_lote WHERE id_lote = <SU-2411B> FOR UPDATE;
--    A: SELECT 1 FROM si.existencia_lote WHERE id_lote = <SU-2411B> FOR UPDATE;   -- espera
--    B: SELECT 1 FROM si.existencia_lote WHERE id_lote = <SU-2411A> FOR UPDATE;   -- 40P01 deadlock
-- -----------------------------------------------------------------------------
