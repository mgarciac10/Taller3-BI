/* ════════════════════════════════════════════════════════════════════
   SCRIPT 06 · T21 Atribución de atenciones a campañas (integra SQL + Mongo)
   Regla: una atención Realizada se atribuye a una campaña si
     1) el paciente hizo CLIC en esa campaña (FACT_InteraccionCampana.Clic = 1),
     2) la atención ocurrió en los 15 días SIGUIENTES al clic
        (FechaClic < FechaAtencion <= FechaClic + 15 días; ambas en hora Colombia),
     3) al menos un servicio de la atención es de una línea promocionada por
        la campaña (stg.campana_linea, líneas estandarizadas con T13).
   Si varias campañas cumplen, gana la del clic MÁS RECIENTE.
   Se guarda como columna: FACT_Atenciones.CampanaKey (todas las líneas de la
   atención). -1 = atención no atribuida a ninguna campaña.
   Requisitos: scripts 04 y 05 ejecutados.
   ════════════════════════════════════════════════════════════════════ */
USE CLINICABI_DW_Grupo1;
GO

/* Paso 1 · Candidatos: cada par (atención, clic) que cumple las 3 condiciones. */
IF OBJECT_ID('tempdb..#Candidatos') IS NOT NULL DROP TABLE #Candidatos;

WITH Atencion AS (                     -- una fila por atención realizada, con su fecha y hora
    SELECT DISTINCT f.AtencionID, f.PacienteKey, a.FechaAtencion
    FROM dbo.FACT_Atenciones f
    JOIN stg.oltp_Atenciones a ON a.AtencionID = f.AtencionID
    WHERE f.PacienteKey <> -1
), Clics AS (                          -- clics de pacientes conocidos
    SELECT i.PacienteKey, i.CampanaKey, i.FechaClic, i.MongoId
    FROM dbo.FACT_InteraccionCampana i
    WHERE i.Clic = 1 AND i.PacienteKey <> -1 AND i.CampanaKey <> -1
)
SELECT at.AtencionID, c.CampanaKey, c.FechaClic, c.MongoId, at.FechaAtencion
INTO #Candidatos
FROM Atencion at
JOIN Clics c ON c.PacienteKey = at.PacienteKey                                      -- 1) mismo paciente hizo clic
WHERE at.FechaAtencion >  c.FechaClic                                               -- 2) después del clic…
  AND at.FechaAtencion <= DATEADD(DAY, 15, c.FechaClic)                             --    …y máximo 15 días
  AND EXISTS (SELECT 1                                                              -- 3) ≥ 1 servicio de línea promocionada
              FROM dbo.FACT_Atenciones fl
              JOIN dbo.DIM_Servicio  s  ON s.ServicioKey = fl.ServicioKey
              JOIN dbo.DIM_Campana   dc ON dc.CampanaKey = c.CampanaKey
              JOIN stg.campana_linea cl ON cl.CampanaID  = dc.CampanaID AND cl.LineaServicio = s.LineaServicio
              WHERE fl.AtencionID = at.AtencionID);

/* Paso 2 · Desempate: si varias campañas (o clics) cumplen, gana el clic más reciente. */
IF OBJECT_ID('tempdb..#Atribucion') IS NOT NULL DROP TABLE #Atribucion;

SELECT AtencionID, CampanaKey, FechaClic, FechaAtencion
INTO #Atribucion
FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY AtencionID ORDER BY FechaClic DESC, MongoId DESC) AS rn
      FROM #Candidatos) x
WHERE rn = 1;

/* Paso 3 · Guardar la atribución en todas las líneas de la atención
   (primero se deja todo en -1 para que el script sea re-ejecutable). */
UPDATE dbo.FACT_Atenciones SET CampanaKey = -1 WHERE CampanaKey <> -1;

UPDATE f SET CampanaKey = a.CampanaKey
FROM dbo.FACT_Atenciones f
JOIN #Atribucion a ON a.AtencionID = f.AtencionID;

/* ─────────────── Verificación de la regla ─────────────── */
SELECT 'T21' AS Regla,
       (SELECT COUNT(DISTINCT AtencionID) FROM #Candidatos) AS AtencionesCandidatas,
       (SELECT COUNT(*) FROM (SELECT AtencionID FROM #Candidatos GROUP BY AtencionID
                              HAVING COUNT(DISTINCT CampanaKey) > 1) x) AS AtencionesConEmpateDeCampanas,
       COUNT(*) AS AtencionesAtribuidas,
       (SELECT COUNT(*) FROM dbo.FACT_Atenciones WHERE CampanaKey <> -1) AS LineasAtribuidas,
       (SELECT SUM(ValorNeto) FROM dbo.FACT_Atenciones WHERE CampanaKey <> -1) AS ValorNetoAtribuido
FROM #Atribucion;

-- Cada atención atribuida debe cumplir las 3 condiciones: las 3 filas deben dar 0.
-- Se revisa directo sobre el FACT ya actualizado (independiente de las tablas temporales).
WITH Atrib AS (
    SELECT DISTINCT f.AtencionID, f.PacienteKey, f.CampanaKey, a.FechaAtencion
    FROM dbo.FACT_Atenciones f JOIN stg.oltp_Atenciones a ON a.AtencionID = f.AtencionID
    WHERE f.CampanaKey <> -1
)
SELECT '1) sin clic del paciente en la campaña' AS Verificacion, COUNT(*) AS Incumplen_debe_ser_0
FROM Atrib f
WHERE NOT EXISTS (SELECT 1 FROM dbo.FACT_InteraccionCampana i
                  WHERE i.PacienteKey = f.PacienteKey AND i.CampanaKey = f.CampanaKey AND i.Clic = 1)
UNION ALL
SELECT '2) atención fuera de los 15 días tras el clic', COUNT(*)
FROM Atrib f
WHERE NOT EXISTS (SELECT 1 FROM dbo.FACT_InteraccionCampana i
                  WHERE i.PacienteKey = f.PacienteKey AND i.CampanaKey = f.CampanaKey AND i.Clic = 1
                    AND f.FechaAtencion > i.FechaClic AND f.FechaAtencion <= DATEADD(DAY, 15, i.FechaClic))
UNION ALL
SELECT '3) ningún servicio de línea promocionada', COUNT(*)
FROM Atrib f
WHERE NOT EXISTS (SELECT 1 FROM dbo.FACT_Atenciones fl
                  JOIN dbo.DIM_Servicio  s  ON s.ServicioKey = fl.ServicioKey
                  JOIN dbo.DIM_Campana   dc ON dc.CampanaKey = f.CampanaKey
                  JOIN stg.campana_linea cl ON cl.CampanaID  = dc.CampanaID AND cl.LineaServicio = s.LineaServicio
                  WHERE fl.AtencionID = f.AtencionID);

-- Atenciones e ingresos atribuidos por campaña
SELECT dc.CampanaID, dc.NombreCampana, COUNT(DISTINCT f.AtencionID) AS Atenciones, SUM(f.ValorNeto) AS ValorNeto
FROM dbo.FACT_Atenciones f JOIN dbo.DIM_Campana dc ON dc.CampanaKey = f.CampanaKey
WHERE f.CampanaKey <> -1
GROUP BY dc.CampanaID, dc.NombreCampana
ORDER BY dc.CampanaID;

-- Ejemplo trazable (para la sustentación): 3 atenciones atribuidas con su clic
SELECT TOP 3 a.AtencionID, dc.CampanaID, a.FechaClic, a.FechaAtencion,
       DATEDIFF(HOUR, a.FechaClic, a.FechaAtencion) / 24.0 AS DiasDesdeClic
FROM #Atribucion a JOIN dbo.DIM_Campana dc ON dc.CampanaKey = a.CampanaKey
ORDER BY a.AtencionID;

DROP TABLE #Candidatos, #Atribucion;
GO
