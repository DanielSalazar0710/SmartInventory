# 9. Transacciones, FEFO y concurrencia

## 9.1 Reserva FEFO como unidad lógica

La reserva está implementada en `reservar_fefo` (una línea) y `reservar_pedido` (todas las líneas de un pedido). Su secuencia dentro de una sola transacción es:

1. `SELECT … FOR UPDATE` sobre la línea del pedido (y sobre el pedido en `reservar_pedido`): dos intentos de reservar la misma línea no pueden correr a la vez.
2. Calcular lo pendiente: cantidad solicitada menos reservas ACTIVAS o CONSUMIDAS de esa línea.
3. Seleccionar los saldos elegibles (lote no vencido, ubicación fuera de cuarentena y activa, misma bodega, disponible > 0) en **orden FEFO** y bloquearlos con `FOR UPDATE OF existencia_lote` **en ese mismo orden**.
4. Recorrer los lotes, insertar una reserva por cada uno con `least(disponible, pendiente)` hasta cubrir la demanda. El trigger suma `cantidad_reservada` y el `CHECK` comprueba que no supere lo físico.
5. Si queda pendiente y no se aceptó parcial, `RAISE … USING ERRCODE = 'P0002'`: la transacción completa vuelve atrás.
6. Actualizar el estado del pedido (RESERVADO o PARCIAL) y hacer `COMMIT`.

En `sql/04_transactions.sql` se ejecutan tres casos con resultado observado:

- **División entre lotes y exclusión del vencido.** Para 6 unidades de FAR-SUERO-500 se reservan 4 de SU-2411A (vence en 15 días) y 2 de SU-2411B (vence en 40 días); SU-2410, vencido, con 10 unidades, no se toca. El caso termina en `ROLLBACK` para no alterar el escenario del experimento.
- **Fallo parcial.** Un pedido con una línea de leche (cubrible) y otra de 50 sueros (no cubrible) falla con P0002 en la segunda línea. Después del `ROLLBACK` el pedido no tiene ninguna reserva, sigue ABIERTO y el total reservado de la base es el mismo que antes. Las tablas que deben volver juntas son `reserva`, `existencia_lote.cantidad_reservada` y `pedido.estado`; por eso todo ocurre en una sola transacción y no en llamadas separadas.
- **Camino feliz.** El pedido 12 se reserva (`COMMIT`) y se despacha (`COMMIT`): las reservas pasan a CONSUMIDA, se registran dos SALIDAS en el libro y las vistas de conciliación siguen en 0.

## 9.2 Diseño del experimento

`tests/concurrencia/experimento.py` abre dos conexiones independientes (sesión A y sesión B) y recarga la semilla antes de cada escenario. El SKU de prueba es el del enunciado: **FAR-SUERO-500 con dos lotes elegibles (SU-2411A con 4 u y SU-2411B con 3 u, 7 disponibles) y un lote vencido (SU-2410 con 10 u)**. Para forzar la carrera, la sesión A decide su plan y espera 3 segundos antes de escribir; la sesión B arranca 0,5 segundos después. Una tercera conexión consulta `pg_stat_activity` cada 20 ms para registrar cuándo una sesión queda esperando un bloqueo. La función de laboratorio `reservar_fefo_lab` es la misma lógica FEFO con dos perillas: leer con o sin `FOR UPDATE`, y la pausa.

Resumen de lo observado (las líneas de tiempo completas van a continuación):

| Escenario | Aislamiento / estrategia | Pedidos | Resultado | ¿Sobreventa? |
|---|---|---|---|---|
| E0 | READ COMMITTED, tabla de saldo **sin** CHECK ni triggers; la aplicación escribe el valor calculado | A=5, B=5 (7 disp.) | Las dos confirman; se prometen 10 unidades con 7 físicas y el saldo solo registra 5 | **Sí** (actualización perdida) |
| E1 | READ COMMITTED, lectura **sin** bloqueo | A=5, B=2 (alcanza justo) | B confirma; A falla con 23514 por el CHECK porque decidió con un saldo obsoleto | No, pero **rechaza un pedido que se podía atender** |
| E2 | READ COMMITTED + **FOR UPDATE** en orden FEFO | A=5, B=2 | B espera el bloqueo de A, re-evalúa el saldo confirmado, salta SU-2411A y toma 2 de SU-2411B. Ambos confirman; 7 de 7 reservadas | No |
| E3 | READ COMMITTED + FOR UPDATE | A=5, B=5 (las últimas unidades) | B espera; cuando A confirma, B falla limpio con P0002 (faltan 3) y no deja reservas | No |
| E4 | SERIALIZABLE sin bloqueo + reintento | A=5, B=2 | A recibe 40001, el cliente reintenta y en el segundo intento reserva SU-2411A=2 y SU-2411B=3 | No |
| E5 | SERIALIZABLE + reintento | A=5, B=5 | A recibe 40001; al reintentar falla con P0002 | No |
| E6 | Bloqueos en orden opuesto vs. orden FEFO común | — | Orden opuesto: **deadlock 40P01** detectado en ~1 s. Orden FEFO común: B solo espera | — |
| E7 | 20 clientes reservan 1 unidad del mismo lote a la vez | 20 × 1 | FOR UPDATE: 20 OK, 0 reintentos, 1,17 s. SERIALIZABLE: 20 OK, **190 reintentos**, 3,1 s | No |

En todos los escenarios sobre el modelo real (E1–E7) las vistas de conciliación reportaron 0 divergencias.

{{CONCURRENCIA}}

## 9.3 Análisis de anomalías

| Anomalía | Pregunta | Respuesta con evidencia |
|---|---|---|
| **Actualización perdida** | ¿Dos procesos que consumen saldo pueden sobrescribir cambios? | Sí, si la aplicación lee el saldo y escribe un valor absoluto (E0: la escritura de A pisó la de B). En nuestro modelo no ocurre por dos razones: el trigger escribe `cantidad_reservada = cantidad_reservada + q`, que PostgreSQL re-evalúa sobre la versión confirmada después de esperar el bloqueo de fila, y el CHECK rechaza cualquier resultado mayor que lo físico (E1). |
| **Lectura no repetible / fantasma** | ¿Puede cambiar el conjunto de lotes elegibles durante la asignación FEFO? | En READ COMMITTED cada sentencia ve su propia instantánea. Con `FOR UPDATE`, si otra sesión cambió una fila ya leída, PostgreSQL vuelve a evaluar el WHERE sobre la versión confirmada (E2: B saltó SU-2411A porque había quedado en 0). Un lote **nuevo** que se confirme durante la asignación (fantasma) no se ve ni se bloquea; eso no puede causar sobreventa, solo que la asignación no lo aproveche, y la siguiente reserva lo verá. En SERIALIZABLE la instantánea es fija y los conflictos se detectan al escribir (E4, E5). |
| **Sobreventa** | ¿Qué condición impide que dos pedidos reserven las mismas unidades? | La regla está en la base, no en la aplicación: `CHECK (cantidad_reservada <= cantidad_fisica)` sobre la fila (lote, ubicación), actualizada siempre de forma relativa dentro de la misma transacción. `FOR UPDATE` agrega que la decisión se toma con datos vigentes, así que el segundo pedido no falla por un plan obsoleto: toma otro lote o recibe un error de negocio claro. |
| **Bloqueo / deadlock** | ¿Qué orden de bloqueo usarán para reducir ciclos? ¿Qué evidencia observan? | Todas las rutas bloquean en el mismo orden global: primero la línea del pedido, luego los saldos en orden FEFO (vencimiento, recepción, número de lote, ubicación). `reservar_pedido` recorre las líneas por `nro_linea`, y `despachar_pedido` y `cancelar_pedido` recorren las reservas en el mismo orden FEFO, así que el trigger toca los saldos en el mismo orden que la reserva. En E6, con orden opuesto PostgreSQL detectó el ciclo y abortó una sesión con 40P01 tras `deadlock_timeout` (1 s); con el orden FEFO común solo hubo espera. Una reserva que pide dos SKU distintos en orden contrario a otra todavía podría formar un ciclo; en ese caso el error 40P01 se reintenta igual que un 40001. |
| **Fallo parcial** | ¿Qué tablas deben volver atrás juntas cuando falla la última asignación de lote? | `reserva` (las filas ya insertadas), `existencia_lote.cantidad_reservada` (modificada por el trigger) y `pedido.estado`. Como la reserva completa ocurre en una transacción y el error se lanza con RAISE, el ROLLBACK las deshace juntas (T34 y sección 9.1). |

## 9.4 Recomendación: READ COMMITTED + `SELECT … FOR UPDATE` en orden FEFO

Elegimos **READ COMMITTED con bloqueo pesimista de las filas de saldo en orden FEFO**, respaldado por el CHECK del balance. Las razones salen del experimento:

1. **Correctitud igual a SERIALIZABLE en este caso.** Las dos estrategias evitaron la sobreventa y dejaron 0 divergencias (E2–E5). El riesgo que protege SERIALIZABLE, decidir con datos que otra transacción ya cambió, lo cubre aquí el bloqueo explícito sobre exactamente las filas que se van a modificar.
2. **Costo menor bajo contención.** Con 20 clientes sobre el mismo lote, FOR UPDATE terminó en 1,17 s sin reintentos; SERIALIZABLE necesitó 190 reintentos y 3,1 s (2,6 veces más). Cada reintento repite la lectura FEFO completa, y con mucha contención los reintentos crecen más rápido que los clientes. SERIALIZABLE también mantiene bloqueos de predicado (SIRead) en todo lo que lee, lo que consume memoria y aumenta los falsos conflictos.
3. **Errores con significado.** Con FOR UPDATE, la segunda sesión obtiene un resultado de negocio (reserva en otro lote o P0002 "stock insuficiente"). Con SERIALIZABLE recibe 40001, que no dice nada al usuario y obliga a reintentar.
4. **Costo que aceptamos.** FOR UPDATE serializa las reservas que compiten por el mismo (lote, ubicación): mientras A no confirma, B espera (en E2 esperó lo que duró la pausa de A). Por eso la transacción de reserva debe ser corta: sin interacción con el usuario ni llamadas externas entre el `BEGIN` y el `COMMIT`. Las reservas de lotes distintos no se bloquean entre sí.

SERIALIZABLE sería preferible si la regla dependiera de un conjunto de filas que no se puede bloquear de antemano (por ejemplo, un límite de crédito sobre la suma de todos los pedidos de un cliente). No es el caso de la reserva FEFO.

**Cuándo debe reintentar el cliente.** La aplicación debe reintentar la transacción **completa** (desde el `BEGIN`, volviendo a leer todo) cuando recibe:

- **40001** `serialization_failure`: solo aparece si alguna operación se ejecuta en SERIALIZABLE o REPEATABLE READ.
- **40P01** `deadlock_detected`: puede aparecer en cualquier nivel si dos transacciones bloquean recursos en orden distinto.

Recomendamos un máximo de 3 intentos con espera creciente, como hace `experimento.py`. No se reintentan los errores de negocio o de integridad, como **P0002** (stock insuficiente), **23514** (CHECK) o **23503** (FK): repetir la misma transacción daría el mismo resultado. Esos errores se informan al usuario. En todos los casos, al primer error la transacción queda abortada y lo único válido es `ROLLBACK`.
