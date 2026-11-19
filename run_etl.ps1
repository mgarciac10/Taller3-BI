<#
  ORQUESTADOR DEL ETL · CLINICABI_DW_Grupo1
  Corre todo desde cero, sin intervención: borra y crea el DW, staging,
  extrae MongoDB, transforma, carga hechos, atribuye (T21) y valida.

  Prerrequisitos (fuentes del docente, ya cargadas):
    - SQL Server con CLINICABI_OLTP (01_Crear_OLTP.sql + 02_Poblar_OLTP.sql)
    - MongoDB con clinica_bi (ver LEEME_carga_MongoDB.txt)
    - sqlcmd, Python 3 con:  pip install -r mongo/requirements.txt

  Uso:   .\run_etl.ps1                         (instancia por defecto localhost\SQLEXPRESS)
         .\run_etl.ps1 -Servidor "MIPC\SQL2022" -MongoUri "mongodb://localhost:27017"
  Salida completa en evidencias\salida_run_etl.txt
#>
param(
    [string]$Servidor = "localhost\SQLEXPRESS",
    [string]$MongoUri = "mongodb://localhost:27017"
)
$ErrorActionPreference = "Continue"            # los errores se detectan con $LASTEXITCODE
[Console]::OutputEncoding = [Text.Encoding]::UTF8   # tildes correctas en la salida de sqlcmd/python
Set-Location $PSScriptRoot
$log = "evidencias\salida_run_etl.txt"
"ETL iniciado $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') en $Servidor" | Out-File $log -Encoding utf8
$inicio = Get-Date

function Invoke-Paso([string]$nombre, [scriptblock]$accion) {
    Write-Host "==> $nombre" -ForegroundColor Cyan
    "`n==================== $nombre ====================" | Out-File $log -Append -Encoding utf8
    $t = Get-Date
    & $accion 2>&1 | Out-File $log -Append -Encoding utf8
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR en '$nombre' (ver $log)" -ForegroundColor Red
        exit 1
    }
    Write-Host ("    OK ({0:N1} s)" -f ((Get-Date) - $t).TotalSeconds) -ForegroundColor Green
}

# -b: aborta si hay error SQL · -E: autenticación Windows · -C: confía en el certificado
# -W -s "|": salida compacta y legible
# Instancia local con nombre: go-sqlcmd necesita el prefijo lpc: (memoria compartida),
# porque sin SQL Browser no resuelve la instancia por TCP.
$SqlcmdServidor = if ($Servidor -match '^(localhost|\.|\(local\))\\') { "lpc:$Servidor" } else { $Servidor }
function Invoke-Sql([string]$archivo) {
    sqlcmd -S $SqlcmdServidor -E -C -b -W -s "|" -i $archivo
}

Invoke-Paso "01 Crear DW (base vacía, miembros -1)"      { Invoke-Sql "sql\01_Crear_DW.sql" }
Invoke-Paso "02 Staging + extracción OLTP"               { Invoke-Sql "sql\02_Crear_Staging.sql" }
Invoke-Paso "Extracción MongoDB → stg (Python)"          {
    $env:SQL_SERVER = $Servidor; $env:MONGO_URI = $MongoUri; $env:PYTHONIOENCODING = "utf-8"
    python mongo\extraer_mongo.py
}
Invoke-Paso "03 Dimensiones OLTP (T1–T5, T10)"           { Invoke-Sql "sql\03_ETL_Dimensiones.sql" }
Invoke-Paso "04 Transformaciones Mongo (T11–T15, T20)"   { Invoke-Sql "sql\04_ETL_Mongo_Transform.sql" }
Invoke-Paso "05 Hechos (T6–T9, T16–T19)"                 { Invoke-Sql "sql\05_ETL_Hechos.sql" }
Invoke-Paso "06 Atribución T21"                          { Invoke-Sql "sql\06_Atribucion_T21.sql" }
Invoke-Paso "07 Validación"                              { Invoke-Sql "sql\07_Validacion.sql" }

$total = ((Get-Date) - $inicio).TotalSeconds
"`nETL terminado en {0:N1} s" -f $total | Out-File $log -Append -Encoding utf8
Write-Host ("ETL terminado en {0:N1} s. Resultados de validación en {1}" -f $total, $log) -ForegroundColor Green
