# 11. Conclusiones y limitaciones

**Conclusiones.**

1. El modelo híbrido nos dio las dos cosas que pedía el caso: cualquier cifra de disponibilidad se explica con movimientos por lote y ubicación, y la reserva tiene una fila concreta sobre la cual bloquear y validar. Las cuatro capas de defensa (único camino de escritura, permisos, libro inmutable y conciliación) mantuvieron libro y balance iguales en todas las pruebas, en la carga de volumen y en todos los escenarios concurrentes.
2. Las reglas viven en la base: 21 reglas de negocio se hacen cumplir con restricciones declarativas, FK compuestas o triggers, y cada una tiene al menos una prueba reproducible (39 de 39 OK).
3. La sobreventa la impide el `CHECK` del balance, no el nivel de aislamiento. `SELECT … FOR UPDATE` en orden FEFO agrega que cada decisión se toma con datos vigentes; en el experimento eso evitó rechazar un pedido que sí se podía atender (E1 frente a E2) y costó 2,6 veces menos que SERIALIZABLE bajo contención (E7).
4. Medir los índices cambió nuestra propuesta: uno de los índices iniciales no aportaba y lo retiramos; los índices sobre FK de la trazabilidad redujeron 25 veces las páginas leídas, a cambio de un 16 % más de costo de escritura.

**Limitaciones.**

- El mínimo y el objetivo de reposición son por SKU para toda la red, no por bodega.
- La reserva no considera la unidad de manipulación (cajas completas frente a unidades) ni la distancia de picking; solo el criterio FEFO.
- Una recepción registrada no se corrige editándola: se compensa con movimientos. Eso preserva la trazabilidad, pero deja la cantidad recibida de la OC con el valor original.
- Los datos de volumen son sintéticos y caben en memoria, y las mediciones de tiempo son de una sola ejecución en caché caliente.
- No se implementaron backorders: un pedido sin stock se rechaza o se reserva parcialmente.

**Referencias.** Elmasri y Navathe, *Fundamentals of Database Systems*; Silberschatz, Korth y Sudarshan, *Database System Concepts*; documentación oficial de PostgreSQL 16 (restricciones, triggers, aislamiento de transacciones, bloqueo explícito, índices y EXPLAIN).
