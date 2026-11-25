# Resultados del experimento de concurrencia

Servidor: PostgreSQL 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1). Fecha de ejecución: 2026-11-25 02:56:28.
Pausa de la sesión A entre decidir y escribir: 3.0 s; B arranca 0,5 s después de A.

### E0 · Sin protecciones (tabla de saldo sin CHECK, la aplicación escribe el valor calculado)

Laboratorio aislado en el esquema `lab`: muestra qué pasaría si la aplicación leyera el saldo, calculara el nuevo valor y lo escribiera como número absoluto. Disponible = 7; A pide 5 y B pide 5.

| t (s) | Sesión | Evento |
|---:|:---:|---|
|  0.01 | A | lee saldo: SU-2411A disp=4, SU-2411B disp=3 |
|  0.21 | B | lee saldo: SU-2411A disp=4, SU-2411B disp=3 |
|  0.21 | B | escribe reservado = SU-2411A:4, SU-2411B:1 |
|  0.21 | B | COMMIT ✔ (cree que reservó 5) |
|  1.01 | A | escribe reservado = SU-2411A:4, SU-2411B:1 |
|  1.01 | A | COMMIT ✔ (cree que reservó 5) |

Saldo final: SU-2411A físico=4 reservado=4, SU-2411B físico=3 reservado=1. Se prometieron 10 unidades con solo 7 físicas: **sobreventa por actualización perdida**; el saldo solo registra la escritura de A, que pisó la de B.

### E1 · READ COMMITTED sin bloqueo (leer → decidir → escribir)

A pide 5 y B pide 2: la suma (7) es exactamente el disponible, así que ambos pedidos se podían atender.

Saldo elegible inicial de FAR-SUERO-500: SU-2411A físico=4 reservado=0, SU-2411B físico=3 reservado=0 (disponible total = 7). Sesión A pide 5 (pedido 15); sesión B pide 2 (pedido 16).

| t (s) | Sesión | Evento |
|---:|:---:|---|
|  0.01 | A | BEGIN READ COMMITTED (intento 1); reserva sin bloqueo |
|  0.51 | B | BEGIN READ COMMITTED (intento 1); reserva sin bloqueo |
|  0.52 | B | reservas escritas: SU-2411A=2 |
|  0.52 | B | COMMIT ✔ |
|  3.02 | A | 23514 new row for relation "existencia_lote" violates check constraint "ck_existencia_reservada" → ROLLBACK |

Saldo final: SU-2411A físico=4 reservado=2, SU-2411B físico=3 reservado=0. Divergencias libro/balance: 0. Unidades reservadas en total: 2 de 7.

### E2 · READ COMMITTED + SELECT … FOR UPDATE en orden FEFO (estrategia elegida)

Mismo caso que E1: A pide 5 y B pide 2.

Saldo elegible inicial de FAR-SUERO-500: SU-2411A físico=4 reservado=0, SU-2411B físico=3 reservado=0 (disponible total = 7). Sesión A pide 5 (pedido 15); sesión B pide 2 (pedido 16).

| t (s) | Sesión | Evento |
|---:|:---:|---|
|  0.01 | A | BEGIN READ COMMITTED (intento 1); reserva con FOR UPDATE |
|  0.51 | B | BEGIN READ COMMITTED (intento 1); reserva con FOR UPDATE |
|  0.52 | B | queda ESPERANDO un bloqueo (transactionid) |
|  3.02 | A | reservas escritas: SU-2411A=4, SU-2411B=1 |
|  3.03 | A | COMMIT ✔ |
|  3.03 | B | reservas escritas: SU-2411B=2 |
|  3.03 | B | COMMIT ✔ |

Saldo final: SU-2411A físico=4 reservado=4, SU-2411B físico=3 reservado=3. Divergencias libro/balance: 0. Unidades reservadas en total: 7 de 7.

### E3 · READ COMMITTED + FOR UPDATE: las últimas unidades (la suma excede el saldo)

A pide 5 y B pide 5 con 7 disponibles: solo uno puede ser atendido.

Saldo elegible inicial de FAR-SUERO-500: SU-2411A físico=4 reservado=0, SU-2411B físico=3 reservado=0 (disponible total = 7). Sesión A pide 5 (pedido 15); sesión B pide 5 (pedido 16).

| t (s) | Sesión | Evento |
|---:|:---:|---|
|  0.01 | A | BEGIN READ COMMITTED (intento 1); reserva con FOR UPDATE |
|  0.51 | B | BEGIN READ COMMITTED (intento 1); reserva con FOR UPDATE |
|  0.52 | B | queda ESPERANDO un bloqueo (transactionid) |
|  3.02 | A | reservas escritas: SU-2411A=4, SU-2411B=1 |
|  3.02 | A | COMMIT ✔ |
|  3.02 | B | P0002 Stock insuficiente para pedido 16 línea 1: faltan 3 unidades → ROLLBACK |

Saldo final: SU-2411A físico=4 reservado=4, SU-2411B físico=3 reservado=1. Divergencias libro/balance: 0. Unidades reservadas en total: 5 de 7.

### E4 · SERIALIZABLE sin bloqueo explícito, con reintento en el cliente

A pide 5 y B pide 2. El cliente reintenta hasta 3 veces ante 40001.

Saldo elegible inicial de FAR-SUERO-500: SU-2411A físico=4 reservado=0, SU-2411B físico=3 reservado=0 (disponible total = 7). Sesión A pide 5 (pedido 15); sesión B pide 2 (pedido 16).

| t (s) | Sesión | Evento |
|---:|:---:|---|
|  0.01 | A | BEGIN SERIALIZABLE (intento 1); reserva sin bloqueo |
|  0.51 | B | BEGIN SERIALIZABLE (intento 1); reserva sin bloqueo |
|  0.52 | B | reservas escritas: SU-2411A=2 |
|  0.52 | B | COMMIT ✔ |
|  3.03 | A | 40001 serialization_failure → ROLLBACK (could not serialize access due to concurrent update) |
|  3.03 | A | el cliente REINTENTA la transacción completa |
|  3.03 | A | BEGIN SERIALIZABLE (intento 2); reserva sin bloqueo |
|  6.03 | A | reservas escritas: SU-2411A=2, SU-2411B=3 |
|  6.03 | A | COMMIT ✔ |

Saldo final: SU-2411A físico=4 reservado=4, SU-2411B físico=3 reservado=3. Divergencias libro/balance: 0. Unidades reservadas en total: 7 de 7.

### E5 · SERIALIZABLE: las últimas unidades, con reintento

A pide 5 y B pide 5 con 7 disponibles.

Saldo elegible inicial de FAR-SUERO-500: SU-2411A físico=4 reservado=0, SU-2411B físico=3 reservado=0 (disponible total = 7). Sesión A pide 5 (pedido 15); sesión B pide 5 (pedido 16).

| t (s) | Sesión | Evento |
|---:|:---:|---|
|  0.01 | A | BEGIN SERIALIZABLE (intento 1); reserva sin bloqueo |
|  0.51 | B | BEGIN SERIALIZABLE (intento 1); reserva sin bloqueo |
|  0.52 | B | reservas escritas: SU-2411A=4, SU-2411B=1 |
|  0.52 | B | COMMIT ✔ |
|  3.02 | A | 40001 serialization_failure → ROLLBACK (could not serialize access due to concurrent update) |
|  3.02 | A | el cliente REINTENTA la transacción completa |
|  3.03 | A | BEGIN SERIALIZABLE (intento 2); reserva sin bloqueo |
|  3.03 | A | P0002 Stock insuficiente para pedido 15 línea 1: faltan 3 unidades → ROLLBACK |

Saldo final: SU-2411A físico=4 reservado=4, SU-2411B físico=3 reservado=1. Divergencias libro/balance: 0. Unidades reservadas en total: 5 de 7.

### E6 · Deadlock por orden de bloqueo inconsistente vs. orden FEFO global


**Orden inconsistente (A: SU-2411A→SU-2411B, B: SU-2411B→SU-2411A)**

| t (s) | Sesión | Evento |
|---:|:---:|---|
|  0.01 | A | bloquea lote 12 |
|  0.21 | B | bloquea lote 13 |
|  1.02 | A | queda ESPERANDO un bloqueo (transactionid) |
|  1.23 | B | queda ESPERANDO un bloqueo (transactionid) |
|  2.01 | B | bloquea lote 12 |
|  2.01 | A | 40P01 deadlock detected → ROLLBACK |
|  2.03 | A | se libera el bloqueo y continúa |
|  2.03 | B | se libera el bloqueo y continúa |
|  2.32 | B | COMMIT ✔ |

**Orden FEFO común (ambas: SU-2411A→SU-2411B)**

| t (s) | Sesión | Evento |
|---:|:---:|---|
|  0.01 | A | bloquea lote 12 |
|  0.22 | B | queda ESPERANDO un bloqueo (transactionid) |
|  1.02 | A | bloquea lote 13 |
|  1.32 | A | COMMIT ✔ |
|  1.32 | B | bloquea lote 12 |
|  1.32 | B | se libera el bloqueo y continúa |
|  2.32 | B | bloquea lote 13 |
|  2.62 | B | COMMIT ✔ |

### E7 · Costo bajo contención: 20 clientes reservan 1 unidad del mismo lote a la vez

| Estrategia | Reservas OK | Reintentos (40001) | Errores | Tiempo total (s) | Divergencias |
|---|---:|---:|---:|---:|---:|
| READ COMMITTED + FOR UPDATE | 20 | 0 | 0 | 1.17 | 0 |
| SERIALIZABLE + reintento | 20 | 190 | 0 | 3.1 | 0 |
