# 6. Implementación del esquema

## 6.1 Scripts y orden de ejecución

| Script | Contenido |
|---|---|
| `sql/01_schema.sql` | Esquema `si`: 15 tablas con PK, FK con nombre estable y política ON DELETE/UPDATE explícita, CHECK, UNIQUE, identidades; triggers de integridad; funciones transaccionales (`reservar_fefo`, `reservar_pedido`, `despachar_pedido`, `cancelar_pedido`, `trasladar`); vistas de conciliación; rol `si_app` y permisos. |
| `sql/02_seed.sql` | Datos sintéticos con casos límite, cargados en orden cronológico por las mismas funciones que usaría la aplicación. |
| `tests/pruebas_integridad.sql` | 39 pruebas de restricciones; cada una se ejecuta en una subtransacción que siempre se deshace, así que el script es repetible. |
| `sql/03_queries.sql` | Ocho consultas parametrizadas con variables de psql. |
| `sql/04_transactions.sql` | Reserva FEFO atómica, fallo parcial con ROLLBACK, reserva y despacho con COMMIT, función de laboratorio y guion manual de dos sesiones. |
| `sql/05_indexes_views.sql` | Tres vistas del dashboard e índices propuestos con su justificación. |
| `tests/concurrencia/experimento.py` | Experimento automático con dos sesiones (E0–E7). |
| `benchmarks/seed_volumen.sql`, `benchmarks/explain_antes_despues.sql` | Base de volumen y comparación de planes. |

Todo el SQL es reproducible: ningún resultado de este informe se escribió a mano. Las salidas completas están en `evidencias/`.

## 6.2 Decisiones del DDL

- **Claves sustitutas** `GENERATED ALWAYS AS IDENTITY` en todas las entidades, y las claves naturales como `UNIQUE` (SKU, código de bodega, código de ubicación dentro de su bodega, número de lote dentro de su SKU). `ALWAYS` impide que alguien inserte un identificador a mano y desincronice la secuencia.
- **Nombres estables**: `pk_`, `fk_`, `uq_`, `ck_`, `trg_`, `ix_`. Los mensajes de error y la matriz de reglas se refieren a esos nombres.
- **Dominios con CHECK** en lugar de tipos ENUM, para poder ampliar un estado con un `ALTER TABLE … DROP/ADD CONSTRAINT` sin recrear el tipo.
- **Cantidades enteras**: la unidad de control es la unidad, la caja o el paquete del producto.
- **Fechas**: `date` para vencimientos y compromisos; `timestamptz` para hechos que ocurren en un instante. `movimiento` guarda `ocurrido_en` (hecho físico) y `registrado_en` (registro en la base), y un CHECK impide registrar hechos en el futuro.
- **Reglas entre tablas**: cuando una regla se puede expresar con una FK compuesta, la preferimos a un trigger (por ejemplo, que el lote de una reserva sea del producto de la línea). Los triggers quedan para lo que una restricción declarativa no puede expresar: vencimiento según el producto, elegibilidad de la reserva, transiciones de estado, sobre-recepción e inmutabilidad del libro.

## 6.3 Datos semilla y casos límite

Las fechas son relativas a `current_date`, así que las consultas de vencimiento dan el mismo resultado cualquier día que se ejecute el script.

| Caso límite | Dónde aparece en la semilla |
|---|---|
| Varias bodegas | UIO (8 ubicaciones) y GYE (4 ubicaciones), con transferencia de 50 cajas de GYE a UIO |
| Ubicación en cuarentena | 20 cajas de PA-2410 en UIO Q-01 |
| Lote vencido con saldo | YO-2409A (12 u, venció hace 40 días) y SU-2410 (10 u, venció hace 3 días) |
| Lote por vencer | YO-2410B vence en 5 días; SU-2411A en 15 días |
| Lote agotado | Q-2408 de queso: entró 60, salió 60, saldo 0 |
| Lote en varias ubicaciones | LE-2410B repartido entre REC-01, P-01 y A-01-01 |
| Producto sin vencimiento | Tornillos FER-TORN-M6 y cinta FER-CINTA-48 |
| Producto nunca recibido | FER-CINTA-48: stock 0 con una OC abierta |
| Producto inactivo con historial | LAC-QUESO-500 |
| OC completa, parcial, abierta y cancelada | OC 1–5 y 8 completas; OC 6 parcial en dos recepciones; OC 9 y 10 abiertas; OC 7 cancelada |
| Pedidos | despachado a tiempo, despachado tarde (pedido 2), despachado incompleto con quiebre (pedido 7), cancelado con reservas liberadas (9), reservados (10, 11) y abierto (12) |
| Ajustes y correcciones | merma de 4 unidades, sobrante de conteo de 2 cajas y un traslado erróneo con su REVERSO |

Después de la carga hay 32 movimientos, 19 filas de saldo, 13 lotes, 12 pedidos, 15 reservas y 10 órdenes de compra, con 0 divergencias en las dos vistas de conciliación.

## 6.4 Resultado de las pruebas de integridad

{{PRUEBAS}}
