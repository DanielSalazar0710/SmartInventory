-- =============================================================================
-- Smart Inventory · 02_seed.sql
-- Datos sintéticos (no reales) que cubren los casos límite del enunciado:
--   * dos bodegas, ubicaciones de recepción, rack, picking, cuarentena y despacho
--   * productos con y sin vencimiento, un producto inactivo con historial y
--     un producto nunca recibido (stock cero)
--   * lote vencido con saldo, lote próximo a vencer, lote agotado,
--     lote repartido en varias ubicaciones
--   * OC completa, parcial (dos recepciones), abierta sin recepción y cancelada
--   * pedidos despachados (a tiempo, tarde y parcial), reservado, abierto y
--     cancelado con reservas liberadas
--   * traslado, transferencia entre bodegas, ajuste (merma y conteo) y reverso
-- Las fechas son relativas a current_date para que las consultas de
-- vencimiento den el mismo resultado cualquier día que se ejecute el script.
-- Todo se carga por las funciones/tablas de negocio: el saldo de
-- existencia_lote lo calculan los triggers a partir del libro.
-- =============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET search_path = si, public;

-- Funciones auxiliares solo para la carga (se eliminan al final).
DROP SCHEMA IF EXISTS si_seed CASCADE;
CREATE SCHEMA si_seed;

CREATE FUNCTION si_seed.u(p_bodega text, p_codigo text) RETURNS int LANGUAGE sql STABLE AS $$
  SELECT u.id_ubicacion FROM si.ubicacion u JOIN si.bodega b USING (id_bodega)
   WHERE b.codigo = p_bodega AND u.codigo = p_codigo $$;
CREATE FUNCTION si_seed.p(p_sku text) RETURNS int LANGUAGE sql STABLE AS $$
  SELECT id_producto FROM si.producto WHERE sku = p_sku $$;
CREATE FUNCTION si_seed.l(p_sku text, p_lote text) RETURNS int LANGUAGE sql STABLE AS $$
  SELECT id_lote FROM si.lote WHERE id_producto = si_seed.p(p_sku) AND numero_lote = p_lote $$;
CREATE FUNCTION si_seed.d(p_dias int) RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT (current_date + p_dias) + time '10:00' $$;

-- Crea la OC con sus líneas. p_lineas = '{{sku,cant,costo},...}'
CREATE FUNCTION si_seed.oc(p_prov text, p_bodega text, p_emision int, p_espera int, p_lineas text[][])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v int; i int;
BEGIN
  INSERT INTO si.orden_compra (id_proveedor, id_bodega, fecha_emision, fecha_esperada)
  VALUES ((SELECT id_proveedor FROM si.proveedor WHERE codigo = p_prov),
          (SELECT id_bodega FROM si.bodega WHERE codigo = p_bodega),
          current_date + p_emision, current_date + p_espera)
  RETURNING id_oc INTO v;
  FOR i IN 1 .. array_length(p_lineas, 1) LOOP
    INSERT INTO si.detalle_compra (id_oc, nro_linea, id_producto, cantidad_pedida, costo_unitario)
    VALUES (v, i, si_seed.p(p_lineas[i][1]), p_lineas[i][2]::int, p_lineas[i][3]::numeric);
  END LOOP;
  RETURN v;
END $$;

-- Recibe una cantidad de una línea de OC en un lote y ubicación.
CREATE FUNCTION si_seed.recibir(p_rec int, p_oc int, p_sku text, p_lote text, p_fab int, p_venc int,
                                p_ubic text, p_cant int, p_dia int, p_guia text DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_rec int := p_rec; v_bod text; v_lote int;
BEGIN
  SELECT b.codigo INTO v_bod FROM si.orden_compra o JOIN si.bodega b USING (id_bodega) WHERE o.id_oc = p_oc;
  IF v_rec IS NULL THEN
    INSERT INTO si.recepcion (id_oc, id_bodega, recibido_en, guia_remision)
    SELECT p_oc, id_bodega, si_seed.d(p_dia), p_guia FROM si.orden_compra WHERE id_oc = p_oc
    RETURNING id_recepcion INTO v_rec;
  END IF;
  v_lote := si_seed.l(p_sku, p_lote);
  IF v_lote IS NULL THEN
    INSERT INTO si.lote (id_producto, numero_lote, fecha_fabricacion, fecha_vencimiento, recibido_en)
    VALUES (si_seed.p(p_sku), p_lote, current_date + p_fab,
            CASE WHEN p_venc IS NULL THEN NULL ELSE current_date + p_venc END, si_seed.d(p_dia))
    RETURNING id_lote INTO v_lote;
  END IF;
  INSERT INTO si.recepcion_linea (id_recepcion, id_oc, nro_linea_oc, id_producto, id_lote, id_ubicacion, cantidad_recibida)
  SELECT v_rec, p_oc, d.nro_linea, d.id_producto, v_lote, si_seed.u(v_bod, p_ubic), p_cant
    FROM si.detalle_compra d WHERE d.id_oc = p_oc AND d.id_producto = si_seed.p(p_sku);
  RETURN v_rec;
END $$;

-- Crea un pedido. p_lineas = '{{sku,cant},...}'
CREATE FUNCTION si_seed.pedido(p_cli text, p_bodega text, p_dia int, p_comp int, p_lineas text[][])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v int; i int;
BEGIN
  INSERT INTO si.pedido (id_cliente, id_bodega, creado_en, fecha_compromiso)
  VALUES ((SELECT id_cliente FROM si.cliente WHERE codigo = p_cli),
          (SELECT id_bodega FROM si.bodega WHERE codigo = p_bodega),
          si_seed.d(p_dia) - interval '2 hours', current_date + p_comp)
  RETURNING id_pedido INTO v;
  FOR i IN 1 .. array_length(p_lineas, 1) LOOP
    INSERT INTO si.detalle_pedido (id_pedido, nro_linea, id_producto, cantidad)
    VALUES (v, i, si_seed.p(p_lineas[i][1]), p_lineas[i][2]::int);
  END LOOP;
  RETURN v;
END $$;

-- -----------------------------------------------------------------------------
-- Catálogo
-- -----------------------------------------------------------------------------
INSERT INTO bodega (codigo, nombre, ciudad) VALUES
  ('UIO', 'Centro de distribución Quito', 'Quito'),
  ('GYE', 'Bodega Guayaquil',             'Guayaquil');

INSERT INTO ubicacion (id_bodega, codigo, zona, tipo)
SELECT b.id_bodega, x.codigo, x.zona, x.tipo
  FROM (VALUES
    ('UIO','REC-01','RECEPCION','RECEPCION'),
    ('UIO','A-01-01','A','RACK'),
    ('UIO','A-01-02','A','RACK'),
    ('UIO','B-01-01','B','RACK'),
    ('UIO','P-01','PICKING','PICKING'),
    ('UIO','P-02','PICKING','PICKING'),
    ('UIO','Q-01','CUARENTENA','CUARENTENA'),
    ('UIO','D-01','DESPACHO','DESPACHO'),
    ('GYE','REC-01','RECEPCION','RECEPCION'),
    ('GYE','A-01-01','A','RACK'),
    ('GYE','P-01','PICKING','PICKING'),
    ('GYE','Q-01','CUARENTENA','CUARENTENA')
  ) AS x(bod, codigo, zona, tipo)
  JOIN bodega b ON b.codigo = x.bod;

INSERT INTO proveedor (codigo, nombre, email, lead_time_dias, activo) VALUES
  ('PROV-LAC', 'Lácteos Andinos S.A.',        'pedidos@lacteosandinos.example', 3, true),
  ('PROV-FAR', 'Distribuidora Farma Pacífico', 'ventas@farmapacifico.example',  5, true),
  ('PROV-FER', 'Ferretería Industrial Norte',  'compras@ferrenorte.example',    7, true),
  ('PROV-OLD', 'Proveedor dado de baja',       NULL,                           10, false);

INSERT INTO producto (sku, nombre, unidad, controla_vencimiento, stock_minimo, stock_objetivo, id_proveedor_pref)
SELECT x.sku, x.nombre, x.unidad, x.vence, x.minimo, x.objetivo, pr.id_proveedor
  FROM (VALUES
    ('LAC-LECHE-1L',  'Leche UHT entera 1 L',            'UN',   true,  40, 150, 'PROV-LAC'),
    ('LAC-YOG-200',   'Yogur natural 200 g',             'UN',   true,  30,  80, 'PROV-LAC'),
    ('LAC-QUESO-500', 'Queso fresco 500 g (descontinuado)','UN', true,   0,   0, 'PROV-LAC'),
    ('FAR-PARA-500',  'Paracetamol 500 mg x 20',         'CAJA', true,  20,  60, 'PROV-FAR'),
    ('FAR-SUERO-500', 'Suero oral 500 ml',               'UN',   true,  10,  30, 'PROV-FAR'),
    ('FER-TORN-M6',   'Tornillo M6 x 30 (caja 100)',     'CAJA', false, 50, 200, 'PROV-FER'),
    ('FER-CINTA-48',  'Cinta de embalaje 48 mm',         'UN',   false, 80, 150, 'PROV-FER')
  ) AS x(sku, nombre, unidad, vence, minimo, objetivo, prov)
  JOIN proveedor pr ON pr.codigo = x.prov;

INSERT INTO cliente (codigo, nombre) VALUES
  ('CLI-001', 'Minimarket La Floresta'),
  ('CLI-002', 'Farmacia Central'),
  ('CLI-003', 'Ferretería El Tornillo'),
  ('CLI-004', 'Tienda Don Pepe'),
  ('CLI-005', 'Comisariato Costa');

-- -----------------------------------------------------------------------------
-- Historia operativa (orden cronológico: el saldo se construye con el libro)
-- -----------------------------------------------------------------------------
DO $$
DECLARE oc int; r int; pe int;
BEGIN
  -- Día -88: queso (producto que luego se descontinúa) -> lote que se agotará
  oc := si_seed.oc('PROV-LAC','UIO',-90,-88, '{{LAC-QUESO-500,60,2.10}}');
  PERFORM si_seed.recibir(NULL, oc, 'LAC-QUESO-500','Q-2408', -95, -35, 'A-01-02', 60, -88, 'GR-1001');

  -- Día -78: OC1 lácteos completa (leche + yogur)
  oc := si_seed.oc('PROV-LAC','UIO',-80,-78, '{{LAC-LECHE-1L,300,0.85},{LAC-YOG-200,200,0.55}}');
  r  := si_seed.recibir(NULL, oc, 'LAC-LECHE-1L','LE-2409A', -82, 95, 'A-01-01', 300, -78, 'GR-1002');
  PERFORM si_seed.recibir(r,  oc, 'LAC-YOG-200', 'YO-2409A', -80, -40, 'P-02',   200, -78);

  -- Día -75: pedido 1, despachado a tiempo
  pe := si_seed.pedido('CLI-001','UIO',-75,-74, '{{LAC-LECHE-1L,100},{LAC-YOG-200,80}}');
  PERFORM reservar_pedido(pe, false, si_seed.d(-75));
  PERFORM despachar_pedido(pe, si_seed.d(-74));

  -- Día -60: OC2 farmacia completa; parte del paracetamol pasa a cuarentena
  oc := si_seed.oc('PROV-FAR','UIO',-62,-60, '{{FAR-PARA-500,100,1.20},{FAR-SUERO-500,40,0.90}}');
  r  := si_seed.recibir(NULL, oc, 'FAR-PARA-500', 'PA-2410', -70, 400, 'B-01-01', 100, -60, 'GR-1003');
  PERFORM si_seed.recibir(r,  oc, 'FAR-SUERO-500','SU-2410', -65,  -3, 'P-01',     40, -60);
  PERFORM trasladar(si_seed.l('FAR-PARA-500','PA-2410'), si_seed.u('UIO','B-01-01'), si_seed.u('UIO','Q-01'), 20,
                    'Control de calidad: empaque dañado', si_seed.d(-59));

  -- Día -58: pedido 2, despachado tarde (compromiso -59)
  pe := si_seed.pedido('CLI-002','UIO',-60,-59, '{{LAC-LECHE-1L,50},{FAR-PARA-500,30}}');
  PERFORM reservar_pedido(pe, false, si_seed.d(-60));
  PERFORM despachar_pedido(pe, si_seed.d(-57));

  -- Día -55: pedido 3 de suero
  pe := si_seed.pedido('CLI-002','UIO',-55,-54, '{{FAR-SUERO-500,30}}');
  PERFORM reservar_pedido(pe, false, si_seed.d(-55));
  PERFORM despachar_pedido(pe, si_seed.d(-54));

  -- Día -50: OC4 tornillos UIO (sin vencimiento)
  oc := si_seed.oc('PROV-FER','UIO',-55,-50, '{{FER-TORN-M6,500,3.40}}');
  PERFORM si_seed.recibir(NULL, oc, 'FER-TORN-M6','TO-0001', -60, NULL, 'A-01-02', 500, -50, 'GR-1004');

  -- Día -45: pedido 4 tornillos
  pe := si_seed.pedido('CLI-003','UIO',-45,-43, '{{FER-TORN-M6,200}}');
  PERFORM reservar_pedido(pe, false, si_seed.d(-45));
  PERFORM despachar_pedido(pe, si_seed.d(-44));

  -- Día -42: pedido 5 de yogur; deja 12 unidades del lote YO-2409A, que vence el día -40
  pe := si_seed.pedido('CLI-004','UIO',-42,-41, '{{LAC-YOG-200,108}}');
  PERFORM reservar_pedido(pe, false, si_seed.d(-42));
  PERFORM despachar_pedido(pe, si_seed.d(-41));

  -- Día -40: OC5 tornillos GYE y transferencia de 50 cajas a UIO
  oc := si_seed.oc('PROV-FER','GYE',-45,-40, '{{FER-TORN-M6,300,3.40}}');
  PERFORM si_seed.recibir(NULL, oc, 'FER-TORN-M6','TO-0002', -50, NULL, 'A-01-01', 300, -40, 'GR-2001');
  PERFORM trasladar(si_seed.l('FER-TORN-M6','TO-0002'), si_seed.u('GYE','A-01-01'), si_seed.u('UIO','A-01-02'), 50,
                    NULL, si_seed.d(-39));

  -- Día -36: pedido 6 queso: agota el lote Q-2408
  pe := si_seed.pedido('CLI-001','UIO',-37,-36, '{{LAC-QUESO-500,60}}');
  PERFORM reservar_pedido(pe, false, si_seed.d(-37));
  PERFORM despachar_pedido(pe, si_seed.d(-36));

  -- Día -30: OC3 lácteos PARCIAL (dos recepciones; quedan 30 yogures pendientes)
  oc := si_seed.oc('PROV-LAC','UIO',-32,-28, '{{LAC-LECHE-1L,200,0.85},{LAC-YOG-200,150,0.55}}');
  r  := si_seed.recibir(NULL, oc, 'LAC-LECHE-1L','LE-2410B', -35, 20, 'REC-01', 120, -30, 'GR-1005');
  PERFORM si_seed.recibir(r,  oc, 'LAC-LECHE-1L','LE-2410C', -33, 60, 'REC-01',  80, -30);
  PERFORM si_seed.recibir(r,  oc, 'LAC-YOG-200', 'YO-2410B', -31,  5, 'P-02',    90, -30);
  -- reubicación del lote LE-2410B en dos ubicaciones (mismo lote, varias ubicaciones)
  PERFORM trasladar(si_seed.l('LAC-LECHE-1L','LE-2410B'), si_seed.u('UIO','REC-01'), si_seed.u('UIO','P-01'), 60,
                    NULL, si_seed.d(-29));
  PERFORM trasladar(si_seed.l('LAC-LECHE-1L','LE-2410B'), si_seed.u('UIO','REC-01'), si_seed.u('UIO','A-01-01'), 60,
                    NULL, si_seed.d(-29));
  PERFORM trasladar(si_seed.l('LAC-LECHE-1L','LE-2410C'), si_seed.u('UIO','REC-01'), si_seed.u('UIO','A-01-01'), 80,
                    NULL, si_seed.d(-29));
  r  := si_seed.recibir(NULL, oc, 'LAC-YOG-200', 'YO-2410C', -22, 25, 'P-02', 30, -20, 'GR-1006');

  -- Día -25: el queso se descontinúa (conserva su historial)
  UPDATE producto SET activo = false WHERE sku = 'LAC-QUESO-500';

  -- Día -15: OC cancelada (nunca se recibió)
  oc := si_seed.oc('PROV-FAR','UIO',-15,-10, '{{FAR-PARA-500,50,1.20}}');
  UPDATE orden_compra SET estado = 'CANCELADA' WHERE id_oc = oc;

  -- Día -15: pedido 7 con cinta sin stock -> se reserva parcial y se despacha incompleto (quiebre)
  pe := si_seed.pedido('CLI-003','UIO',-15,-14, '{{FER-TORN-M6,20},{FER-CINTA-48,10}}');
  PERFORM reservar_pedido(pe, true, si_seed.d(-15));
  PERFORM despachar_pedido(pe, si_seed.d(-14));

  -- Día -12: suero para el experimento FEFO: dos lotes elegibles (el lote SU-2410 ya venció)
  oc := si_seed.oc('PROV-FAR','UIO',-14,-12, '{{FAR-SUERO-500,7,0.90}}');
  r  := si_seed.recibir(NULL, oc, 'FAR-SUERO-500','SU-2411A', -40, 15, 'P-01', 4, -12, 'GR-1007');
  PERFORM si_seed.recibir(r,  oc, 'FAR-SUERO-500','SU-2411B', -20, 40, 'P-01', 3, -12);

  -- Día -10: pedido 8 de leche: FEFO toma LE-2410B (vence día +20) de dos ubicaciones
  pe := si_seed.pedido('CLI-004','UIO',-10,-9, '{{LAC-LECHE-1L,70}}');
  PERFORM reservar_pedido(pe, false, si_seed.d(-10));
  PERFORM despachar_pedido(pe, si_seed.d(-9));

  -- Día -10: OC abierta sin recepción en GYE (en tránsito)
  oc := si_seed.oc('PROV-FAR','GYE',-10,5, '{{FAR-PARA-500,80,1.20}}');

  -- Día -8: ajuste por merma y ajuste por conteo cíclico
  INSERT INTO movimiento (tipo, id_lote, id_ubicacion_origen, cantidad, ocurrido_en, motivo)
  VALUES ('AJUSTE', si_seed.l('LAC-LECHE-1L','LE-2409A'), si_seed.u('UIO','A-01-01'), 4, si_seed.d(-8),
          'Merma: envases rotos');
  INSERT INTO movimiento (tipo, id_lote, id_ubicacion_destino, cantidad, ocurrido_en, motivo)
  VALUES ('AJUSTE', si_seed.l('FER-TORN-M6','TO-0001'), si_seed.u('UIO','A-01-02'), 2, si_seed.d(-8),
          'Conteo cíclico: sobrante');

  -- Día -6: traslado registrado por error y su movimiento compensatorio (REVERSO)
  PERFORM trasladar(si_seed.l('FAR-PARA-500','PA-2410'), si_seed.u('UIO','B-01-01'), si_seed.u('UIO','P-02'), 15,
                    'Reposición a picking', si_seed.d(-6));
  INSERT INTO movimiento (tipo, id_lote, id_ubicacion_origen, id_ubicacion_destino, cantidad, ocurrido_en,
                          id_movimiento_revertido, motivo)
  SELECT 'REVERSO', m.id_lote, m.id_ubicacion_destino, m.id_ubicacion_origen, m.cantidad, si_seed.d(-6),
         m.id_movimiento, 'Error de digitación: el traslado no se ejecutó físicamente'
    FROM movimiento m
   WHERE m.tipo = 'TRASLADO' AND m.motivo = 'Reposición a picking';

  -- Día -5: OC abierta de cinta en UIO (en tránsito, aún sin recibir)
  oc := si_seed.oc('PROV-FER','UIO',-5,2, '{{FER-CINTA-48,60,0.75}}');

  -- Día -5: pedido 9 reservado y luego cancelado (reservas LIBERADAS)
  pe := si_seed.pedido('CLI-001','UIO',-5,-3, '{{LAC-YOG-200,20}}');
  PERFORM reservar_pedido(pe, false, si_seed.d(-5));
  PERFORM cancelar_pedido(pe, si_seed.d(-4));

  -- Día -1: pedido 10 reservado (pendiente de despacho) en UIO
  pe := si_seed.pedido('CLI-002','UIO',-1,1, '{{FAR-PARA-500,20},{LAC-LECHE-1L,40}}');
  PERFORM reservar_pedido(pe, false, si_seed.d(-1));

  -- Día -1: pedido 11 reservado en GYE
  pe := si_seed.pedido('CLI-005','GYE',-1,1, '{{FER-TORN-M6,30}}');
  PERFORM reservar_pedido(pe, false, si_seed.d(-1));

  -- Hoy: pedido 12 abierto, aún sin reservar
  pe := si_seed.pedido('CLI-004','UIO',0,2, '{{LAC-LECHE-1L,10},{LAC-YOG-200,5}}');
END $$;

DROP SCHEMA si_seed CASCADE;

-- Resumen de la carga
SELECT 'movimientos' AS tabla, count(*) FROM movimiento
UNION ALL SELECT 'existencias', count(*) FROM existencia_lote
UNION ALL SELECT 'lotes', count(*) FROM lote
UNION ALL SELECT 'pedidos', count(*) FROM pedido
UNION ALL SELECT 'reservas', count(*) FROM reserva
UNION ALL SELECT 'ordenes de compra', count(*) FROM orden_compra;
