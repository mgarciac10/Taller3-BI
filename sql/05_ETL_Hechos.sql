/* ════════════════════════════════════════════════════════════════════
   SCRIPT 05 · Carga de las tablas de hechos
   Parte A · FACT_Atenciones          (T6, T7, T8, T9)
   Parte B · FACT_InteraccionCampana  (T16, T18, T17, T19)
   Requisitos: dimensiones cargadas (03 y 04).
   ════════════════════════════════════════════════════════════════════ */
USE CLINICABI_DW_Grupo1;
GO

/* ═══════════════ PARTE A · FACT_Atenciones ═══════════════
   Grano: un servicio (línea de DetalleAtencion) de una atención Realizada. */

/* Paso 1 · T6: solo atenciones en estado 'Realizada'.
   Las canceladas e inasistencias NO se cargan; su tasa por modalidad se
   reporta en la validación (script 07). Se calculan las medidas por línea. */
IF OBJECT_ID('tempdb..#Lineas') IS NOT NULL DROP TABLE #Lineas;

SELECT d.DetalleID, d.AtencionID, a.NumeroAtencion, a.PacienteID, a.SedeID, a.ProfesionalID,
       a.DiagnosticoID, a.ModalidadID, a.AseguradoraID, a.OrdenExterna, a.FechaAtencion,
       d.ServicioID, d.Cantidad, d.ValorUnitario, d.PorcentajeDescuento, d.CostoUnitario,
       v.ValorBruto,
       v.ValorDescuento,
       v.ValorBruto - v.ValorDescuento                 AS ValorNeto,
       d.Cantidad * d.CostoUnitario                    AS CostoTotal
INTO #Lineas
FROM stg.oltp_DetalleAtencion d
JOIN stg.oltp_Atenciones      a ON a.AtencionID = d.AtencionID
JOIN stg.oltp_EstadosAtencion e ON e.EstadoID   = a.EstadoID
CROSS APPLY (SELECT CAST(d.Cantidad * d.ValorUnitario AS DECIMAL(14,2)) AS ValorBruto,
                    CAST(ROUND(d.Cantidad * d.ValorUnitario * d.PorcentajeDescuento / 100.0, 2) AS DECIMAL(14,2)) AS ValorDescuento) v
WHERE e.Nombre = N'Realizada';                                   -- T6

/* Paso 2 · T7 (a): totales de pago por atención, separando lo que paga el
   paciente (EsAseguradora = 0) de lo que se cobra a la aseguradora (= 1). */
IF OBJECT_ID('tempdb..#PagosAtencion') IS NOT NULL DROP TABLE #PagosAtencion;

SELECT p.AtencionID,
       SUM(CASE WHEN m.EsAseguradora = 0 THEN p.Valor ELSE 0 END) AS PagoPaciente,
       SUM(CASE WHEN m.EsAseguradora = 1 THEN p.Valor ELSE 0 END) AS PagoAseguradora
INTO #PagosAtencion
FROM stg.oltp_Pagos p
JOIN stg.oltp_MediosPago m ON m.MedioPagoID = p.MedioPagoID
GROUP BY p.AtencionID;

/* Paso 3 · T7 (b): medio de pago principal = el pago de MAYOR valor de la
   atención (desempate: el primer pago registrado). */
IF OBJECT_ID('tempdb..#MedioPrincipal') IS NOT NULL DROP TABLE #MedioPrincipal;

SELECT AtencionID, MedioPago
INTO #MedioPrincipal
FROM (SELECT p.AtencionID, m.Nombre AS MedioPago,
             ROW_NUMBER() OVER (PARTITION BY p.AtencionID ORDER BY p.Valor DESC, p.PagoID) AS rn
      FROM stg.oltp_Pagos p
      JOIN stg.oltp_MediosPago m ON m.MedioPagoID = p.MedioPagoID) x
WHERE rn = 1;

/* Paso 4 · T7 (c): prorrateo del pago del paciente entre las líneas, en
   proporción a su ValorNeto, redondeado al peso. El residuo del redondeo se
   suma a la línea de mayor ValorNeto (rnAjuste = 1), así la suma por
   atención cuadra exacto. ValorAseguradora = ValorNeto − ValorPaciente,
   lo que garantiza ValorPaciente + ValorAseguradora = ValorNeto en cada línea
   y, como los pagos de la atención suman su neto, el total de la aseguradora
   también cuadra al peso (se verifica en el script 07). */
IF OBJECT_ID('tempdb..#Prorrateo') IS NOT NULL DROP TABLE #Prorrateo;

WITH base AS (
    SELECT l.DetalleID, l.AtencionID, l.ValorNeto,
           ISNULL(pa.PagoPaciente, 0) AS PagoPaciente,
           SUM(l.ValorNeto) OVER (PARTITION BY l.AtencionID) AS NetoAtencion,
           ROW_NUMBER() OVER (PARTITION BY l.AtencionID ORDER BY l.ValorNeto DESC, l.DetalleID) AS rnAjuste
    FROM #Lineas l
    LEFT JOIN #PagosAtencion pa ON pa.AtencionID = l.AtencionID
), prel AS (
    SELECT *, CAST(ROUND(PagoPaciente * ValorNeto / NULLIF(NetoAtencion, 0), 0) AS DECIMAL(14,2)) AS PacPrelim
    FROM base
)
SELECT DetalleID,
       ISNULL(PacPrelim, 0)
       + CASE WHEN rnAjuste = 1
              THEN PagoPaciente - ISNULL(SUM(PacPrelim) OVER (PARTITION BY AtencionID), 0)
              ELSE 0 END AS ValorPaciente
INTO #Prorrateo
FROM prel;

/* Paso 5 · Inserción con búsqueda de claves sustitutas.
   T8: orden externa → ProfesionalKey = -1 y DiagnosticoKey = -1.
   T9: AseguradoraKey sale de Atenciones.AseguradoraID (pagador al momento de
       la atención), NO de Pacientes.AseguradoraID.
   CampanaKey = -1 por ahora; la atribución (T21) la actualiza el script 06.
   Cualquier clave no encontrada cae en -1 (se cuenta en la validación). */
INSERT INTO dbo.FACT_Atenciones (TiempoKey, PacienteKey, ServicioKey, SedeKey, ProfesionalKey, AseguradoraKey,
       DiagnosticoKey, ModalidadKey, CampanaKey, DetalleID, AtencionID, NumeroAtencion, MedioPagoPrincipal,
       OrdenExterna, Cantidad, ValorUnitario, PorcentajeDescuento, CostoUnitario, ValorBruto, ValorDescuento,
       ValorNeto, CostoTotal, Margen, ValorPaciente, ValorAseguradora)
SELECT ISNULL(t.TiempoKey, -1),
       ISNULL(dp.PacienteKey, -1),
       ISNULL(ds.ServicioKey, -1),
       ISNULL(se.SedeKey, -1),
       CASE WHEN l.OrdenExterna = 1 THEN -1 ELSE ISNULL(pr.ProfesionalKey, -1) END,   -- T8
       ISNULL(ase.AseguradoraKey, -1),                                                 -- T9
       CASE WHEN l.OrdenExterna = 1 THEN -1 ELSE ISNULL(dg.DiagnosticoKey, -1) END,    -- T8
       ISNULL(mo.ModalidadKey, -1),
       -1,
       l.DetalleID, l.AtencionID, l.NumeroAtencion,
       ISNULL(mp.MedioPago, N'Sin pago'),
       l.OrdenExterna,
       l.Cantidad, l.ValorUnitario, l.PorcentajeDescuento, l.CostoUnitario,
       l.ValorBruto, l.ValorDescuento, l.ValorNeto, l.CostoTotal,
       l.ValorNeto - l.CostoTotal,                                                     -- Margen
       p.ValorPaciente,
       l.ValorNeto - p.ValorPaciente                                                   -- ValorAseguradora
FROM #Lineas l
JOIN #Prorrateo p ON p.DetalleID = l.DetalleID
LEFT JOIN dbo.DIM_Tiempo      t   ON t.TiempoKey      = CONVERT(INT, CONVERT(CHAR(8), l.FechaAtencion, 112))
LEFT JOIN dbo.DIM_Paciente    dp  ON dp.PacienteID    = l.PacienteID
LEFT JOIN dbo.DIM_Servicio    ds  ON ds.ServicioID    = l.ServicioID
LEFT JOIN dbo.DIM_Sede        se  ON se.SedeID        = l.SedeID
LEFT JOIN dbo.DIM_Profesional pr  ON pr.ProfesionalID = l.ProfesionalID
LEFT JOIN dbo.DIM_Aseguradora ase ON ase.AseguradoraID = l.AseguradoraID
LEFT JOIN dbo.DIM_Diagnostico dg  ON dg.DiagnosticoID = l.DiagnosticoID
LEFT JOIN dbo.DIM_Modalidad   mo  ON mo.ModalidadID   = l.ModalidadID
LEFT JOIN #MedioPrincipal     mp  ON mp.AtencionID    = l.AtencionID;

CREATE INDEX IX_FACT_Atenciones_Paciente ON dbo.FACT_Atenciones (PacienteKey, TiempoKey) INCLUDE (AtencionID);

DROP TABLE #Lineas, #PagosAtencion, #MedioPrincipal, #Prorrateo;

SELECT COUNT(*) AS FilasFACT_Atenciones, COUNT(DISTINCT AtencionID) AS Atenciones,
       SUM(ValorNeto) AS ValorNeto, SUM(ValorPaciente) AS ValorPaciente, SUM(ValorAseguradora) AS ValorAseguradora
FROM dbo.FACT_Atenciones;
GO

/* ═══════════════ PARTE B · FACT_InteraccionCampana ═══════════════
   Grano: un documento ÚNICO de interacciones_campanas (paciente × campaña × canal).
   Orden: T16 (duplicados y limpieza) → T18 (fechas) → T17 (pivote) → T19 (cumplimiento). */

/* Paso 1 · T16 (a): eliminar duplicados exactos. El Doc se guardó sin _id, así
   que dos documentos idénticos tienen el mismo Doc: se comparan por su hash
   SHA-256 y se conserva el de menor MongoId. */
IF OBJECT_ID('tempdb..#Unicos') IS NOT NULL DROP TABLE #Unicos;

SELECT MongoId, Doc
INTO #Unicos
FROM (SELECT MongoId, Doc,
             ROW_NUMBER() OVER (PARTITION BY HASHBYTES('SHA2_256', Doc) ORDER BY MongoId) AS rn
      FROM stg.mongo_interacciones_campanas) x
WHERE rn = 1;

SELECT 'T16' AS Regla, (SELECT COUNT(*) FROM stg.mongo_interacciones_campanas) AS DocsStg,
       (SELECT COUNT(*) FROM stg.mongo_interacciones_campanas) - COUNT(*) AS DuplicadosEliminados,
       COUNT(*) AS DocsUnicos
FROM #Unicos;

/* Paso 2 · T16 (b): canal → email / sms / whatsapp / app; campanaId → TRIM + MAYÚSCULAS. */
IF OBJECT_ID('tempdb..#Inter') IS NOT NULL DROP TABLE #Inter;

SELECT u.MongoId, j.pacienteId AS PacienteIdOrigen,
       j.campanaId AS CampanaIdOrigen, UPPER(TRIM(j.campanaId)) AS CampanaID,
       j.canal AS CanalOrigen,
       CASE LOWER(TRIM(j.canal))
            WHEN 'email' THEN 'email' WHEN 'e-mail' THEN 'email' WHEN 'correo' THEN 'email'
            WHEN 'sms' THEN 'sms'
            WHEN 'whatsapp' THEN 'whatsapp' WHEN 'wa' THEN 'whatsapp'
            WHEN 'app' THEN 'app' WHEN 'push' THEN 'app'
       END AS Canal,
       ISNULL(j.dispositivo, N'Sin dato') AS Dispositivo,
       CASE WHEN j.citaAgendada = 'true' THEN 1 ELSE 0 END AS CitaAgendada
INTO #Inter
FROM #Unicos u
CROSS APPLY OPENJSON(u.Doc) WITH (
    pacienteId   INT          '$.pacienteId',
    campanaId    VARCHAR(30)  '$.campanaId',
    canal        VARCHAR(20)  '$.canal',
    dispositivo  NVARCHAR(15) '$.dispositivo',
    citaAgendada VARCHAR(5)   '$.citaAgendada') j;

SELECT 'T16' AS Regla,
       SUM(CASE WHEN CanalOrigen COLLATE Latin1_General_BIN <> Canal THEN 1 ELSE 0 END) AS CanalEstandarizado,
       SUM(CASE WHEN Canal IS NULL THEN 1 ELSE 0 END) AS CanalSinEquivalencia_debe_ser_0,
       SUM(CASE WHEN CampanaIdOrigen COLLATE Latin1_General_BIN <> CampanaID
                  OR DATALENGTH(CampanaIdOrigen) <> DATALENGTH(CampanaID) THEN 1 ELSE 0 END) AS CampanaIdLimpiado
FROM #Inter;

/* Paso 3 · T18: desanidar eventos y unificar la fecha a DATETIME2 en UTC.
   Viene como {"$date":"AAAA-MM-DDThh:mm:ssZ"} (estilo 127) o como texto
   "dd/mm/aaaa hh:mm" en UTC (estilo 103). Luego se pasa a Colombia (UTC-5). */
IF OBJECT_ID('tempdb..#Eventos') IS NOT NULL DROP TABLE #Eventos;

SELECT u.MongoId, e.tipo,
       CASE WHEN e.fechaObj IS NOT NULL THEN 0 ELSE 1 END AS EraTexto,
       DATEADD(HOUR, -5, COALESCE(CONVERT(DATETIME2(0), e.fechaObj, 127),
                                  TRY_CONVERT(DATETIME2(0), e.fechaTxt, 103))) AS FechaCol   -- UTC → UTC-5
INTO #Eventos
FROM #Unicos u
CROSS APPLY OPENJSON(u.Doc, '$.eventos') WITH (
    tipo     VARCHAR(20) '$.tipo',
    fechaObj VARCHAR(30) '$.fecha."$date"',     -- fecha como objeto
    fechaTxt VARCHAR(30) '$.fecha') e;          -- fecha como texto (NULL si es objeto)

SELECT 'T18' AS Regla, COUNT(*) AS Eventos, SUM(EraTexto) AS FechasTextoConvertidas,
       SUM(CASE WHEN FechaCol IS NULL THEN 1 ELSE 0 END) AS FechasSinConvertir_debe_ser_0
FROM #Eventos;

/* Paso 4 · T17: pivote del arreglo eventos → banderas 0/1 (un doc = una fila).
   Abierto = "abierto" o "leido" (WhatsApp/SMS reportan leído).
   HorasHastaApertura = horas entre el primer "entregado" y la primera apertura.
   FechaPrimerEvento da el TiempoKey (T18); FechaClic es insumo de T21. */
IF OBJECT_ID('tempdb..#Pivote') IS NOT NULL DROP TABLE #Pivote;

SELECT MongoId,
       MAX(CASE WHEN tipo = 'enviado'            THEN 1 ELSE 0 END) AS Enviado,
       MAX(CASE WHEN tipo = 'entregado'          THEN 1 ELSE 0 END) AS Entregado,
       MAX(CASE WHEN tipo = 'rebotado'           THEN 1 ELSE 0 END) AS Rebotado,
       MAX(CASE WHEN tipo IN ('abierto','leido') THEN 1 ELSE 0 END) AS Abierto,
       MAX(CASE WHEN tipo = 'impresion'          THEN 1 ELSE 0 END) AS Impresion,
       MAX(CASE WHEN tipo = 'clic'               THEN 1 ELSE 0 END) AS Clic,
       MAX(CASE WHEN tipo = 'baja_suscripcion'   THEN 1 ELSE 0 END) AS BajaSuscripcion,
       MIN(FechaCol) AS FechaPrimerEvento,
       MIN(CASE WHEN tipo = 'clic' THEN FechaCol END) AS FechaClic,
       MIN(CASE WHEN tipo = 'entregado' THEN FechaCol END) AS FechaEntregado,
       MIN(CASE WHEN tipo IN ('abierto','leido') THEN FechaCol END) AS FechaApertura
INTO #Pivote
FROM #Eventos
GROUP BY MongoId;

/* Paso 5 · T19 + inserción.
   - PacienteKey: pacienteId que no existe en el OLTP → -1 (se reporta abajo).
   - EnviadoSinConsentimiento = 1 si el canal requiere autorización y el perfil
     vigente (T12) no la tiene. App no la requiere. Paciente sin perfil → 1
     (no hay autorización registrada).
   - FueraDeSegmento = 1 si la campaña tiene segmentoObjetivo y el paciente no
     cumple la edad AL INICIO DE LA CAMPAÑA o el sexo. Sexo "Sin dato" → 1
     (no se puede verificar que cumpla). Paciente inexistente → 0: no hay
     edad ni sexo que evaluar y ya queda reportado como PacienteKey -1. */
INSERT INTO dbo.FACT_InteraccionCampana (TiempoKey, PacienteKey, CampanaKey, CanalKey, MongoId, PacienteIdOrigen,
       Dispositivo, FechaPrimerEvento, FechaClic, Enviado, Entregado, Rebotado, Abierto, Impresion, Clic,
       BajaSuscripcion, CitaAgendada, EnviadoSinConsentimiento, FueraDeSegmento, HorasHastaApertura)
SELECT ISNULL(t.TiempoKey, -1),
       ISNULL(dp.PacienteKey, -1),                                                       -- T19
       ISNULL(dc.CampanaKey, -1),
       ISNULL(ca.CanalKey, -1),
       i.MongoId, i.PacienteIdOrigen, i.Dispositivo, p.FechaPrimerEvento, p.FechaClic,
       p.Enviado, p.Entregado, p.Rebotado, p.Abierto, p.Impresion, p.Clic, p.BajaSuscripcion, i.CitaAgendada,
       CASE WHEN ca.RequiereConsentimiento = 1
             AND ISNULL(CASE i.Canal WHEN 'email'    THEN pv.AceptaEmail
                                     WHEN 'sms'      THEN pv.AceptaSMS
                                     WHEN 'whatsapp' THEN pv.AceptaWhatsApp END, 0) = 0
            THEN 1 ELSE 0 END,                                                           -- T19 consentimiento
       CASE WHEN dp.PacienteKey IS NULL THEN 0       -- paciente inexistente: ya se reporta como -1, no se evalúa
            WHEN dc.SexoObjetivo IN (N'F', N'M') AND LEFT(dp.Sexo, 1) <> dc.SexoObjetivo THEN 1   -- "Sin dato" ≠ F/M → 1
            WHEN dc.EdadMin IS NOT NULL AND ed.EdadInicio NOT BETWEEN dc.EdadMin AND dc.EdadMax THEN 1
            ELSE 0 END,                                                                  -- T19 segmento
       CAST(DATEDIFF(MINUTE, p.FechaEntregado, p.FechaApertura) / 60.0 AS DECIMAL(10,2))   -- T17
FROM #Inter i
JOIN #Pivote p ON p.MongoId = i.MongoId
LEFT JOIN dbo.DIM_Tiempo        t  ON t.TiempoKey    = CONVERT(INT, CONVERT(CHAR(8), p.FechaPrimerEvento, 112))  -- T18
LEFT JOIN dbo.DIM_Paciente      dp ON dp.PacienteID  = i.PacienteIdOrigen AND dp.PacienteKey <> -1
LEFT JOIN dbo.DIM_Campana       dc ON dc.CampanaID   = i.CampanaID
LEFT JOIN dbo.DIM_CanalContacto ca ON ca.CodigoCanal = i.Canal
LEFT JOIN stg.perfil_vigente    pv ON pv.PacienteID  = i.PacienteIdOrigen
OUTER APPLY (SELECT DATEDIFF(YEAR, dp.FechaNacimiento, dc.FechaInicio)
                    - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, dp.FechaNacimiento, dc.FechaInicio), dp.FechaNacimiento)
                                > CAST(dc.FechaInicio AS DATE) THEN 1 ELSE 0 END AS EdadInicio) ed;  -- edad al inicio de la campaña

DROP TABLE #Unicos, #Inter, #Eventos, #Pivote;

SELECT 'FACT_InteraccionCampana' AS Tabla, COUNT(*) AS Filas,
       SUM(CASE WHEN PacienteKey = -1 THEN 1 ELSE 0 END) AS PacienteInexistente_T19,
       COUNT(DISTINCT CASE WHEN PacienteKey = -1 THEN PacienteIdOrigen END) AS PacienteIdsInexistentes,
       SUM(CASE WHEN CampanaKey = -1 THEN 1 ELSE 0 END) AS SinCampana,
       SUM(CASE WHEN CanalKey = -1 THEN 1 ELSE 0 END) AS SinCanal,
       SUM(CASE WHEN TiempoKey = -1 THEN 1 ELSE 0 END) AS SinFecha,
       SUM(EnviadoSinConsentimiento) AS EnviadoSinConsentimiento,
       SUM(FueraDeSegmento) AS FueraDeSegmento
FROM dbo.FACT_InteraccionCampana;

SELECT c.CodigoCanal, COUNT(*) AS Docs, SUM(f.Enviado) AS Enviado, SUM(f.Entregado) AS Entregado,
       SUM(f.Rebotado) AS Rebotado, SUM(f.Abierto) AS Abierto, SUM(f.Impresion) AS Impresion, SUM(f.Clic) AS Clic,
       SUM(f.CitaAgendada) AS CitaAgendada, SUM(f.EnviadoSinConsentimiento) AS SinConsentimiento,
       CAST(AVG(f.HorasHastaApertura) AS DECIMAL(10,2)) AS HorasPromApertura
FROM dbo.FACT_InteraccionCampana f JOIN dbo.DIM_CanalContacto c ON c.CanalKey = f.CanalKey
GROUP BY c.CodigoCanal;
GO
