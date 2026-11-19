/* ════════════════════════════════════════════════════════════════════
   SCRIPT 04 · Transformaciones MongoDB: perfiles (T11–T15) y campañas (T20)
   Lee el JSON crudo de stg.mongo_* (lo deja ahí extraer_mongo.py) con OPENJSON.
   Resultado:
     - stg.EquivalenciaLinea  tabla de equivalencias de líneas (T13)
     - stg.perfil_vigente     1 perfil por paciente, ya limpio (T11–T15);
                              también lo usa el script 05 para el consentimiento (T19)
     - DIM_Paciente           se enriquece con los datos del perfil
     - DIM_Campana + stg.campana_linea (líneas promocionadas en filas, para T21)
   Requisitos: 01, 02, extraer_mongo.py y 03 ya ejecutados.
   ════════════════════════════════════════════════════════════════════ */
USE CLINICABI_DW_Grupo1;
GO

/* ═══════════ T13 · Tabla de equivalencias → 6 líneas oficiales del OLTP ═══════════
   La variante se guarda en minúsculas y sin tildes; al comparar se usa
   TRIM + intercalación CI_AI (ignora mayúsculas y tildes), así "ODONTOLOGÍA",
   "odontologia" y " Odontología " caen en la misma fila. Las variantes que no
   son el nombre oficial (PyP, Salud oral, Imagenología…) se mapean a mano. */
DROP TABLE IF EXISTS stg.EquivalenciaLinea;
CREATE TABLE stg.EquivalenciaLinea (
    Variante     NVARCHAR(60) COLLATE Latin1_General_CI_AI NOT NULL PRIMARY KEY,
    LineaOficial NVARCHAR(60) NOT NULL
);
INSERT INTO stg.EquivalenciaLinea (Variante, LineaOficial) VALUES
 (N'consulta externa',       N'Consulta externa'),
 (N'consulta',               N'Consulta externa'),
 (N'laboratorio clinico',    N'Laboratorio clínico'),
 (N'laboratorio',            N'Laboratorio clínico'),
 (N'lab. clinico',           N'Laboratorio clínico'),
 (N'imagenes diagnosticas',  N'Imágenes diagnósticas'),
 (N'imagenes',               N'Imágenes diagnósticas'),
 (N'imagenologia',           N'Imágenes diagnósticas'),
 (N'odontologia',            N'Odontología'),
 (N'salud oral',             N'Odontología'),
 (N'promocion y prevencion', N'Promoción y prevención'),
 (N'pyp',                    N'Promoción y prevención'),
 (N'p y p',                  N'Promoción y prevención'),
 (N'prevencion',             N'Promoción y prevención'),
 (N'cirugia ambulatoria',    N'Cirugía ambulatoria'),
 (N'cirugia',                N'Cirugía ambulatoria');

-- Control: toda línea oficial del OLTP debe estar en la tabla (si no, falla aquí)
IF EXISTS (SELECT 1 FROM stg.oltp_LineasServicio l
           WHERE NOT EXISTS (SELECT 1 FROM stg.EquivalenciaLinea e WHERE e.LineaOficial = l.Nombre))
    THROW 50001, 'T13: hay una línea oficial del OLTP sin equivalencia.', 1;
GO

/* ═══════════════════ PERFILES DE PACIENTES (T11–T15) ═══════════════════ */

/* Paso 1 · Lectura del JSON.
   T11: pacienteId llega como número (5.155) o como texto (60, ej. "3091").
        Se lee como texto y se convierte a INT, ANTES de buscar duplicados (T12);
        si no, "3091" y 3091 parecerían pacientes distintos. */
DROP TABLE IF EXISTS #Perfiles;
SELECT p.MongoId,
       CAST(TRIM(j.pacienteId) AS INT)                       AS PacienteID,          -- T11
       CONVERT(DATETIME2(0), j.fechaActualizacion, 127)      AS FechaActualizacion,  -- UTC
       j.origenRegistro, j.canalPreferido,
       j.cEmail, j.cSms, j.cWhatsapp,
       j.programa, j.nivelRiesgo, j.adherencia,
       p.Doc
INTO #Perfiles
FROM stg.mongo_perfiles_pacientes p
CROSS APPLY OPENJSON(p.Doc) WITH (
    pacienteId         NVARCHAR(20) '$.pacienteId',
    fechaActualizacion NVARCHAR(30) '$.fechaActualizacion."$date"',
    origenRegistro     NVARCHAR(20) '$.origenRegistro',
    canalPreferido     NVARCHAR(15) '$.canalPreferido',
    cEmail             NVARCHAR(10) '$.consentimientos.email',
    cSms               NVARCHAR(10) '$.consentimientos.sms',
    cWhatsapp          NVARCHAR(10) '$.consentimientos.whatsapp',
    programa           NVARCHAR(40) '$.programaRiesgo.programa',
    nivelRiesgo        NVARCHAR(10) '$.programaRiesgo.nivelRiesgo',
    adherencia         NVARCHAR(10) '$.programaRiesgo.adherencia') j;

SELECT 'T11' AS Regla, COUNT(*) AS PerfilesLeidos,
       SUM(CASE WHEN j.type = 1 THEN 1 ELSE 0 END) AS PacienteIdComoTexto_Convertidos
FROM stg.mongo_perfiles_pacientes p
CROSS APPLY OPENJSON(p.Doc) j WHERE j.[key] = 'pacienteId';

/* Paso 2 · T12: un perfil por paciente = el de fechaActualizacion más reciente
   (desempate estable: MongoId mayor). Se hace después de T11. */
DROP TABLE IF EXISTS #Vigente;
SELECT *
INTO #Vigente
FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY PacienteID
                                   ORDER BY FechaActualizacion DESC, MongoId DESC) AS rn
      FROM #Perfiles) x
WHERE rn = 1;

SELECT 'T12' AS Regla, (SELECT COUNT(*) FROM #Perfiles) AS Perfiles,
       COUNT(*) AS PacientesUnicos, (SELECT COUNT(*) FROM #Perfiles) - COUNT(*) AS PerfilesDescartadosPorAntiguos
FROM #Vigente;

/* Paso 3 · T13: lineasInteres (arreglo) → filas → línea oficial por la tabla
   de equivalencias → texto separado por comas sin repetidos. */
DROP TABLE IF EXISTS #LineasPerfil;
SELECT DISTINCT v.MongoId, e.LineaOficial
INTO #LineasPerfil
FROM #Vigente v
CROSS APPLY OPENJSON(v.Doc, '$.lineasInteres') l
JOIN stg.EquivalenciaLinea e ON e.Variante = TRIM(l.value);

SELECT 'T13' AS Regla,
       COUNT(*) AS ValoresLineaEnPerfilesVigentes,
       SUM(CASE WHEN l.value COLLATE Latin1_General_BIN <> e.LineaOficial COLLATE Latin1_General_BIN
                THEN 1 ELSE 0 END) AS ValoresEstandarizados,          -- distinto (mayúsculas, tildes, espacios o sinónimo)
       SUM(CASE WHEN e.Variante IS NULL THEN 1 ELSE 0 END) AS SinEquivalencia_debe_ser_0
FROM #Vigente v
CROSS APPLY OPENJSON(v.Doc, '$.lineasInteres') l
LEFT JOIN stg.EquivalenciaLinea e ON e.Variante = TRIM(l.value);

/* Paso 4 · T15: desanidar encuestasSatisfaccion; puntaje texto → INT;
   NPS promedio por paciente y clasificación. Con promedio decimal se usan
   los cortes ≥ 9 Promotor, ≥ 7 Pasivo, < 7 Detractor. */
DROP TABLE IF EXISTS #NPS;
SELECT v.MongoId,
       CAST(AVG(CAST(TRY_CAST(e.puntaje AS INT) AS DECIMAL(6,2))) AS DECIMAL(4,2)) AS NPSPromedio,
       COUNT(*) AS Encuestas
INTO #NPS
FROM #Vigente v
CROSS APPLY OPENJSON(v.Doc, '$.encuestasSatisfaccion') WITH (puntaje NVARCHAR(10) '$.puntaje') e
GROUP BY v.MongoId;

/* Paso 5 · stg.perfil_vigente = perfil final por paciente con T14 aplicada:
   - consentimientos true / "SI" → 1 ; false / "NO" / faltante → 0
   - sin programaRiesgo → "Sin programa" y nivel "No aplica"
   - nivelRiesgo en cualquier mayúscula → Alto / Medio / Bajo
   - adherencia "85%" → 85 ; 0.85 → 85 ; 85 → 85 */
DROP TABLE IF EXISTS stg.perfil_vigente;
SELECT v.MongoId, v.PacienteID, v.FechaActualizacion,
       ISNULL(v.origenRegistro, N'Sin dato') AS OrigenRegistro,
       ISNULL(LOWER(v.canalPreferido), N'Sin dato') AS CanalPreferido,
       CAST(CASE WHEN v.cEmail    IN (N'true', N'SI') THEN 1 ELSE 0 END AS BIT) AS AceptaEmail,
       CAST(CASE WHEN v.cSms      IN (N'true', N'SI') THEN 1 ELSE 0 END AS BIT) AS AceptaSMS,
       CAST(CASE WHEN v.cWhatsapp IN (N'true', N'SI') THEN 1 ELSE 0 END AS BIT) AS AceptaWhatsApp,
       ISNULL((SELECT STRING_AGG(lp.LineaOficial, N', ') WITHIN GROUP (ORDER BY lp.LineaOficial)
               FROM #LineasPerfil lp WHERE lp.MongoId = v.MongoId), N'') AS LineasInteres,
       ISNULL(v.programa, N'Sin programa') AS ProgramaRiesgo,
       CASE UPPER(TRIM(v.nivelRiesgo)) WHEN N'ALTO' THEN N'Alto' WHEN N'MEDIO' THEN N'Medio'
                                       WHEN N'BAJO' THEN N'Bajo' ELSE N'No aplica' END AS NivelRiesgo,
       CASE WHEN v.adherencia LIKE N'%[%]' THEN CAST(REPLACE(v.adherencia, N'%', N'') AS INT)
            WHEN TRY_CAST(v.adherencia AS DECIMAL(9,4)) <= 1 THEN CAST(ROUND(CAST(v.adherencia AS DECIMAL(9,4)) * 100, 0) AS INT)
            ELSE CAST(ROUND(TRY_CAST(v.adherencia AS DECIMAL(9,4)), 0) AS INT) END AS Adherencia,
       n.NPSPromedio,
       CASE WHEN n.NPSPromedio IS NULL THEN N'Sin encuesta'
            WHEN n.NPSPromedio >= 9    THEN N'Promotor'
            WHEN n.NPSPromedio >= 7    THEN N'Pasivo'
            ELSE N'Detractor' END AS TipoNPS
INTO stg.perfil_vigente
FROM #Vigente v
LEFT JOIN #NPS n ON n.MongoId = v.MongoId;

CREATE UNIQUE INDEX UX_perfil_vigente ON stg.perfil_vigente (PacienteID);

SELECT 'T14' AS Regla,
       SUM(CASE WHEN v.cEmail IN (N'SI', N'NO') OR v.cSms IN (N'SI', N'NO') OR v.cWhatsapp IN (N'SI', N'NO') THEN 1 ELSE 0 END) AS PerfilesConsentimientoTexto,
       SUM(CASE WHEN v.programa IS NULL THEN 1 ELSE 0 END) AS SinPrograma,
       SUM(CASE WHEN v.nivelRiesgo COLLATE Latin1_General_CS_AS NOT IN (N'Alto', N'Medio', N'Bajo') THEN 1 ELSE 0 END) AS NivelRiesgoNormalizado,
       SUM(CASE WHEN v.adherencia LIKE N'%[%]' THEN 1 ELSE 0 END) AS AdherenciaPorcentajeTexto,
       SUM(CASE WHEN TRY_CAST(v.adherencia AS DECIMAL(9,4)) <= 1 THEN 1 ELSE 0 END) AS AdherenciaFraccion
FROM #Vigente v;

SELECT 'T15' AS Regla, COUNT(*) AS PacientesConEncuesta, SUM(Encuestas) AS Encuestas,
       (SELECT COUNT(*) FROM #Vigente v CROSS APPLY OPENJSON(v.Doc, '$.encuestasSatisfaccion') e
        WHERE JSON_VALUE(e.value, '$.puntaje') IS NOT NULL
          AND (SELECT type FROM OPENJSON(e.value) WHERE [key] = 'puntaje') = 1) AS PuntajesTextoConvertidos
FROM #NPS;

SELECT TipoNPS, COUNT(*) AS Pacientes FROM stg.perfil_vigente GROUP BY TipoNPS;

/* Paso 6 · Enriquecer DIM_Paciente con el perfil vigente.
   Los pacientes sin perfil conservan los valores por defecto del script 03. */
UPDATE dp
SET TienePerfil = 1, OrigenRegistro = pv.OrigenRegistro, CanalPreferido = pv.CanalPreferido,
    AceptaEmail = pv.AceptaEmail, AceptaSMS = pv.AceptaSMS, AceptaWhatsApp = pv.AceptaWhatsApp,
    LineasInteres = pv.LineasInteres, ProgramaRiesgo = pv.ProgramaRiesgo, NivelRiesgo = pv.NivelRiesgo,
    Adherencia = pv.Adherencia, NPSPromedio = pv.NPSPromedio, TipoNPS = pv.TipoNPS
FROM dbo.DIM_Paciente dp
JOIN stg.perfil_vigente pv ON pv.PacienteID = dp.PacienteID;

SELECT 'DIM_Paciente' AS Tabla, SUM(CAST(TienePerfil AS INT)) AS PacientesConPerfil,
       SUM(CASE WHEN TienePerfil = 0 AND PacienteKey <> -1 THEN 1 ELSE 0 END) AS PacientesSinPerfil,
       (SELECT COUNT(*) FROM stg.perfil_vigente pv
        WHERE NOT EXISTS (SELECT 1 FROM dbo.DIM_Paciente d WHERE d.PacienteID = pv.PacienteID)) AS PerfilesDePacienteInexistente
FROM dbo.DIM_Paciente;

DROP TABLE #Perfiles, #Vigente, #LineasPerfil, #NPS;
GO

/* ═══════════════════════ CAMPAÑAS (T20) → DIM_Campana ═══════════════════════
   - presupuesto texto ("9.200.000", "$22.500.000") → número (se quitan $ y puntos)
   - responsable faltante o vacío → "Sin asignar"; codigoBeneficio faltante → "Sin código"
   - canales y lineasPromocionadas (arreglos) → texto separado por comas;
     las líneas pasan por la tabla de equivalencias T13
   - segmentoObjetivo → SexoObjetivo (F / M / Todos), EdadMin, EdadMax (NULL = sin límite)
   - fechas UTC → hora de Colombia (UTC-5) */

-- Líneas promocionadas en filas (estandarizadas); la usa la atribución T21
DROP TABLE IF EXISTS stg.campana_linea;
SELECT DISTINCT c.MongoId AS CampanaID, e.LineaOficial AS LineaServicio
INTO stg.campana_linea
FROM stg.mongo_campanas c
CROSS APPLY OPENJSON(c.Doc, '$.lineasPromocionadas') l
JOIN stg.EquivalenciaLinea e ON e.Variante = TRIM(l.value);

INSERT INTO dbo.DIM_Campana (CampanaID, NombreCampana, Objetivo, Estado, FechaInicio, FechaFin, Anio, Canales,
       LineasPromocionadas, SexoObjetivo, EdadMin, EdadMax, DescuentoOfrecido, CodigoBeneficio, Presupuesto, Responsable)
SELECT c.MongoId,
       j.nombre, j.objetivo, j.estado,
       DATEADD(HOUR, -5, CONVERT(DATETIME2(0), j.fechaInicio, 127)),
       DATEADD(HOUR, -5, CONVERT(DATETIME2(0), j.fechaFin, 127)),
       YEAR(DATEADD(HOUR, -5, CONVERT(DATETIME2(0), j.fechaInicio, 127))),
       (SELECT STRING_AGG(TRIM(x.value), N', ') WITHIN GROUP (ORDER BY CAST(x.[key] AS INT))
        FROM OPENJSON(c.Doc, '$.canales') x),
       ISNULL((SELECT STRING_AGG(cl.LineaServicio, N', ') WITHIN GROUP (ORDER BY cl.LineaServicio)
               FROM stg.campana_linea cl WHERE cl.CampanaID = c.MongoId), N''),
       ISNULL(UPPER(TRIM(j.segSexo)), N'Todos'),
       j.segEdadMin, j.segEdadMax,
       j.descuento,
       ISNULL(NULLIF(TRIM(j.codigo), N''), N'Sin código'),
       CAST(REPLACE(REPLACE(REPLACE(j.presupuesto, N'$', N''), N'.', N''), N' ', N'') AS DECIMAL(14,2)),  -- números enteros en pesos
       ISNULL(NULLIF(TRIM(j.responsable), N''), N'Sin asignar')
FROM stg.mongo_campanas c
CROSS APPLY OPENJSON(c.Doc) WITH (
    nombre      NVARCHAR(100) '$.nombre',
    objetivo    NVARCHAR(60)  '$.objetivo',
    estado      NVARCHAR(20)  '$.estado',
    fechaInicio NVARCHAR(30)  '$.fechaInicio."$date"',
    fechaFin    NVARCHAR(30)  '$.fechaFin."$date"',
    segSexo     NVARCHAR(10)  '$.segmentoObjetivo.sexo',
    segEdadMin  INT           '$.segmentoObjetivo.edadMin',
    segEdadMax  INT           '$.segmentoObjetivo.edadMax',
    descuento   DECIMAL(5,2)  '$.descuentoOfrecido',
    codigo      NVARCHAR(20)  '$.codigoBeneficio',
    presupuesto NVARCHAR(30)  '$.presupuesto',
    responsable NVARCHAR(80)  '$.responsable') j;

SELECT 'T20' AS Regla, COUNT(*) AS Campanas,
       (SELECT COUNT(*) FROM stg.mongo_campanas WHERE JSON_VALUE(Doc, '$.presupuesto') LIKE N'%[^0-9]%') AS PresupuestoTextoConvertido,
       SUM(CASE WHEN Responsable = N'Sin asignar' THEN 1 ELSE 0 END) AS ResponsableSinAsignar,
       SUM(CASE WHEN CodigoBeneficio = N'Sin código' THEN 1 ELSE 0 END) AS SinCodigoBeneficio,
       SUM(CASE WHEN SexoObjetivo <> N'Todos' OR EdadMin IS NOT NULL THEN 1 ELSE 0 END) AS ConSegmento
FROM dbo.DIM_Campana WHERE CampanaKey <> -1;

SELECT CampanaID, NombreCampana, FechaInicio, Canales, LineasPromocionadas, SexoObjetivo, EdadMin, EdadMax, Presupuesto, Responsable
FROM dbo.DIM_Campana ORDER BY CampanaID;
GO
