# Smart Inventory · Deber 2 de Bases de Datos (USFQ)

Modelo relacional en PostgreSQL 16 para el inventario de Smart Inventory: lotes, ubicaciones, existencias, movimientos, pedidos, reservas FEFO, proveedores y órdenes de compra, con reglas de integridad hechas cumplir por la base de datos y un experimento de concurrencia reproducible.

**Equipo:** Andretty Ochoa · Jalil Chano · Daniel Salazar

El informe completo está en [`docs/Informe_Deber2_Smart_Inventory.pdf`](docs/Informe_Deber2_Smart_Inventory.pdf).

## Decisión principal

El saldo es **híbrido**: `movimiento` es un libro inmutable y fuente de verdad, y `existencia_lote` es un balance por (lote, ubicación) que solo escriben triggers en la misma transacción que el movimiento. La divergencia se evita con cuatro capas: un único camino de escritura, permisos (`si_app` no puede escribir el saldo), libro inmutable con movimientos compensatorios, y vistas de conciliación que deben devolver 0 filas. La reserva FEFO usa **READ COMMITTED + `SELECT … FOR UPDATE` en orden FEFO**, respaldada por `CHECK (cantidad_reservada <= cantidad_fisica)`.

## Estructura

```
sql/
  01_schema.sql            tablas, PK/FK/CHECK/UNIQUE, triggers, funciones FEFO, conciliación, permisos
  02_seed.sql              datos sintéticos con casos límite (fechas relativas a hoy)
  03_queries.sql           8 consultas (stock, vencimientos, FEFO, reposición, trazabilidad,
                           recepciones parciales, rotación, nivel de servicio)
  04_transactions.sql      reserva FEFO atómica, fallo parcial, COMMIT/ROLLBACK, guion de dos sesiones
  05_indexes_views.sql     vistas del dashboard e índices propuestos
tests/
  pruebas_integridad.sql   39 pruebas (matriz regla–restricción–prueba)
  concurrencia/experimento.py   dos sesiones concurrentes, escenarios E0–E7
benchmarks/
  seed_volumen.sql         base de volumen (24 000 lotes, 20 000 pedidos)
  explain_antes_despues.sql   EXPLAIN (ANALYZE, BUFFERS) sin y con índices
docs/
  Informe_Deber2_Smart_Inventory.pdf   informe final
  01_modelo.md … 09_conclusiones.md    fuentes del informe
  diccionario_datos.md     generado desde el catálogo
  img/diagrama_er.png|svg  diagrama ER generado desde el catálogo
  08_sprints.md            registro de los tres sprints
evidencias/                salidas reales de cada script
scripts/ejecutar_todo.sh|ps1   carga y ejecución completa
```

## Cómo ejecutarlo

### Con Docker (Windows, macOS o Linux)

```powershell
docker compose up -d                 # PostgreSQL 16 en localhost:55433 (usuario si_admin / si_local)
.\scripts\ejecutar_todo.ps1          # Windows: usa el psql del contenedor
```

```bash
PGHOST=localhost PGPORT=55433 PGUSER=si_admin PGPASSWORD=si_local PGDATABASE=smart_inventory \
  scripts/ejecutar_todo.sh           # Linux/macOS con psql instalado
```

El orden de ejecución es `01 → 02 → tests/pruebas_integridad → 03 → 04 → 05`. `01_schema.sql` borra y recrea el esquema `si`, así que todo se puede repetir desde cero. Las salidas quedan en `evidencias/`.

También se puede abrir cada script en DBeaver o pgAdmin y ejecutarlo en ese orden; los parámetros de `03_queries.sql` usan variables de psql con valores por defecto.

### Experimento de concurrencia

```bash
pip install "psycopg[binary]"
PGHOST=localhost PGPORT=55433 PGUSER=si_admin PGPASSWORD=si_local PGDATABASE=smart_inventory \
  python tests/concurrencia/experimento.py
```

Recarga la semilla antes de cada escenario, abre dos sesiones y escribe las líneas de tiempo en `evidencias/concurrencia_resultados.md`. Para hacerlo a mano en dos ventanas, sigue el guion de la sección 5 de `sql/04_transactions.sql`.

### Planes de ejecución

```bash
createdb smart_inventory_perf
psql -d smart_inventory_perf -f sql/01_schema.sql -f sql/05_indexes_views.sql -f benchmarks/seed_volumen.sql   # ~9 min
psql -d smart_inventory_perf -f benchmarks/explain_antes_despues.sql > evidencias/explain_antes_despues.txt
```

### Regenerar el informe

```bash
python docs/generar_er.py && python docs/generar_diccionario.py   # requieren la base cargada y Graphviz
python docs/construir_informe.py && node docs/html_a_pdf.js       # requieren pandoc y Playwright
```

## Resultados principales

| Entregable | Resultado |
|---|---|
| Pruebas de integridad | 39 de 39 OK (FK inválida, cantidad negativa, clave duplicada, fecha inconsistente, transición no permitida y 34 más) |
| Consultas | 8 consultas ejecutables; 4 con joins de 3 o más tablas y agregación; 3 con funciones de ventana |
| Vistas | `v_stock_disponible`, `v_reposicion_sugerida`, `v_nivel_servicio_mensual` (y dos de conciliación) |
| Índices | Trazabilidad: 1 274 → 51 páginas leídas (6,5 ms → 0,1 ms); costo de escritura +16 %; un índice descartado por no mejorar el plan |
| Concurrencia | Sin sobreventa en ningún escenario sobre el modelo; FOR UPDATE atiende los dos pedidos que caben (E2) y rechaza limpio el que no cabe (E3); con 20 clientes, FOR UPDATE 1,17 s y 0 reintentos frente a SERIALIZABLE 3,1 s y 190 reintentos |
