/* ════════════════════════════════════════════════════════════════════
   SCRIPT 05 · Carga de las tablas de hechos
   Parte A · FACT_Atenciones          (T6, T7, T8, T9)
   Parte B · FACT_InteraccionCampana  (T16–T19) → se agrega en la Fase 5
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
