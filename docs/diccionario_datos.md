# Diccionario de datos

Generado desde el catálogo de PostgreSQL (esquema `si`). Clave: PK clave primaria, FK clave foránea, UQ participa en una restricción UNIQUE. Las restricciones de varias columnas se listan bajo cada tabla.

## bodega

Centro de almacenamiento físico.

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_bodega` | integer | No | PK | identity | Identificador sustituto. |
| `codigo` | varchar(10) | No | UQ |  | Código corto de la bodega (UIO, GYE). |
| `nombre` | varchar(80) | No |  |  | Nombre descriptivo. |
| `ciudad` | varchar(60) | No |  |  | Ciudad donde opera. |
| `activa` | boolean | No |  | true | Desactivación lógica; una bodega con historial no se borra. |

Restricciones:

- `ck_bodega_codigo`: `CHECK (((codigo) ~ '^[A-Z0-9-]{2,10}$'))`
- `pk_bodega`: `PRIMARY KEY (id_bodega)`
- `uq_bodega_codigo`: `UNIQUE (codigo)`

## ubicacion

Posición física dentro de una bodega (rack, picking, cuarentena…).

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_ubicacion` | integer | No | PK | identity | Identificador sustituto. |
| `id_bodega` | integer | No | FK UQ |  | Bodega a la que pertenece. |
| `codigo` | varchar(20) | No | UQ |  | Código físico, único dentro de la bodega. |
| `zona` | varchar(20) | No |  |  | Zona operativa. |
| `tipo` | varchar(12) | No |  |  | Uso de la ubicación; CUARENTENA no es vendible. |
| `activa` | boolean | No |  | true | Una ubicación inactiva no es elegible para picking. |

Restricciones:

- `ck_ubicacion_tipo`: `CHECK (((tipo) IN ('RECEPCION', 'RACK', 'PICKING', 'CUARENTENA', 'DESPACHO')))`
- `fk_ubicacion_bodega`: `FOREIGN KEY (id_bodega) REFERENCES bodega(id_bodega) (RESTRICT)`
- `pk_ubicacion`: `PRIMARY KEY (id_ubicacion)`
- `uq_ubicacion_bodega_codigo`: `UNIQUE (id_bodega, codigo)`

## proveedor

Empresa que abastece productos mediante órdenes de compra.

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_proveedor` | integer | No | PK | identity | Identificador sustituto. |
| `codigo` | varchar(12) | No | UQ |  | Código interno. |
| `nombre` | varchar(100) | No |  |  | Razón social. |
| `email` | varchar(120) | Sí | UQ |  | Correo de pedidos (opcional, único). |
| `lead_time_dias` | smallint | No |  | 7 | Días promedio entre orden y entrega. |
| `activo` | boolean | No |  | true | Desactivación lógica. |

Restricciones:

- `ck_proveedor_email`: `CHECK (((email IS NULL) OR ((email) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')))`
- `ck_proveedor_lead_time`: `CHECK (((lead_time_dias >= 0) AND (lead_time_dias <= 180)))`
- `pk_proveedor`: `PRIMARY KEY (id_proveedor)`
- `uq_proveedor_codigo`: `UNIQUE (codigo)`
- `uq_proveedor_email`: `UNIQUE (email)`

## producto

Artículo identificado por SKU.

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_producto` | integer | No | PK | identity | Identificador sustituto. |
| `sku` | varchar(20) | No | UQ |  | Código comercial único. |
| `nombre` | varchar(120) | No |  |  | Descripción. |
| `unidad` | varchar(10) | No |  | ’UN’ | Unidad de control del inventario. |
| `controla_vencimiento` | boolean | No |  | true | Si es verdadero, cada lote exige fecha de vencimiento. |
| `stock_minimo` | integer | No |  | 0 | Umbral de reposición (punto de pedido). |
| `stock_objetivo` | integer | No |  | 0 | Nivel al que se repone. |
| `id_proveedor_pref` | integer | Sí | FK |  | Proveedor sugerido para compras. |
| `activo` | boolean | No |  | true | Un producto inactivo conserva su historial pero no admite nuevas líneas. |

Restricciones:

- `ck_producto_minimo`: `CHECK ((stock_minimo >= 0))`
- `ck_producto_objetivo`: `CHECK ((stock_objetivo >= stock_minimo))`
- `ck_producto_sku`: `CHECK (((sku) ~ '^[A-Z0-9-]{3,20}$'))`
- `ck_producto_unidad`: `CHECK (((unidad) IN ('UN', 'CAJA', 'KG', 'L', 'PAQ')))`
- `fk_producto_proveedor_pref`: `FOREIGN KEY (id_proveedor_pref) REFERENCES proveedor(id_proveedor) ON UPDATE RESTRICT ON DELETE SET NULL`
- `pk_producto`: `PRIMARY KEY (id_producto)`
- `uq_producto_sku`: `UNIQUE (sku)`

## lote

Partida de un producto con fechas propias; base de la trazabilidad y de FEFO.

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_lote` | integer | No | PK UQ | identity | Identificador sustituto. |
| `id_producto` | integer | No | FK UQ |  | Producto al que pertenece el lote. |
| `numero_lote` | varchar(30) | No | UQ |  | Número de lote del fabricante, único por producto. |
| `fecha_fabricacion` | date | Sí |  |  | Fecha de fabricación (opcional). |
| `fecha_vencimiento` | date | Sí |  |  | Vencimiento; NULL solo para productos sin vencimiento. |
| `recibido_en` | timestamptz | No |  | now() | Primera recepción; desempate FEFO. |

Restricciones:

- `ck_lote_fechas`: `CHECK (((fecha_vencimiento IS NULL) OR (fecha_fabricacion IS NULL) OR (fecha_vencimiento > fecha_fabricacion)))`
- `fk_lote_producto`: `FOREIGN KEY (id_producto) REFERENCES producto(id_producto) (RESTRICT)`
- `pk_lote`: `PRIMARY KEY (id_lote)`
- `uq_lote_id_producto`: `UNIQUE (id_lote, id_producto)`
- `uq_lote_producto_numero`: `UNIQUE (id_producto, numero_lote)`

## existencia_lote

Balance por lote y ubicación. Dato derivado del libro; solo lo escriben triggers.

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_lote` | integer | No | FK PK |  | Lote. |
| `id_ubicacion` | integer | No | FK PK |  | Ubicación. |
| `cantidad_fisica` | integer | No |  | 0 | Unidades presentes = neto de movimientos del par (lote, ubicación). |
| `cantidad_reservada` | integer | No |  | 0 | Unidades comprometidas = suma de reservas ACTIVAS. |
| `actualizado_en` | timestamptz | No |  | clock_timestamp() | Último cambio aplicado por trigger. |

Restricciones:

- `ck_existencia_fisica`: `CHECK ((cantidad_fisica >= 0))`
- `ck_existencia_reservada`: `CHECK (((cantidad_reservada >= 0) AND (cantidad_reservada <= cantidad_fisica)))`
- `fk_existencia_lote`: `FOREIGN KEY (id_lote) REFERENCES lote(id_lote) (RESTRICT)`
- `fk_existencia_ubicacion`: `FOREIGN KEY (id_ubicacion) REFERENCES ubicacion(id_ubicacion) (RESTRICT)`
- `pk_existencia_lote`: `PRIMARY KEY (id_lote, id_ubicacion)`

## orden_compra

Cabecera de compra a un proveedor para una bodega.

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_oc` | integer | No | PK UQ | identity | Identificador sustituto. |
| `id_proveedor` | integer | No | FK |  | Proveedor. |
| `id_bodega` | integer | No | FK UQ |  | Bodega de destino. |
| `fecha_emision` | date | No |  | CURRENT_DATE | Fecha de emisión. |
| `fecha_esperada` | date | No |  |  | Fecha comprometida de entrega. |
| `estado` | varchar(10) | No |  | ’ABIERTA’ | ABIERTA → PARCIAL → COMPLETA (por trigger) o CANCELADA. |

Restricciones:

- `ck_oc_estado`: `CHECK (((estado) IN ('ABIERTA', 'PARCIAL', 'COMPLETA', 'CANCELADA')))`
- `ck_oc_fechas`: `CHECK ((fecha_esperada >= fecha_emision))`
- `fk_oc_bodega`: `FOREIGN KEY (id_bodega) REFERENCES bodega(id_bodega) (RESTRICT)`
- `fk_oc_proveedor`: `FOREIGN KEY (id_proveedor) REFERENCES proveedor(id_proveedor) (RESTRICT)`
- `pk_orden_compra`: `PRIMARY KEY (id_oc)`
- `uq_oc_id_bodega`: `UNIQUE (id_oc, id_bodega)`

## detalle_compra

Línea de la orden de compra.

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_oc` | integer | No | FK PK UQ |  | Orden de compra. |
| `nro_linea` | smallint | No | PK UQ |  | Número de línea dentro de la OC. |
| `id_producto` | integer | No | FK UQ |  | Producto ordenado (una línea por producto). |
| `cantidad_pedida` | integer | No |  |  | Unidades ordenadas. |
| `costo_unitario` | numeric(12,2) | No |  |  | Costo pactado. |

Restricciones:

- `ck_detalle_compra_cantidad`: `CHECK ((cantidad_pedida > 0))`
- `ck_detalle_compra_costo`: `CHECK ((costo_unitario >= (0)::numeric))`
- `ck_detalle_compra_linea`: `CHECK ((nro_linea > 0))`
- `fk_detalle_compra_oc`: `FOREIGN KEY (id_oc) REFERENCES orden_compra(id_oc) ON UPDATE RESTRICT ON DELETE CASCADE`
- `fk_detalle_compra_producto`: `FOREIGN KEY (id_producto) REFERENCES producto(id_producto) (RESTRICT)`
- `pk_detalle_compra`: `PRIMARY KEY (id_oc, nro_linea)`
- `uq_detalle_compra_linea_producto`: `UNIQUE (id_oc, nro_linea, id_producto)`
- `uq_detalle_compra_producto`: `UNIQUE (id_oc, id_producto)`

## recepcion

Evento de recepción física (guía de remisión) de una OC.

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_recepcion` | integer | No | PK UQ | identity | Identificador sustituto. |
| `id_oc` | integer | No | FK UQ |  | Orden de compra recibida. |
| `id_bodega` | integer | No | FK |  | Bodega; debe coincidir con la de la OC (FK compuesta). |
| `recibido_en` | timestamptz | No |  | now() | Fecha y hora de recepción. |
| `guia_remision` | varchar(30) | Sí |  |  | Documento del transportista. |

Restricciones:

- `fk_recepcion_oc_bodega`: `FOREIGN KEY (id_oc, id_bodega) REFERENCES orden_compra(id_oc, id_bodega) (RESTRICT)`
- `pk_recepcion`: `PRIMARY KEY (id_recepcion)`
- `uq_recepcion_id_oc`: `UNIQUE (id_recepcion, id_oc)`

## recepcion_linea

Cantidad recibida de una línea de OC en un lote y ubicación; genera la ENTRADA del libro.

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_recepcion_linea` | integer | No | PK | identity | Identificador sustituto. |
| `id_recepcion` | integer | No | FK |  | Recepción. |
| `id_oc` | integer | No | FK |  | OC (repetida para la FK compuesta). |
| `nro_linea_oc` | smallint | No | FK |  | Línea de la OC recibida. |
| `id_producto` | integer | No | FK |  | Producto (controla que lote y línea sean del mismo SKU). |
| `id_lote` | integer | No | FK |  | Lote recibido. |
| `id_ubicacion` | integer | No | FK |  | Ubicación donde se deja. |
| `cantidad_recibida` | integer | No |  |  | Unidades recibidas en esta recepción. |

Restricciones:

- `ck_rl_cantidad`: `CHECK ((cantidad_recibida > 0))`
- `fk_rl_detalle_compra`: `FOREIGN KEY (id_oc, nro_linea_oc, id_producto) REFERENCES detalle_compra(id_oc, nro_linea, id_producto) (RESTRICT)`
- `fk_rl_lote_producto`: `FOREIGN KEY (id_lote, id_producto) REFERENCES lote(id_lote, id_producto) (RESTRICT)`
- `fk_rl_recepcion`: `FOREIGN KEY (id_recepcion, id_oc) REFERENCES recepcion(id_recepcion, id_oc) (RESTRICT)`
- `fk_rl_ubicacion`: `FOREIGN KEY (id_ubicacion) REFERENCES ubicacion(id_ubicacion) (RESTRICT)`
- `pk_recepcion_linea`: `PRIMARY KEY (id_recepcion_linea)`

## cliente

Destinatario de los pedidos (datos sintéticos).

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_cliente` | integer | No | PK | identity | Identificador sustituto. |
| `codigo` | varchar(12) | No | UQ |  | Código interno. |
| `nombre` | varchar(100) | No |  |  | Nombre o razón social. |

Restricciones:

- `pk_cliente`: `PRIMARY KEY (id_cliente)`
- `uq_cliente_codigo`: `UNIQUE (codigo)`

## pedido

Cabecera de pedido de cliente atendido desde una bodega.

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_pedido` | integer | No | PK | identity | Identificador sustituto. |
| `id_cliente` | integer | No | FK |  | Cliente. |
| `id_bodega` | integer | No | FK |  | Bodega que despacha. |
| `creado_en` | timestamptz | No |  | now() | Fecha de creación. |
| `fecha_compromiso` | date | No |  |  | Fecha prometida; base del nivel de servicio. |
| `estado` | varchar(10) | No |  | ’ABIERTO’ | ABIERTO, PARCIAL, RESERVADO, DESPACHADO o CANCELADO (transiciones por trigger). |
| `despachado_en` | timestamptz | Sí |  |  | Fecha de despacho; obligatoria solo si estado = DESPACHADO. |

Restricciones:

- `ck_pedido_compromiso`: `CHECK ((fecha_compromiso >= (creado_en)))`
- `ck_pedido_despacho`: `CHECK ((((estado) = 'DESPACHADO') = (despachado_en IS NOT NULL)))`
- `ck_pedido_estado`: `CHECK (((estado) IN ('ABIERTO', 'PARCIAL', 'RESERVADO', 'DESPACHADO', 'CANCELADO')))`
- `fk_pedido_bodega`: `FOREIGN KEY (id_bodega) REFERENCES bodega(id_bodega) (RESTRICT)`
- `fk_pedido_cliente`: `FOREIGN KEY (id_cliente) REFERENCES cliente(id_cliente) (RESTRICT)`
- `pk_pedido`: `PRIMARY KEY (id_pedido)`

## detalle_pedido

Línea del pedido; puede cubrirse con varios lotes.

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_pedido` | integer | No | FK PK UQ |  | Pedido. |
| `nro_linea` | smallint | No | PK UQ |  | Número de línea. |
| `id_producto` | integer | No | FK UQ |  | Producto solicitado (una línea por producto). |
| `cantidad` | integer | No |  |  | Unidades solicitadas. |

Restricciones:

- `ck_detalle_pedido_cantidad`: `CHECK ((cantidad > 0))`
- `ck_detalle_pedido_linea`: `CHECK ((nro_linea > 0))`
- `fk_detalle_pedido_pedido`: `FOREIGN KEY (id_pedido) REFERENCES pedido(id_pedido) ON UPDATE RESTRICT ON DELETE CASCADE`
- `fk_detalle_pedido_producto`: `FOREIGN KEY (id_producto) REFERENCES producto(id_producto) (RESTRICT)`
- `pk_detalle_pedido`: `PRIMARY KEY (id_pedido, nro_linea)`
- `uq_detalle_pedido_linea_producto`: `UNIQUE (id_pedido, nro_linea, id_producto)`
- `uq_detalle_pedido_producto`: `UNIQUE (id_pedido, id_producto)`

## reserva

Asignación de una línea de pedido a un (lote, ubicación).

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_reserva` | bigint | No | PK | identity | Identificador sustituto. |
| `id_pedido` | integer | No | FK |  | Pedido. |
| `nro_linea` | smallint | No | FK |  | Línea del pedido. |
| `id_producto` | integer | No | FK |  | Producto (redundancia controlada por FK compuestas). |
| `id_lote` | integer | No | FK |  | Lote asignado. |
| `id_ubicacion` | integer | No | FK |  | Ubicación de donde se toma. |
| `cantidad` | integer | No |  |  | Unidades asignadas. |
| `estado` | varchar(10) | No |  | ’ACTIVA’ | ACTIVA → CONSUMIDA (despacho) o LIBERADA (cancelación). |
| `creada_en` | timestamptz | No |  | now() | Momento de la reserva. |
| `cerrada_en` | timestamptz | Sí |  |  | Momento en que dejó de estar ACTIVA. |

Restricciones:

- `ck_reserva_cantidad`: `CHECK ((cantidad > 0))`
- `ck_reserva_cierre`: `CHECK ((((estado) = 'ACTIVA') = (cerrada_en IS NULL)))`
- `ck_reserva_estado`: `CHECK (((estado) IN ('ACTIVA', 'CONSUMIDA', 'LIBERADA')))`
- `fk_reserva_existencia`: `FOREIGN KEY (id_lote, id_ubicacion) REFERENCES existencia_lote(id_lote, id_ubicacion) (RESTRICT)`
- `fk_reserva_linea`: `FOREIGN KEY (id_pedido, nro_linea, id_producto) REFERENCES detalle_pedido(id_pedido, nro_linea, id_producto) (RESTRICT)`
- `fk_reserva_lote_producto`: `FOREIGN KEY (id_lote, id_producto) REFERENCES lote(id_lote, id_producto) (RESTRICT)`
- `pk_reserva`: `PRIMARY KEY (id_reserva)`

## movimiento

Libro de movimientos inmutable; fuente de verdad del inventario.

| Columna | Tipo | Nulo | Clave | Default | Significado |
|---|---|:---:|---|---|---|
| `id_movimiento` | bigint | No | PK | identity | Identificador sustituto. |
| `tipo` | varchar(10) | No |  |  | ENTRADA, SALIDA, TRASLADO, AJUSTE o REVERSO. |
| `id_lote` | integer | No | FK |  | Lote afectado. |
| `id_ubicacion_origen` | integer | Sí | FK |  | Ubicación de la que sale (si aplica). |
| `id_ubicacion_destino` | integer | Sí | FK |  | Ubicación a la que entra (si aplica). |
| `cantidad` | integer | No |  |  | Unidades, siempre positivas. |
| `ocurrido_en` | timestamptz | No |  | now() | Fecha del hecho físico. |
| `registrado_en` | timestamptz | No |  | clock_timestamp() | Fecha de registro en la base. |
| `id_recepcion_linea` | integer | Sí | FK UQ |  | Origen de una ENTRADA. |
| `id_reserva` | bigint | Sí | FK UQ |  | Reserva consumida por una SALIDA. |
| `id_movimiento_revertido` | bigint | Sí | FK UQ |  | Movimiento que este REVERSO compensa. |
| `motivo` | varchar(200) | Sí |  |  | Justificación (obligatoria en AJUSTE y REVERSO). |

Restricciones:

- `ck_mov_cantidad`: `CHECK ((cantidad > 0))`
- `ck_mov_fecha`: `CHECK ((ocurrido_en <= (registrado_en + '00:05:00'::interval)))`
- `ck_mov_forma`: `CHECK (((((tipo) = 'ENTRADA') AND (id_ubicacion_origen IS NULL) AND (id_ubicacion_destino IS NOT NULL) AND (id_recepcion_linea IS NOT NULL) AND (id_reserva IS NULL) AND (id_movimiento_revertido IS NULL)) OR (((tipo) = 'SALIDA') AND (id_ubicacion_origen IS NOT NULL) AND (id_ubicacion_destino IS NULL) AND (id_reserva IS NOT NULL) AND (id_recepcion_linea IS NULL) AND (id_movimiento_revertido IS NULL)) OR (((tipo) = 'TRASLADO') AND (id_ubicacion_origen IS NOT NULL) AND (id_ubicacion_destino IS NOT NULL) AND (id_ubicacion_origen <> id_ubicacion_destino) AND (id_recepcion_linea IS NULL) AND (id_reserva IS NULL) AND (id_movimiento_revertido IS NULL)) OR (((tipo) = 'AJUSTE') AND ((id_ubicacion_origen IS NULL) <> (id_ubicacion_destino IS NULL)) AND (motivo IS NOT NULL) AND (id_recepcion_linea IS NULL) AND (id_reserva IS NULL) AND (id_movimiento_revertido IS NULL)) OR (((tipo) = 'REVERSO') AND (id_movimiento_revertido IS NOT NULL) AND (motivo IS NOT NULL) AND ((id_ubicacion_origen IS NOT NULL) OR (id_ubicacion_destino IS NOT NULL)) AND (id_recepcion_linea IS NULL) AND (id_reserva IS NULL))))`
- `ck_mov_tipo`: `CHECK (((tipo) IN ('ENTRADA', 'SALIDA', 'TRASLADO', 'AJUSTE', 'REVERSO')))`
- `fk_mov_destino`: `FOREIGN KEY (id_ubicacion_destino) REFERENCES ubicacion(id_ubicacion) (RESTRICT)`
- `fk_mov_lote`: `FOREIGN KEY (id_lote) REFERENCES lote(id_lote) (RESTRICT)`
- `fk_mov_origen`: `FOREIGN KEY (id_ubicacion_origen) REFERENCES ubicacion(id_ubicacion) (RESTRICT)`
- `fk_mov_recepcion_linea`: `FOREIGN KEY (id_recepcion_linea) REFERENCES recepcion_linea(id_recepcion_linea) (RESTRICT)`
- `fk_mov_reserva`: `FOREIGN KEY (id_reserva) REFERENCES reserva(id_reserva) (RESTRICT)`
- `fk_mov_revertido`: `FOREIGN KEY (id_movimiento_revertido) REFERENCES movimiento(id_movimiento) (RESTRICT)`
- `pk_movimiento`: `PRIMARY KEY (id_movimiento)`
- `uq_mov_recepcion_linea`: `UNIQUE (id_recepcion_linea)`
- `uq_mov_reserva`: `UNIQUE (id_reserva)`
- `uq_mov_revertido`: `UNIQUE (id_movimiento_revertido)`
