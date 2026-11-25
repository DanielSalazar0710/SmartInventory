-- =============================================================================
-- Smart Inventory · 01_schema.sql
-- Esquema relacional en PostgreSQL 16: tablas, claves, CHECK, UNIQUE, triggers
-- de integridad y funciones transaccionales (recepción, reserva FEFO, despacho).
--
-- Decisión central (ver docs/informe): MODELO HÍBRIDO.
--   * movimiento   = libro (ledger) inmutable, fuente de verdad.
--   * existencia_lote = balance por (lote, ubicación), derivado y escrito SOLO
--     por triggers SECURITY DEFINER en la misma transacción que el movimiento.
--   * v_conciliacion_* (05_indexes_views.sql) debe devolver 0 filas.
-- =============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP SCHEMA IF EXISTS si CASCADE;
CREATE SCHEMA si;
SET search_path = si, public;

-- Rol de la aplicación (no es dueño de las tablas). Se crea solo si no existe.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'si_app') THEN
    CREATE ROLE si_app NOLOGIN;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. Catálogo y almacén
-- -----------------------------------------------------------------------------
CREATE TABLE bodega (
  id_bodega     integer GENERATED ALWAYS AS IDENTITY,
  codigo        varchar(10)  NOT NULL,
  nombre        varchar(80)  NOT NULL,
  ciudad        varchar(60)  NOT NULL,
  activa        boolean      NOT NULL DEFAULT true,
  CONSTRAINT pk_bodega PRIMARY KEY (id_bodega),
  CONSTRAINT uq_bodega_codigo UNIQUE (codigo),
  CONSTRAINT ck_bodega_codigo CHECK (codigo ~ '^[A-Z0-9-]{2,10}$')
);

CREATE TABLE ubicacion (
  id_ubicacion  integer GENERATED ALWAYS AS IDENTITY,
  id_bodega     integer      NOT NULL,
  codigo        varchar(20)  NOT NULL,
  zona          varchar(20)  NOT NULL,
  tipo          varchar(12)  NOT NULL,
  activa        boolean      NOT NULL DEFAULT true,
  CONSTRAINT pk_ubicacion PRIMARY KEY (id_ubicacion),
  CONSTRAINT fk_ubicacion_bodega FOREIGN KEY (id_bodega)
    REFERENCES bodega (id_bodega) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT uq_ubicacion_bodega_codigo UNIQUE (id_bodega, codigo),
  CONSTRAINT ck_ubicacion_tipo CHECK (tipo IN ('RECEPCION','RACK','PICKING','CUARENTENA','DESPACHO'))
);

CREATE TABLE proveedor (
  id_proveedor  integer GENERATED ALWAYS AS IDENTITY,
  codigo        varchar(12)  NOT NULL,
  nombre        varchar(100) NOT NULL,
  email         varchar(120),
  lead_time_dias smallint    NOT NULL DEFAULT 7,
  activo        boolean      NOT NULL DEFAULT true,
  CONSTRAINT pk_proveedor PRIMARY KEY (id_proveedor),
  CONSTRAINT uq_proveedor_codigo UNIQUE (codigo),
  CONSTRAINT uq_proveedor_email UNIQUE (email),
  CONSTRAINT ck_proveedor_lead_time CHECK (lead_time_dias BETWEEN 0 AND 180),
  CONSTRAINT ck_proveedor_email CHECK (email IS NULL OR email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

CREATE TABLE producto (
  id_producto          integer GENERATED ALWAYS AS IDENTITY,
  sku                  varchar(20)  NOT NULL,
  nombre               varchar(120) NOT NULL,
  unidad               varchar(10)  NOT NULL DEFAULT 'UN',
  controla_vencimiento boolean      NOT NULL DEFAULT true,
  stock_minimo         integer      NOT NULL DEFAULT 0,
  stock_objetivo       integer      NOT NULL DEFAULT 0,
  id_proveedor_pref    integer,
  activo               boolean      NOT NULL DEFAULT true,
  CONSTRAINT pk_producto PRIMARY KEY (id_producto),
  CONSTRAINT uq_producto_sku UNIQUE (sku),
  CONSTRAINT fk_producto_proveedor_pref FOREIGN KEY (id_proveedor_pref)
    REFERENCES proveedor (id_proveedor) ON UPDATE RESTRICT ON DELETE SET NULL,
  CONSTRAINT ck_producto_sku CHECK (sku ~ '^[A-Z0-9-]{3,20}$'),
  CONSTRAINT ck_producto_unidad CHECK (unidad IN ('UN','CAJA','KG','L','PAQ')),
  CONSTRAINT ck_producto_minimo CHECK (stock_minimo >= 0),
  CONSTRAINT ck_producto_objetivo CHECK (stock_objetivo >= stock_minimo)
);

CREATE TABLE lote (
  id_lote            integer GENERATED ALWAYS AS IDENTITY,
  id_producto        integer      NOT NULL,
  numero_lote        varchar(30)  NOT NULL,
  fecha_fabricacion  date,
  fecha_vencimiento  date,          -- NULL solo si el producto no controla vencimiento
  recibido_en        timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT pk_lote PRIMARY KEY (id_lote),
  CONSTRAINT fk_lote_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT uq_lote_producto_numero UNIQUE (id_producto, numero_lote),
  -- destino de FK compuestas: garantiza que un lote se use con SU producto
  CONSTRAINT uq_lote_id_producto UNIQUE (id_lote, id_producto),
  CONSTRAINT ck_lote_fechas CHECK (fecha_vencimiento IS NULL OR fecha_fabricacion IS NULL
                                   OR fecha_vencimiento > fecha_fabricacion)
);

-- Balance por lote y ubicación (dato derivado del libro; ver triggers).
CREATE TABLE existencia_lote (
  id_lote             integer NOT NULL,
  id_ubicacion        integer NOT NULL,
  cantidad_fisica     integer NOT NULL DEFAULT 0,
  cantidad_reservada  integer NOT NULL DEFAULT 0,
  actualizado_en      timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT pk_existencia_lote PRIMARY KEY (id_lote, id_ubicacion),
  CONSTRAINT fk_existencia_lote FOREIGN KEY (id_lote)
    REFERENCES lote (id_lote) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_existencia_ubicacion FOREIGN KEY (id_ubicacion)
    REFERENCES ubicacion (id_ubicacion) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT ck_existencia_fisica CHECK (cantidad_fisica >= 0),
  CONSTRAINT ck_existencia_reservada CHECK (cantidad_reservada >= 0
                                            AND cantidad_reservada <= cantidad_fisica)
);

-- -----------------------------------------------------------------------------
-- 2. Reposición y compras
-- -----------------------------------------------------------------------------
CREATE TABLE orden_compra (
  id_oc           integer GENERATED ALWAYS AS IDENTITY,
  id_proveedor    integer     NOT NULL,
  id_bodega       integer     NOT NULL,
  fecha_emision   date        NOT NULL DEFAULT current_date,
  fecha_esperada  date        NOT NULL,
  estado          varchar(10) NOT NULL DEFAULT 'ABIERTA',
  CONSTRAINT pk_orden_compra PRIMARY KEY (id_oc),
  CONSTRAINT fk_oc_proveedor FOREIGN KEY (id_proveedor)
    REFERENCES proveedor (id_proveedor) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_oc_bodega FOREIGN KEY (id_bodega)
    REFERENCES bodega (id_bodega) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT uq_oc_id_bodega UNIQUE (id_oc, id_bodega),
  CONSTRAINT ck_oc_estado CHECK (estado IN ('ABIERTA','PARCIAL','COMPLETA','CANCELADA')),
  CONSTRAINT ck_oc_fechas CHECK (fecha_esperada >= fecha_emision)
);

CREATE TABLE detalle_compra (
  id_oc            integer       NOT NULL,
  nro_linea        smallint      NOT NULL,
  id_producto      integer       NOT NULL,
  cantidad_pedida  integer       NOT NULL,
  costo_unitario   numeric(12,2) NOT NULL,
  CONSTRAINT pk_detalle_compra PRIMARY KEY (id_oc, nro_linea),
  CONSTRAINT fk_detalle_compra_oc FOREIGN KEY (id_oc)
    REFERENCES orden_compra (id_oc) ON UPDATE RESTRICT ON DELETE CASCADE,
  CONSTRAINT fk_detalle_compra_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT uq_detalle_compra_producto UNIQUE (id_oc, id_producto),
  CONSTRAINT uq_detalle_compra_linea_producto UNIQUE (id_oc, nro_linea, id_producto),
  CONSTRAINT ck_detalle_compra_linea CHECK (nro_linea > 0),
  CONSTRAINT ck_detalle_compra_cantidad CHECK (cantidad_pedida > 0),
  CONSTRAINT ck_detalle_compra_costo CHECK (costo_unitario >= 0)
);

CREATE TABLE recepcion (
  id_recepcion    integer GENERATED ALWAYS AS IDENTITY,
  id_oc           integer      NOT NULL,
  id_bodega       integer      NOT NULL,
  recibido_en     timestamptz  NOT NULL DEFAULT now(),
  guia_remision   varchar(30),
  CONSTRAINT pk_recepcion PRIMARY KEY (id_recepcion),
  -- la recepción ocurre en la bodega de la OC
  CONSTRAINT fk_recepcion_oc_bodega FOREIGN KEY (id_oc, id_bodega)
    REFERENCES orden_compra (id_oc, id_bodega) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT uq_recepcion_id_oc UNIQUE (id_recepcion, id_oc)
);

-- Cada línea recibida queda vinculada a línea de OC, lote, ubicación y movimiento.
CREATE TABLE recepcion_linea (
  id_recepcion_linea integer GENERATED ALWAYS AS IDENTITY,
  id_recepcion       integer  NOT NULL,
  id_oc              integer  NOT NULL,
  nro_linea_oc       smallint NOT NULL,
  id_producto        integer  NOT NULL,
  id_lote            integer  NOT NULL,
  id_ubicacion       integer  NOT NULL,
  cantidad_recibida  integer  NOT NULL,
  CONSTRAINT pk_recepcion_linea PRIMARY KEY (id_recepcion_linea),
  CONSTRAINT fk_rl_recepcion FOREIGN KEY (id_recepcion, id_oc)
    REFERENCES recepcion (id_recepcion, id_oc) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_rl_detalle_compra FOREIGN KEY (id_oc, nro_linea_oc, id_producto)
    REFERENCES detalle_compra (id_oc, nro_linea, id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_rl_lote_producto FOREIGN KEY (id_lote, id_producto)
    REFERENCES lote (id_lote, id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_rl_ubicacion FOREIGN KEY (id_ubicacion)
    REFERENCES ubicacion (id_ubicacion) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT ck_rl_cantidad CHECK (cantidad_recibida > 0)
);

-- -----------------------------------------------------------------------------
-- 3. Fulfillment
-- -----------------------------------------------------------------------------
CREATE TABLE cliente (
  id_cliente  integer GENERATED ALWAYS AS IDENTITY,
  codigo      varchar(12)  NOT NULL,
  nombre      varchar(100) NOT NULL,
  CONSTRAINT pk_cliente PRIMARY KEY (id_cliente),
  CONSTRAINT uq_cliente_codigo UNIQUE (codigo)
);

CREATE TABLE pedido (
  id_pedido         integer GENERATED ALWAYS AS IDENTITY,
  id_cliente        integer      NOT NULL,
  id_bodega         integer      NOT NULL,
  creado_en         timestamptz  NOT NULL DEFAULT now(),
  fecha_compromiso  date         NOT NULL,
  estado            varchar(10)  NOT NULL DEFAULT 'ABIERTO',
  despachado_en     timestamptz,
  CONSTRAINT pk_pedido PRIMARY KEY (id_pedido),
  CONSTRAINT fk_pedido_cliente FOREIGN KEY (id_cliente)
    REFERENCES cliente (id_cliente) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_pedido_bodega FOREIGN KEY (id_bodega)
    REFERENCES bodega (id_bodega) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT ck_pedido_estado CHECK (estado IN ('ABIERTO','PARCIAL','RESERVADO','DESPACHADO','CANCELADO')),
  CONSTRAINT ck_pedido_compromiso CHECK (fecha_compromiso >= creado_en::date),
  CONSTRAINT ck_pedido_despacho CHECK ((estado = 'DESPACHADO') = (despachado_en IS NOT NULL))
);

CREATE TABLE detalle_pedido (
  id_pedido    integer  NOT NULL,
  nro_linea    smallint NOT NULL,
  id_producto  integer  NOT NULL,
  cantidad     integer  NOT NULL,
  CONSTRAINT pk_detalle_pedido PRIMARY KEY (id_pedido, nro_linea),
  CONSTRAINT fk_detalle_pedido_pedido FOREIGN KEY (id_pedido)
    REFERENCES pedido (id_pedido) ON UPDATE RESTRICT ON DELETE CASCADE,
  CONSTRAINT fk_detalle_pedido_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT uq_detalle_pedido_producto UNIQUE (id_pedido, id_producto),
  CONSTRAINT uq_detalle_pedido_linea_producto UNIQUE (id_pedido, nro_linea, id_producto),
  CONSTRAINT ck_detalle_pedido_linea CHECK (nro_linea > 0),
  CONSTRAINT ck_detalle_pedido_cantidad CHECK (cantidad > 0)
);

-- Asignación de una línea de pedido a un (lote, ubicación). Una línea puede
-- tener varias reservas si un solo lote no cubre la demanda.
CREATE TABLE reserva (
  id_reserva    bigint GENERATED ALWAYS AS IDENTITY,
  id_pedido     integer     NOT NULL,
  nro_linea     smallint    NOT NULL,
  id_producto   integer     NOT NULL,
  id_lote       integer     NOT NULL,
  id_ubicacion  integer     NOT NULL,
  cantidad      integer     NOT NULL,
  estado        varchar(10) NOT NULL DEFAULT 'ACTIVA',
  creada_en     timestamptz NOT NULL DEFAULT now(),
  cerrada_en    timestamptz,
  CONSTRAINT pk_reserva PRIMARY KEY (id_reserva),
  CONSTRAINT fk_reserva_linea FOREIGN KEY (id_pedido, nro_linea, id_producto)
    REFERENCES detalle_pedido (id_pedido, nro_linea, id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_reserva_lote_producto FOREIGN KEY (id_lote, id_producto)
    REFERENCES lote (id_lote, id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_reserva_existencia FOREIGN KEY (id_lote, id_ubicacion)
    REFERENCES existencia_lote (id_lote, id_ubicacion) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT ck_reserva_cantidad CHECK (cantidad > 0),
  CONSTRAINT ck_reserva_estado CHECK (estado IN ('ACTIVA','CONSUMIDA','LIBERADA')),
  CONSTRAINT ck_reserva_cierre CHECK ((estado = 'ACTIVA') = (cerrada_en IS NULL))
);

-- -----------------------------------------------------------------------------
-- 4. Libro de movimientos (append-only)
-- -----------------------------------------------------------------------------
CREATE TABLE movimiento (
  id_movimiento          bigint GENERATED ALWAYS AS IDENTITY,
  tipo                   varchar(10) NOT NULL,
  id_lote                integer     NOT NULL,
  id_ubicacion_origen    integer,
  id_ubicacion_destino   integer,
  cantidad               integer     NOT NULL,
  ocurrido_en            timestamptz NOT NULL DEFAULT now(),
  registrado_en          timestamptz NOT NULL DEFAULT clock_timestamp(),
  id_recepcion_linea     integer,
  id_reserva             bigint,
  id_movimiento_revertido bigint,
  motivo                 varchar(200),
  CONSTRAINT pk_movimiento PRIMARY KEY (id_movimiento),
  CONSTRAINT fk_mov_lote FOREIGN KEY (id_lote)
    REFERENCES lote (id_lote) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_mov_origen FOREIGN KEY (id_ubicacion_origen)
    REFERENCES ubicacion (id_ubicacion) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_mov_destino FOREIGN KEY (id_ubicacion_destino)
    REFERENCES ubicacion (id_ubicacion) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_mov_recepcion_linea FOREIGN KEY (id_recepcion_linea)
    REFERENCES recepcion_linea (id_recepcion_linea) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_mov_reserva FOREIGN KEY (id_reserva)
    REFERENCES reserva (id_reserva) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_mov_revertido FOREIGN KEY (id_movimiento_revertido)
    REFERENCES movimiento (id_movimiento) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT uq_mov_revertido UNIQUE (id_movimiento_revertido),   -- se revierte una sola vez
  CONSTRAINT uq_mov_recepcion_linea UNIQUE (id_recepcion_linea),  -- 1 línea recibida = 1 entrada
  CONSTRAINT uq_mov_reserva UNIQUE (id_reserva),                  -- 1 reserva consumida = 1 salida
  CONSTRAINT ck_mov_tipo CHECK (tipo IN ('ENTRADA','SALIDA','TRASLADO','AJUSTE','REVERSO')),
  CONSTRAINT ck_mov_cantidad CHECK (cantidad > 0),
  CONSTRAINT ck_mov_forma CHECK (
       (tipo = 'ENTRADA'  AND id_ubicacion_origen IS NULL AND id_ubicacion_destino IS NOT NULL
                          AND id_recepcion_linea IS NOT NULL AND id_reserva IS NULL AND id_movimiento_revertido IS NULL)
    OR (tipo = 'SALIDA'   AND id_ubicacion_origen IS NOT NULL AND id_ubicacion_destino IS NULL
                          AND id_reserva IS NOT NULL AND id_recepcion_linea IS NULL AND id_movimiento_revertido IS NULL)
    OR (tipo = 'TRASLADO' AND id_ubicacion_origen IS NOT NULL AND id_ubicacion_destino IS NOT NULL
                          AND id_ubicacion_origen <> id_ubicacion_destino
                          AND id_recepcion_linea IS NULL AND id_reserva IS NULL AND id_movimiento_revertido IS NULL)
    OR (tipo = 'AJUSTE'   AND (id_ubicacion_origen IS NULL) <> (id_ubicacion_destino IS NULL)
                          AND motivo IS NOT NULL
                          AND id_recepcion_linea IS NULL AND id_reserva IS NULL AND id_movimiento_revertido IS NULL)
    OR (tipo = 'REVERSO'  AND id_movimiento_revertido IS NOT NULL AND motivo IS NOT NULL
                          AND (id_ubicacion_origen IS NOT NULL OR id_ubicacion_destino IS NOT NULL)
                          AND id_recepcion_linea IS NULL AND id_reserva IS NULL)
  ),
  CONSTRAINT ck_mov_fecha CHECK (ocurrido_en <= registrado_en + interval '5 minutes')
);

-- =============================================================================
-- 5. Triggers de integridad
-- =============================================================================

-- 5.1 Lote: vencimiento obligatorio si el producto lo controla.
CREATE FUNCTION fn_lote_valida_vencimiento() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_controla boolean;
BEGIN
  SELECT controla_vencimiento INTO v_controla FROM producto WHERE id_producto = NEW.id_producto;
  IF v_controla AND NEW.fecha_vencimiento IS NULL THEN
    RAISE EXCEPTION 'El producto % controla vencimiento: el lote % requiere fecha_vencimiento',
      NEW.id_producto, NEW.numero_lote USING ERRCODE = '23514';
  END IF;
  IF NOT v_controla AND NEW.fecha_vencimiento IS NOT NULL THEN
    RAISE EXCEPTION 'El producto % no controla vencimiento: fecha_vencimiento debe ser NULL',
      NEW.id_producto USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_lote_valida_vencimiento BEFORE INSERT OR UPDATE OF fecha_vencimiento, id_producto
  ON lote FOR EACH ROW EXECUTE FUNCTION fn_lote_valida_vencimiento();

-- 5.2 Productos inactivos no reciben nuevas líneas de compra ni de pedido.
CREATE FUNCTION fn_valida_producto_activo() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT (SELECT activo FROM producto WHERE id_producto = NEW.id_producto) THEN
    RAISE EXCEPTION 'Producto % inactivo: no admite nuevas líneas en %', NEW.id_producto, TG_TABLE_NAME
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_detalle_compra_producto_activo BEFORE INSERT ON detalle_compra
  FOR EACH ROW EXECUTE FUNCTION fn_valida_producto_activo();
CREATE TRIGGER trg_detalle_pedido_producto_activo BEFORE INSERT ON detalle_pedido
  FOR EACH ROW EXECUTE FUNCTION fn_valida_producto_activo();

-- 5.3 Libro inmutable: ni UPDATE, ni DELETE, ni TRUNCATE.
CREATE FUNCTION fn_libro_inmutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'La tabla % es append-only: % no permitido. Registre un movimiento compensatorio (REVERSO/AJUSTE).',
    TG_TABLE_NAME, TG_OP USING ERRCODE = 'P0001';
END $$;
CREATE TRIGGER trg_movimiento_inmutable BEFORE UPDATE OR DELETE ON movimiento
  FOR EACH ROW EXECUTE FUNCTION fn_libro_inmutable();
CREATE TRIGGER trg_movimiento_no_truncate BEFORE TRUNCATE ON movimiento
  FOR EACH STATEMENT EXECUTE FUNCTION fn_libro_inmutable();
CREATE TRIGGER trg_recepcion_linea_inmutable BEFORE UPDATE OR DELETE ON recepcion_linea
  FOR EACH ROW EXECUTE FUNCTION fn_libro_inmutable();

-- 5.4 Validaciones del movimiento antes de aplicarlo.
CREATE FUNCTION fn_movimiento_valida() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE o movimiento%ROWTYPE;
BEGIN
  IF NEW.tipo = 'REVERSO' THEN
    SELECT * INTO o FROM movimiento WHERE id_movimiento = NEW.id_movimiento_revertido;
    IF o.tipo = 'REVERSO' THEN
      RAISE EXCEPTION 'No se revierte un REVERSO; registre un AJUSTE' USING ERRCODE = '23514';
    END IF;
    -- el reverso es el espejo exacto del original
    IF NEW.id_lote <> o.id_lote OR NEW.cantidad <> o.cantidad
       OR NEW.id_ubicacion_origen  IS DISTINCT FROM o.id_ubicacion_destino
       OR NEW.id_ubicacion_destino IS DISTINCT FROM o.id_ubicacion_origen THEN
      RAISE EXCEPTION 'El REVERSO del movimiento % debe tener el mismo lote y cantidad y ubicaciones invertidas',
        o.id_movimiento USING ERRCODE = '23514';
    END IF;
  END IF;
  IF NEW.tipo = 'SALIDA' THEN
    IF NOT EXISTS (SELECT 1 FROM reserva r WHERE r.id_reserva = NEW.id_reserva
                     AND r.estado = 'CONSUMIDA' AND r.id_lote = NEW.id_lote
                     AND r.id_ubicacion = NEW.id_ubicacion_origen AND r.cantidad = NEW.cantidad) THEN
      RAISE EXCEPTION 'Una SALIDA debe corresponder a una reserva CONSUMIDA del mismo lote, ubicación y cantidad'
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_movimiento_valida BEFORE INSERT ON movimiento
  FOR EACH ROW EXECUTE FUNCTION fn_movimiento_valida();

-- 5.5 ÚNICO camino de escritura del balance físico: el libro.
--     SECURITY DEFINER: el rol si_app no tiene permisos sobre existencia_lote.
CREATE FUNCTION fn_movimiento_aplica_saldo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = si, pg_temp AS $$
BEGIN
  IF NEW.id_ubicacion_origen IS NOT NULL THEN
    UPDATE existencia_lote
       SET cantidad_fisica = cantidad_fisica - NEW.cantidad, actualizado_en = clock_timestamp()
     WHERE id_lote = NEW.id_lote AND id_ubicacion = NEW.id_ubicacion_origen;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'No hay existencia del lote % en la ubicación %', NEW.id_lote, NEW.id_ubicacion_origen
        USING ERRCODE = '23514';
    END IF;
  END IF;
  IF NEW.id_ubicacion_destino IS NOT NULL THEN
    INSERT INTO existencia_lote (id_lote, id_ubicacion, cantidad_fisica)
    VALUES (NEW.id_lote, NEW.id_ubicacion_destino, NEW.cantidad)
    ON CONFLICT (id_lote, id_ubicacion)
    DO UPDATE SET cantidad_fisica = existencia_lote.cantidad_fisica + EXCLUDED.cantidad_fisica,
                  actualizado_en  = clock_timestamp();
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER trg_movimiento_aplica_saldo AFTER INSERT ON movimiento
  FOR EACH ROW EXECUTE FUNCTION fn_movimiento_aplica_saldo();

-- 5.6 Reservas: reglas de elegibilidad y máquina de estados.
CREATE FUNCTION fn_reserva_valida() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_venc date; v_tipo varchar; v_bod_ubi int; v_bod_ped int; v_est_ped varchar;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.estado <> 'ACTIVA' THEN
      RAISE EXCEPTION 'Una reserva nace ACTIVA' USING ERRCODE = '23514';
    END IF;
    SELECT l.fecha_vencimiento INTO v_venc FROM lote l WHERE l.id_lote = NEW.id_lote;
    IF v_venc IS NOT NULL AND v_venc <= NEW.creada_en::date THEN
      RAISE EXCEPTION 'Lote % vencido (%): no es elegible para reserva', NEW.id_lote, v_venc
        USING ERRCODE = '23514';
    END IF;
    SELECT u.tipo, u.id_bodega INTO v_tipo, v_bod_ubi FROM ubicacion u WHERE u.id_ubicacion = NEW.id_ubicacion;
    SELECT p.id_bodega, p.estado INTO v_bod_ped, v_est_ped FROM pedido p WHERE p.id_pedido = NEW.id_pedido;
    IF v_tipo = 'CUARENTENA' THEN
      RAISE EXCEPTION 'Ubicación % en CUARENTENA: no es elegible', NEW.id_ubicacion USING ERRCODE = '23514';
    END IF;
    IF v_bod_ubi <> v_bod_ped THEN
      RAISE EXCEPTION 'La ubicación no pertenece a la bodega del pedido' USING ERRCODE = '23514';
    END IF;
    IF v_est_ped NOT IN ('ABIERTO','PARCIAL') THEN
      RAISE EXCEPTION 'Pedido % en estado %: no admite reservas', NEW.id_pedido, v_est_ped USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE: solo cambia el estado ACTIVA -> CONSUMIDA | LIBERADA
  IF (NEW.id_pedido, NEW.nro_linea, NEW.id_producto, NEW.id_lote, NEW.id_ubicacion, NEW.cantidad, NEW.creada_en)
     IS DISTINCT FROM
     (OLD.id_pedido, OLD.nro_linea, OLD.id_producto, OLD.id_lote, OLD.id_ubicacion, OLD.cantidad, OLD.creada_en) THEN
    RAISE EXCEPTION 'Solo el estado de una reserva puede cambiar' USING ERRCODE = '23514';
  END IF;
  IF OLD.estado <> 'ACTIVA' OR NEW.estado NOT IN ('CONSUMIDA','LIBERADA') THEN
    RAISE EXCEPTION 'Transición de reserva no permitida: % -> %', OLD.estado, NEW.estado USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_reserva_valida BEFORE INSERT OR UPDATE ON reserva
  FOR EACH ROW EXECUTE FUNCTION fn_reserva_valida();
CREATE TRIGGER trg_reserva_no_delete BEFORE DELETE ON reserva
  FOR EACH ROW EXECUTE FUNCTION fn_libro_inmutable();

-- 5.7 ÚNICO camino de escritura de cantidad_reservada: las reservas ACTIVAS.
CREATE FUNCTION fn_reserva_aplica_saldo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = si, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE existencia_lote
       SET cantidad_reservada = cantidad_reservada + NEW.cantidad, actualizado_en = clock_timestamp()
     WHERE id_lote = NEW.id_lote AND id_ubicacion = NEW.id_ubicacion;
  ELSIF OLD.estado = 'ACTIVA' AND NEW.estado <> 'ACTIVA' THEN
    UPDATE existencia_lote
       SET cantidad_reservada = cantidad_reservada - OLD.cantidad, actualizado_en = clock_timestamp()
     WHERE id_lote = OLD.id_lote AND id_ubicacion = OLD.id_ubicacion;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER trg_reserva_aplica_saldo AFTER INSERT OR UPDATE OF estado ON reserva
  FOR EACH ROW EXECUTE FUNCTION fn_reserva_aplica_saldo();

-- 5.8 Pedido: transiciones de estado permitidas.
CREATE FUNCTION fn_pedido_transicion() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.estado = NEW.estado THEN RETURN NEW; END IF;
  IF NOT (   (OLD.estado = 'ABIERTO'   AND NEW.estado IN ('PARCIAL','RESERVADO','CANCELADO'))
          OR (OLD.estado = 'PARCIAL'   AND NEW.estado IN ('RESERVADO','DESPACHADO','CANCELADO'))
          OR (OLD.estado = 'RESERVADO' AND NEW.estado IN ('DESPACHADO','CANCELADO'))) THEN
    RAISE EXCEPTION 'Transición de pedido no permitida: % -> %', OLD.estado, NEW.estado USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_pedido_transicion BEFORE UPDATE OF estado ON pedido
  FOR EACH ROW EXECUTE FUNCTION fn_pedido_transicion();

-- 5.9 Recepción: no recibir más de lo ordenado; lote recibido en la bodega de la OC;
--     genera el movimiento ENTRADA y actualiza el estado de la OC.
CREATE FUNCTION fn_recepcion_linea_valida() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_pedida int; v_recibida int; v_estado varchar; v_bod_oc int; v_bod_ubi int; v_tipo varchar;
BEGIN
  -- bloquea la línea de OC: dos recepciones simultáneas no pueden sobrerrecibir
  SELECT d.cantidad_pedida, oc.estado, oc.id_bodega INTO v_pedida, v_estado, v_bod_oc
    FROM detalle_compra d JOIN orden_compra oc USING (id_oc)
   WHERE d.id_oc = NEW.id_oc AND d.nro_linea = NEW.nro_linea_oc
   FOR UPDATE OF d;
  IF v_estado IN ('COMPLETA','CANCELADA') THEN
    RAISE EXCEPTION 'OC % en estado %: no admite recepciones', NEW.id_oc, v_estado USING ERRCODE = '23514';
  END IF;
  SELECT coalesce(sum(cantidad_recibida),0) INTO v_recibida FROM recepcion_linea
   WHERE id_oc = NEW.id_oc AND nro_linea_oc = NEW.nro_linea_oc;
  IF v_recibida + NEW.cantidad_recibida > v_pedida THEN
    RAISE EXCEPTION 'Sobre-recepción en OC % línea %: pedido %, ya recibido %, intenta %',
      NEW.id_oc, NEW.nro_linea_oc, v_pedida, v_recibida, NEW.cantidad_recibida USING ERRCODE = '23514';
  END IF;
  SELECT id_bodega, tipo INTO v_bod_ubi, v_tipo FROM ubicacion WHERE id_ubicacion = NEW.id_ubicacion;
  IF v_bod_ubi <> v_bod_oc THEN
    RAISE EXCEPTION 'La ubicación de recepción no pertenece a la bodega de la OC' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_recepcion_linea_valida BEFORE INSERT ON recepcion_linea
  FOR EACH ROW EXECUTE FUNCTION fn_recepcion_linea_valida();

CREATE FUNCTION fn_recepcion_linea_genera_entrada() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = si, pg_temp AS $$
DECLARE v_fecha timestamptz; v_pend int;
BEGIN
  SELECT recibido_en INTO v_fecha FROM recepcion WHERE id_recepcion = NEW.id_recepcion;
  INSERT INTO movimiento (tipo, id_lote, id_ubicacion_destino, cantidad, ocurrido_en, id_recepcion_linea)
  VALUES ('ENTRADA', NEW.id_lote, NEW.id_ubicacion, NEW.cantidad_recibida, v_fecha, NEW.id_recepcion_linea);

  SELECT sum(d.cantidad_pedida - coalesce(r.rec,0)) INTO v_pend
    FROM detalle_compra d
    LEFT JOIN (SELECT nro_linea_oc, sum(cantidad_recibida) rec FROM recepcion_linea
                WHERE id_oc = NEW.id_oc GROUP BY nro_linea_oc) r ON r.nro_linea_oc = d.nro_linea
   WHERE d.id_oc = NEW.id_oc;
  UPDATE orden_compra SET estado = CASE WHEN v_pend = 0 THEN 'COMPLETA' ELSE 'PARCIAL' END
   WHERE id_oc = NEW.id_oc;
  RETURN NULL;
END $$;
CREATE TRIGGER trg_recepcion_linea_genera_entrada AFTER INSERT ON recepcion_linea
  FOR EACH ROW EXECUTE FUNCTION fn_recepcion_linea_genera_entrada();

-- =============================================================================
-- 6. Operaciones transaccionales (API de escritura de la aplicación)
-- =============================================================================

-- 6.1 Reserva FEFO atómica de UNA línea de pedido.
--   * Bloquea la línea del pedido (serializa reintentos sobre la misma línea).
--   * Recorre los lotes elegibles en orden FEFO y los bloquea con FOR UPDATE
--     en ese MISMO orden (orden global de bloqueo => menos deadlocks).
--   * En READ COMMITTED, si otra sesión cambió una fila bloqueada, PostgreSQL
--     re-evalúa el WHERE sobre la versión confirmada (EvalPlanQual): un lote
--     que quedó sin disponible se salta en vez de sobreasignarse.
--   * p_permitir_parcial = false: todo o nada (RAISE => ROLLBACK de todo).
CREATE FUNCTION reservar_fefo(p_id_pedido int, p_nro_linea smallint,
                              p_permitir_parcial boolean DEFAULT false,
                              p_fecha timestamptz DEFAULT now())
RETURNS TABLE (id_reserva bigint, id_lote int, numero_lote varchar, id_ubicacion int,
               fecha_vencimiento date, cantidad int)
LANGUAGE plpgsql AS $$
DECLARE
  v_prod int; v_cant int; v_bodega int; v_pend int; v_toma int; c record; v_id bigint;
BEGIN
  SELECT d.id_producto, d.cantidad, p.id_bodega INTO v_prod, v_cant, v_bodega
    FROM detalle_pedido d JOIN pedido p USING (id_pedido)
   WHERE d.id_pedido = p_id_pedido AND d.nro_linea = p_nro_linea
   FOR UPDATE OF d;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Línea %/% inexistente', p_id_pedido, p_nro_linea USING ERRCODE = '23503';
  END IF;

  SELECT v_cant - coalesce(sum(r.cantidad),0) INTO v_pend
    FROM reserva r WHERE r.id_pedido = p_id_pedido AND r.nro_linea = p_nro_linea
     AND r.estado IN ('ACTIVA','CONSUMIDA');

  FOR c IN
    SELECT e.id_lote, l.numero_lote, e.id_ubicacion, l.fecha_vencimiento,
           e.cantidad_fisica - e.cantidad_reservada AS disponible
      FROM existencia_lote e
      JOIN lote l      ON l.id_lote = e.id_lote
      JOIN ubicacion u ON u.id_ubicacion = e.id_ubicacion
     WHERE l.id_producto = v_prod
       AND u.id_bodega = v_bodega
       AND u.tipo <> 'CUARENTENA' AND u.activa
       AND (l.fecha_vencimiento IS NULL OR l.fecha_vencimiento > p_fecha::date)
       AND e.cantidad_fisica - e.cantidad_reservada > 0
     ORDER BY l.fecha_vencimiento NULLS LAST, l.recibido_en, l.numero_lote, u.codigo
       FOR UPDATE OF e
  LOOP
    EXIT WHEN v_pend <= 0;
    v_toma := least(c.disponible, v_pend);
    INSERT INTO reserva (id_pedido, nro_linea, id_producto, id_lote, id_ubicacion, cantidad, creada_en)
    VALUES (p_id_pedido, p_nro_linea, v_prod, c.id_lote, c.id_ubicacion, v_toma, p_fecha)
    RETURNING reserva.id_reserva INTO v_id;
    v_pend := v_pend - v_toma;
    id_reserva := v_id; id_lote := c.id_lote; numero_lote := c.numero_lote;
    id_ubicacion := c.id_ubicacion; fecha_vencimiento := c.fecha_vencimiento; cantidad := v_toma;
    RETURN NEXT;
  END LOOP;

  IF v_pend > 0 AND NOT p_permitir_parcial THEN
    RAISE EXCEPTION 'Stock insuficiente para pedido % línea %: faltan % unidades',
      p_id_pedido, p_nro_linea, v_pend USING ERRCODE = 'P0002', HINT = 'Reintentar más tarde o aceptar parcial';
  END IF;
END $$;

-- 6.2 Reserva de un pedido completo (todas sus líneas, en orden de nro_linea)
--     y actualización del estado. Una sola transacción: si una línea falla,
--     no queda ninguna reserva del pedido (fallo parcial => ROLLBACK total).
CREATE FUNCTION reservar_pedido(p_id_pedido int, p_permitir_parcial boolean DEFAULT false,
                                p_fecha timestamptz DEFAULT now())
RETURNS varchar LANGUAGE plpgsql AS $$
DECLARE l record; v_faltante int;
BEGIN
  PERFORM 1 FROM pedido WHERE id_pedido = p_id_pedido AND estado IN ('ABIERTO','PARCIAL') FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido % no existe o no está ABIERTO/PARCIAL', p_id_pedido USING ERRCODE = 'P0002';
  END IF;
  FOR l IN SELECT nro_linea FROM detalle_pedido WHERE id_pedido = p_id_pedido ORDER BY nro_linea LOOP
    PERFORM * FROM reservar_fefo(p_id_pedido, l.nro_linea, p_permitir_parcial, p_fecha);
  END LOOP;
  SELECT coalesce(sum(d.cantidad - coalesce(r.res,0)),0) INTO v_faltante
    FROM detalle_pedido d
    LEFT JOIN (SELECT nro_linea, sum(cantidad) res FROM reserva
                WHERE id_pedido = p_id_pedido AND estado IN ('ACTIVA','CONSUMIDA') GROUP BY nro_linea) r
      USING (nro_linea)
   WHERE d.id_pedido = p_id_pedido;
  UPDATE pedido SET estado = CASE WHEN v_faltante = 0 THEN 'RESERVADO' ELSE 'PARCIAL' END
   WHERE id_pedido = p_id_pedido AND estado <> CASE WHEN v_faltante = 0 THEN 'RESERVADO' ELSE 'PARCIAL' END;
  RETURN CASE WHEN v_faltante = 0 THEN 'RESERVADO' ELSE 'PARCIAL' END;
END $$;

-- 6.3 Despacho: consume las reservas ACTIVAS y registra las SALIDAS.
CREATE FUNCTION despachar_pedido(p_id_pedido int, p_fecha timestamptz DEFAULT now())
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE r record; n int := 0;
BEGIN
  PERFORM 1 FROM pedido WHERE id_pedido = p_id_pedido AND estado IN ('RESERVADO','PARCIAL') FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido % no está RESERVADO/PARCIAL', p_id_pedido USING ERRCODE = 'P0002';
  END IF;
  -- mismo orden global de bloqueo que la reserva (FEFO) para no formar ciclos
  FOR r IN SELECT rv.* FROM reserva rv
             JOIN lote l      ON l.id_lote = rv.id_lote
             JOIN ubicacion u ON u.id_ubicacion = rv.id_ubicacion
            WHERE rv.id_pedido = p_id_pedido AND rv.estado = 'ACTIVA'
            ORDER BY l.fecha_vencimiento NULLS LAST, l.recibido_en, l.numero_lote, u.codigo
              FOR UPDATE OF rv LOOP
    UPDATE reserva SET estado = 'CONSUMIDA', cerrada_en = p_fecha WHERE id_reserva = r.id_reserva;
    INSERT INTO movimiento (tipo, id_lote, id_ubicacion_origen, cantidad, ocurrido_en, id_reserva)
    VALUES ('SALIDA', r.id_lote, r.id_ubicacion, r.cantidad, p_fecha, r.id_reserva);
    n := n + 1;
  END LOOP;
  UPDATE pedido SET estado = 'DESPACHADO', despachado_en = p_fecha WHERE id_pedido = p_id_pedido;
  RETURN n;
END $$;

-- 6.4 Cancelación: libera reservas ACTIVAS (el saldo reservado vuelve por trigger).
CREATE FUNCTION cancelar_pedido(p_id_pedido int, p_fecha timestamptz DEFAULT now())
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n int; r record;
BEGIN
  PERFORM 1 FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
  -- libera en orden FEFO: mismo orden de bloqueo que reservar y despachar
  WITH orden AS (
    SELECT rv.id_reserva FROM reserva rv
      JOIN lote l      ON l.id_lote = rv.id_lote
      JOIN ubicacion u ON u.id_ubicacion = rv.id_ubicacion
     WHERE rv.id_pedido = p_id_pedido AND rv.estado = 'ACTIVA'
     ORDER BY l.fecha_vencimiento NULLS LAST, l.recibido_en, l.numero_lote, u.codigo
       FOR UPDATE OF rv)
  SELECT count(*) INTO n FROM orden;
  FOR r IN SELECT rv.id_reserva FROM reserva rv
             JOIN lote l      ON l.id_lote = rv.id_lote
             JOIN ubicacion u ON u.id_ubicacion = rv.id_ubicacion
            WHERE rv.id_pedido = p_id_pedido AND rv.estado = 'ACTIVA'
            ORDER BY l.fecha_vencimiento NULLS LAST, l.recibido_en, l.numero_lote, u.codigo LOOP
    UPDATE reserva SET estado = 'LIBERADA', cerrada_en = p_fecha WHERE id_reserva = r.id_reserva;
  END LOOP;
  UPDATE pedido SET estado = 'CANCELADO' WHERE id_pedido = p_id_pedido;
  RETURN n;
END $$;

-- 6.5 Traslado entre ubicaciones (un solo movimiento con origen y destino).
CREATE FUNCTION trasladar(p_id_lote int, p_origen int, p_destino int, p_cantidad int,
                          p_motivo varchar DEFAULT NULL, p_fecha timestamptz DEFAULT now())
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v bigint; b1 int; b2 int;
BEGIN
  SELECT id_bodega INTO b1 FROM ubicacion WHERE id_ubicacion = p_origen;
  SELECT id_bodega INTO b2 FROM ubicacion WHERE id_ubicacion = p_destino;
  INSERT INTO movimiento (tipo, id_lote, id_ubicacion_origen, id_ubicacion_destino, cantidad, ocurrido_en, motivo)
  VALUES ('TRASLADO', p_id_lote, p_origen, p_destino, p_cantidad, p_fecha,
          coalesce(p_motivo, CASE WHEN b1 <> b2 THEN 'Transferencia entre bodegas' ELSE 'Reubicación' END))
  RETURNING id_movimiento INTO v;
  RETURN v;
END $$;

-- =============================================================================
-- 7. Conciliación libro <-> balance (deben devolver 0 filas)
-- =============================================================================
-- Físico: el saldo de cada (lote, ubicación) es igual al neto de sus movimientos.
CREATE VIEW v_conciliacion_fisico AS
WITH libro AS (
  SELECT id_lote, id_ubicacion, sum(delta) AS fisico_libro
    FROM (SELECT id_lote, id_ubicacion_destino AS id_ubicacion, cantidad AS delta
            FROM movimiento WHERE id_ubicacion_destino IS NOT NULL
          UNION ALL
          SELECT id_lote, id_ubicacion_origen, -cantidad
            FROM movimiento WHERE id_ubicacion_origen IS NOT NULL) x
   GROUP BY id_lote, id_ubicacion
)
SELECT coalesce(e.id_lote, l.id_lote)           AS id_lote,
       coalesce(e.id_ubicacion, l.id_ubicacion) AS id_ubicacion,
       e.cantidad_fisica                         AS fisico_balance,
       l.fisico_libro
  FROM existencia_lote e
  FULL JOIN libro l ON l.id_lote = e.id_lote AND l.id_ubicacion = e.id_ubicacion
 WHERE coalesce(e.cantidad_fisica, 0) <> coalesce(l.fisico_libro, 0);

-- Reservado: el saldo reservado es igual a la suma de reservas ACTIVAS.
CREATE VIEW v_conciliacion_reservado AS
SELECT e.id_lote, e.id_ubicacion, e.cantidad_reservada AS reservado_balance,
       coalesce(r.activas, 0) AS reservado_reservas
  FROM existencia_lote e
  LEFT JOIN (SELECT id_lote, id_ubicacion, sum(cantidad) AS activas
               FROM reserva WHERE estado = 'ACTIVA'
              GROUP BY id_lote, id_ubicacion) r
         ON r.id_lote = e.id_lote AND r.id_ubicacion = e.id_ubicacion
 WHERE e.cantidad_reservada <> coalesce(r.activas, 0);

-- =============================================================================
-- 8. Permisos: la aplicación escribe por el libro y las funciones; nunca el saldo.
-- =============================================================================
GRANT USAGE ON SCHEMA si TO si_app;
GRANT SELECT ON ALL TABLES IN SCHEMA si TO si_app;
GRANT INSERT ON bodega, ubicacion, proveedor, producto, lote, orden_compra, detalle_compra,
               recepcion, recepcion_linea, cliente, pedido, detalle_pedido, reserva, movimiento TO si_app;
GRANT UPDATE (activo) ON producto, proveedor TO si_app;
GRANT UPDATE (activa) ON ubicacion, bodega TO si_app;
GRANT UPDATE (estado, despachado_en) ON pedido TO si_app;
GRANT UPDATE (estado, cerrada_en) ON reserva TO si_app;
GRANT UPDATE (estado) ON orden_compra TO si_app;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON existencia_lote FROM si_app, PUBLIC;
REVOKE UPDATE, DELETE, TRUNCATE ON movimiento FROM si_app, PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA si TO si_app;
