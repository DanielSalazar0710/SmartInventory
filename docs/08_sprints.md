# 10. Gestión del trabajo: registro de sprints

Trabajamos en tres sprints semanales. Cada sprint empezó con una planificación corta sobre el backlog, tuvo un responsable por historia y cerró con una revisión (qué evidencia mostramos) y una retrospectiva (qué cambiamos para el siguiente). El historial del repositorio sigue el mismo orden: cada commit indica a qué sprint pertenece.

**Equipo:** Andretty Ochoa, Jalil Chano y Daniel Salazar.

## Sprint 1 · Reglas, modelo ER, dependencias y normalización

**Objetivo:** acordar las reglas del dominio y un modelo normalizado antes de escribir DDL.

| Historia del backlog | Responsable | Estado |
|---|---|---|
| Levantar reglas del enunciado y supuestos (vencimiento, cuarentena, ajustes, traslados) | Andretty Ochoa | Hecho |
| Decidir saldo derivado vs. balance y cómo evitar divergencias | Daniel Salazar | Hecho |
| Modelo ER con cardinalidades, opcionalidad y nombres de claves | Daniel Salazar | Hecho |
| Relación inicial de recepción/picking, dependencias funcionales y anomalías | Jalil Chano | Hecho |
| Descomposición a 1FN, 2FN y 3FN; análisis BCNF de dos relaciones | Jalil Chano, Andretty Ochoa | Hecho |
| Diccionario de datos inicial | Andretty Ochoa | Hecho |

**Revisión.** Presentamos el diagrama, el diccionario y la descomposición. Se aceptaron con dos cambios: agregar `recepcion`/`recepcion_linea`, porque el modelo inicial no podía representar recepciones parciales, y separar `cliente` del pedido.

**Retrospectiva.**
- *Funcionó:* discutir la decisión libro/balance antes del DDL evitó rehacer tablas.
- *A mejorar:* el diccionario escrito a mano se desactualizaba con cada cambio. Acordamos generarlo desde el catálogo de PostgreSQL (`docs/generar_diccionario.py`) y hacer lo mismo con el diagrama.

## Sprint 2 · DDL, restricciones, datos semilla y consultas

**Objetivo:** un esquema reproducible con reglas hechas cumplir por la base y consultas con resultados.

| Historia del backlog | Responsable | Estado |
|---|---|---|
| `01_schema.sql`: tablas, PK/FK con nombre, CHECK, UNIQUE, política ON DELETE | Daniel Salazar | Hecho |
| Triggers: libro inmutable, balance por trigger, transiciones de estado, recepción | Daniel Salazar | Hecho |
| `02_seed.sql` con casos límite y fechas relativas | Jalil Chano | Hecho |
| Matriz regla–restricción–prueba y 39 pruebas de integridad | Jalil Chano | Hecho |
| Q1–Q4: disponibilidad, vencimientos, FEFO y reposición | Andretty Ochoa | Hecho |
| Q5–Q8: trazabilidad, recepciones parciales, rotación y nivel de servicio | Andretty Ochoa, Daniel Salazar | Hecho |

**Revisión.** Mostramos la carga desde cero sin errores, las 39 pruebas en OK y las ocho consultas con resultados. Observaciones atendidas: la primera versión de la Q1 resolvía los SKU sin stock con un `HAVING` difícil de leer y se reescribió con `UNION ALL … NOT EXISTS`; además, el pedido 8 de la semilla se amplió a 70 unidades para que la Q5 muestre una línea cubierta desde dos ubicaciones.

**Retrospectiva.**
- *Funcionó:* escribir la prueba de cada regla junto con la restricción. Así detectamos que la prueba de "estado inválido" (T06) en realidad la rechazaba el trigger de transiciones y no el CHECK; la cambiamos a un INSERT para probar el CHECK de verdad.
- *A mejorar:* algunos datos semilla no ejercitaban la regla que queríamos mostrar. Por ejemplo, la cinta no aparecía en la reposición porque su OC abierta ya cubría el mínimo; ajustamos su mínimo para mostrar el caso de una OC en tránsito que no alcanza.

## Sprint 3 · Transacciones, concurrencia, vistas, índices e informe

**Objetivo:** demostrar con evidencia la reserva FEFO atómica bajo concurrencia, justificar índices con planes medidos y entregar el informe.

| Historia del backlog | Responsable | Estado |
|---|---|---|
| `04_transactions.sql`: FEFO atómico, fallo parcial, COMMIT/ROLLBACK | Daniel Salazar | Hecho |
| Experimento de dos sesiones (E0–E7) y análisis de anomalías | Daniel Salazar, Jalil Chano | Hecho |
| Vistas del dashboard y su política de actualización | Andretty Ochoa | Hecho |
| Base de volumen y EXPLAIN (ANALYZE, BUFFERS) antes/después | Jalil Chano | Hecho |
| Informe, README y release de scripts | Equipo | Hecho |
| Exposición de 8–10 minutos | Equipo | Pendiente (se prepara después de la entrega escrita) |

**Revisión.** Mostramos las líneas de tiempo del experimento, la comparación de planes y el informe. Tres cambios salieron de la revisión: descartamos un índice propuesto (`lote(id_producto, fecha_vencimiento, …)`) porque la medición mostró que no mejoraba el plan FEFO; corregimos `v_stock_disponible`, que omitía las bodegas donde un SKU no tenía saldo; y, después del análisis de deadlocks, hicimos que el despacho y la cancelación recorran las reservas en el mismo orden FEFO que la reserva.

**Retrospectiva.**
- *Funcionó:* automatizar las dos sesiones con una pausa controlada hizo que las carreras se reprodujeran siempre igual; a mano dependían de la velocidad para cambiar de ventana.
- *A mejorar:* la carga de volumen tarda unos 9 minutos porque cada pedido se reserva con la función real; para una próxima iteración convendría guardar un respaldo de esa base.
