/* Respuestas de control a las 8 preguntas de negocio, calculadas sobre el DW.
   Sirven para verificar las cifras del dashboard y para el documento técnico.
   (No hacen parte del ETL.) */
USE CLINICABI_DW_Grupo1;
GO

-- P1 · Crecimiento de facturación y margen 2025 vs 2024
SELECT t.Anio, SUM(f.ValorNeto) AS Facturacion, SUM(f.Margen) AS Margen,
       CAST(100.0 * SUM(f.Margen) / SUM(f.ValorNeto) AS DECIMAL(5,2)) AS MargenPct,
       COUNT(DISTINCT f.AtencionID) AS Atenciones, COUNT(DISTINCT f.PacienteKey) AS Pacientes
FROM dbo.FACT_Atenciones f JOIN dbo.DIM_Tiempo t ON t.TiempoKey = f.TiempoKey
GROUP BY t.Anio ORDER BY t.Anio;

-- P2 · Concentración por línea, especialidad (top 5) y región de la sede
SELECT s.LineaServicio, SUM(f.ValorNeto) AS Facturacion,
       CAST(100.0 * SUM(f.ValorNeto) / SUM(SUM(f.ValorNeto)) OVER () AS DECIMAL(5,2)) AS Pct
FROM dbo.FACT_Atenciones f JOIN dbo.DIM_Servicio s ON s.ServicioKey = f.ServicioKey
GROUP BY s.LineaServicio ORDER BY Facturacion DESC;

SELECT TOP 5 s.Especialidad, SUM(f.ValorNeto) AS Facturacion,
       CAST(100.0 * SUM(f.ValorNeto) / (SELECT SUM(ValorNeto) FROM dbo.FACT_Atenciones) AS DECIMAL(5,2)) AS Pct
FROM dbo.FACT_Atenciones f JOIN dbo.DIM_Servicio s ON s.ServicioKey = f.ServicioKey
GROUP BY s.Especialidad ORDER BY Facturacion DESC;

SELECT se.Region, SUM(f.ValorNeto) AS Facturacion,
       CAST(100.0 * SUM(f.ValorNeto) / SUM(SUM(f.ValorNeto)) OVER () AS DECIMAL(5,2)) AS Pct
FROM dbo.FACT_Atenciones f JOIN dbo.DIM_Sede se ON se.SedeKey = f.SedeKey
GROUP BY se.Region ORDER BY Facturacion DESC;

-- P3 · Crecimiento por modalidad (atenciones y facturación)
SELECT m.Modalidad,
       COUNT(DISTINCT CASE WHEN t.Anio = 2024 THEN f.AtencionID END) AS Aten2024,
       COUNT(DISTINCT CASE WHEN t.Anio = 2025 THEN f.AtencionID END) AS Aten2025,
       CAST(100.0 * COUNT(DISTINCT CASE WHEN t.Anio = 2025 THEN f.AtencionID END)
            / NULLIF(COUNT(DISTINCT CASE WHEN t.Anio = 2024 THEN f.AtencionID END), 0) - 100 AS DECIMAL(6,2)) AS CrecAtencionesPct,
       SUM(CASE WHEN t.Anio = 2024 THEN f.ValorNeto END) AS Fact2024,
       SUM(CASE WHEN t.Anio = 2025 THEN f.ValorNeto END) AS Fact2025,
       CAST(100.0 * SUM(CASE WHEN t.Anio = 2025 THEN f.ValorNeto END)
            / NULLIF(SUM(CASE WHEN t.Anio = 2024 THEN f.ValorNeto END), 0) - 100 AS DECIMAL(6,2)) AS CrecFacturacionPct
FROM dbo.FACT_Atenciones f
JOIN dbo.DIM_Tiempo t ON t.TiempoKey = f.TiempoKey
JOIN dbo.DIM_Modalidad m ON m.ModalidadKey = f.ModalidadKey
GROUP BY m.Modalidad ORDER BY CrecAtencionesPct DESC;

-- P4 · Margen por tipo de afiliación y cartera (ValorAseguradora) por aseguradora
SELECT a.TipoAfiliacion, SUM(f.ValorNeto) AS Facturacion, SUM(f.Margen) AS Margen,
       CAST(100.0 * SUM(f.Margen) / SUM(f.ValorNeto) AS DECIMAL(5,2)) AS MargenPct
FROM dbo.FACT_Atenciones f JOIN dbo.DIM_Aseguradora a ON a.AseguradoraKey = f.AseguradoraKey
GROUP BY a.TipoAfiliacion ORDER BY MargenPct DESC;

SELECT a.NombreAseguradora, a.TipoAfiliacion, SUM(f.ValorAseguradora) AS Cartera,
       CAST(100.0 * SUM(f.ValorAseguradora) / SUM(SUM(f.ValorAseguradora)) OVER () AS DECIMAL(5,2)) AS PctCartera
FROM dbo.FACT_Atenciones f JOIN dbo.DIM_Aseguradora a ON a.AseguradoraKey = f.AseguradoraKey
GROUP BY a.NombreAseguradora, a.TipoAfiliacion ORDER BY Cartera DESC;

-- P5 · Conversión a cita por canal (base = contactos; para app la base es impresión)
SELECT c.NombreCanal, COUNT(*) AS Contactos, SUM(f.Clic) AS Clics, SUM(f.CitaAgendada) AS Citas,
       CAST(100.0 * SUM(f.CitaAgendada) / COUNT(*) AS DECIMAL(5,2)) AS TasaCitaPct,
       CAST(100.0 * SUM(f.Clic) / COUNT(*) AS DECIMAL(5,2)) AS TasaClicPct,
       CAST(100.0 * SUM(f.CitaAgendada) / NULLIF(SUM(f.Clic), 0) AS DECIMAL(5,2)) AS CitaPorClicPct
FROM dbo.FACT_InteraccionCampana f JOIN dbo.DIM_CanalContacto c ON c.CanalKey = f.CanalKey
GROUP BY c.NombreCanal ORDER BY TasaCitaPct DESC;

-- P6 · Atenciones por paciente según programa de riesgo y nivel
SELECT CASE WHEN p.ProgramaRiesgo = N'Sin programa' THEN N'Sin programa' ELSE N'Con programa' END AS Grupo,
       p.NivelRiesgo,
       COUNT(DISTINCT f.PacienteKey) AS Pacientes, COUNT(DISTINCT f.AtencionID) AS Atenciones,
       CAST(1.0 * COUNT(DISTINCT f.AtencionID) / COUNT(DISTINCT f.PacienteKey) AS DECIMAL(6,2)) AS AtencionesPorPaciente
FROM dbo.FACT_Atenciones f JOIN dbo.DIM_Paciente p ON p.PacienteKey = f.PacienteKey
GROUP BY ROLLUP (CASE WHEN p.ProgramaRiesgo = N'Sin programa' THEN N'Sin programa' ELSE N'Con programa' END, p.NivelRiesgo)
ORDER BY 1, 2;

-- P7 · Semana de la salud 2024 vs 2025: facturación atribuida y ROI
SELECT c.CampanaID, c.NombreCampana, c.Presupuesto,
       ISNULL(SUM(f.ValorNeto), 0) AS FacturacionAtribuida,
       COUNT(DISTINCT f.AtencionID) AS AtencionesAtribuidas,
       CAST((ISNULL(SUM(f.ValorNeto), 0) - c.Presupuesto) / c.Presupuesto AS DECIMAL(8,4)) AS ROI
FROM dbo.DIM_Campana c LEFT JOIN dbo.FACT_Atenciones f ON f.CampanaKey = c.CampanaKey
WHERE c.CampanaKey <> -1
GROUP BY c.CampanaID, c.NombreCampana, c.Presupuesto
ORDER BY c.CampanaID;

-- P8 · Sin consentimiento y fuera de segmento por campaña
SELECT c.CampanaID, c.NombreCampana, COUNT(*) AS Envios,
       SUM(f.EnviadoSinConsentimiento) AS SinConsentimiento,
       CAST(100.0 * SUM(f.EnviadoSinConsentimiento) / COUNT(*) AS DECIMAL(5,2)) AS PctSinConsentimiento,
       SUM(f.FueraDeSegmento) AS FueraDeSegmento
FROM dbo.FACT_InteraccionCampana f JOIN dbo.DIM_Campana c ON c.CampanaKey = f.CampanaKey
GROUP BY c.CampanaID, c.NombreCampana
ORDER BY SUM(f.EnviadoSinConsentimiento) + SUM(f.FueraDeSegmento) DESC;

-- Extra para la página 3: NPS de pacientes con encuesta
SELECT COUNT(*) AS PacientesConEncuesta,
       CAST(100.0 * SUM(CASE WHEN TipoNPS = N'Promotor' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS PctPromotores,
       CAST(100.0 * SUM(CASE WHEN TipoNPS = N'Detractor' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS PctDetractores,
       CAST(100.0 * (SUM(CASE WHEN TipoNPS = N'Promotor' THEN 1 ELSE 0 END) - SUM(CASE WHEN TipoNPS = N'Detractor' THEN 1 ELSE 0 END)) / COUNT(*) AS DECIMAL(5,2)) AS NPS
FROM dbo.DIM_Paciente WHERE TipoNPS <> N'Sin encuesta';
GO
