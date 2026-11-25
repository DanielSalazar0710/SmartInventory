#!/usr/bin/env bash
# Carga el esquema desde cero, ejecuta pruebas, consultas y transacciones, y guarda la salida en evidencias/.
# Uso: PGHOST=localhost PGPORT=55433 PGUSER=si_admin PGPASSWORD=si_local PGDATABASE=smart_inventory scripts/ejecutar_todo.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p evidencias
P="psql -X -v ON_ERROR_STOP=1"
$P -q -f sql/01_schema.sql
$P -q -f sql/02_seed.sql            > evidencias/carga_semilla.txt
$P -q -f tests/pruebas_integridad.sql > evidencias/pruebas_integridad_resultados.txt
$P    -f sql/03_queries.sql         > evidencias/consultas_resultados.txt
$P    -f sql/04_transactions.sql    > evidencias/transacciones_resultados.txt 2>&1
$P -q -f sql/05_indexes_views.sql
$P -c "SELECT * FROM si.v_stock_disponible ORDER BY sku, bodega" > evidencias/vista_stock_disponible.txt
tail -n 3 evidencias/pruebas_integridad_resultados.txt
echo "Listo: resultados en evidencias/"
