# Igual que ejecutar_todo.sh, usando el psql del contenedor (no requiere PostgreSQL instalado en Windows).
# Uso (desde la carpeta del repositorio):  docker compose up -d ;  .\scripts\ejecutar_todo.ps1
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
New-Item -ItemType Directory -Force -Path evidencias | Out-Null
function Psql([string]$archivo, [string]$salida, [switch]$silencioso) {
    $a = @("compose", "exec", "-T", "db", "psql", "-X", "-U", "si_admin", "-d", "smart_inventory", "-v", "ON_ERROR_STOP=1")
    if ($silencioso) { $a += "-q" }
    $a += @("-f", "/work/$archivo")
    if ($salida) { docker @args 2>&1 | Out-File -Encoding utf8 $salida } else { docker @args }
    if ($LASTEXITCODE -ne 0) { throw "Falló $archivo" }
}
Psql "sql/01_schema.sql" -silencioso
Psql "sql/02_seed.sql" "evidencias/carga_semilla.txt" -silencioso
Psql "tests/pruebas_integridad.sql" "evidencias/pruebas_integridad_resultados.txt" -silencioso
Psql "sql/03_queries.sql" "evidencias/consultas_resultados.txt"
docker compose exec -T db psql -X -U si_admin -d smart_inventory -f /work/sql/04_transactions.sql 2>&1 | Out-File -Encoding utf8 evidencias/transacciones_resultados.txt
Psql "sql/05_indexes_views.sql" -silencioso
Get-Content evidencias/pruebas_integridad_resultados.txt -Tail 3
Write-Host "Listo: resultados en evidencias/"
