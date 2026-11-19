/* ════════════════════════════════════════════════════════════════════
   SCRIPT 07 · Validación de la carga (Parte 4 del enunciado)
   Corre al final del ETL. Muestra:
     1) Conteos origen → stg → DW en cada paso, con la explicación de cada
        registro que no llega (ningún descarte queda sin explicar).
     2) Cuadre de dinero: neto OLTP = SUM(ValorNeto) DW = pagos;
        ValorPaciente + ValorAseguradora = ValorNeto.
     3) Uso del miembro -1 en cada dimensión, con su explicación.
     4) Tasas de cancelación e inasistencia por modalidad (OLTP, T6) y T9.
     5) dbo.ReporteCalidad       → problema, registros afectados, regla aplicada.
     6) dbo.ReporteCumplimiento  → hallazgos de T19 (consentimiento, segmento).
   Los conteos de ORIGEN se leen directo de CLINICABI_OLTP y de la tabla de
   control que llenó la extracción de MongoDB (stg.ControlCarga).
   ════════════════════════════════════════════════════════════════════ */
USE CLINICABI_DW_Grupo1;
GO

/* ═══════════════ 1) CONTEOS POR PASO ═══════════════
   Cuadra = FilasOrigen − Descartados(explicados) = FilasDestino */
DECLARE @Conteos TABLE (Orden INT, Paso NVARCHAR(80), FilasOrigen INT, Descartados INT, FilasDestino INT, Explicacion NVARCHAR(200));

INSERT INTO @Conteos
SELECT 1, N'OLTP Pacientes → DIM_Paciente',
       (SELECT COUNT(*) FROM CLINICABI_OLTP.dbo.Pacientes), 0,
       (SELECT COUNT(*) FROM dbo.DIM_Paciente WHERE PacienteKey <> -1),
       N'Todos los pacientes se cargan (sin descartes)'
UNION ALL
SELECT 2, N'OLTP Atenciones → atenciones en FACT_Atenciones',
       (SELECT COUNT(*) FROM CLINICABI_OLTP.dbo.Atenciones),
       (SELECT COUNT(*) FROM CLINICABI_OLTP.dbo.Atenciones a JOIN CLINICABI_OLTP.dbo.EstadosAtencion e ON e.EstadoID = a.EstadoID
        WHERE e.Nombre <> N'Realizada'),
       (SELECT COUNT(DISTINCT AtencionID) FROM dbo.FACT_Atenciones),
       N'T6: canceladas e inasistencias no se cargan (se reportan por modalidad en la sección 4)'
UNION ALL
SELECT 3, N'OLTP DetalleAtencion → filas FACT_Atenciones',
       (SELECT COUNT(*) FROM CLINICABI_OLTP.dbo.DetalleAtencion),
       (SELECT COUNT(*) FROM CLINICABI_OLTP.dbo.DetalleAtencion d JOIN CLINICABI_OLTP.dbo.Atenciones a ON a.AtencionID = d.AtencionID
        JOIN CLINICABI_OLTP.dbo.EstadosAtencion e ON e.EstadoID = a.EstadoID WHERE e.Nombre <> N'Realizada'),
       (SELECT COUNT(*) FROM dbo.FACT_Atenciones),
       N'T6: líneas de detalle de atenciones canceladas o con inasistencia'
UNION ALL
SELECT 4, N'MongoDB interacciones_campanas → stg',
       FilasOrigen, 0, (SELECT COUNT(*) FROM stg.mongo_interacciones_campanas), N'Extracción completa (Python)'
FROM stg.ControlCarga WHERE Fuente = N'MongoDB' AND Objeto = N'interacciones_campanas'
UNION ALL
SELECT 5, N'stg interacciones → FACT_InteraccionCampana',
       (SELECT COUNT(*) FROM stg.mongo_interacciones_campanas),
       (SELECT COUNT(*) - COUNT(DISTINCT HASHBYTES('SHA2_256', Doc)) FROM stg.mongo_interacciones_campanas),
       (SELECT COUNT(*) FROM dbo.FACT_InteraccionCampana),
       N'T16: duplicados exactos eliminados (se conserva una copia de cada uno)'
UNION ALL
SELECT 6, N'MongoDB perfiles_pacientes → stg',
       FilasOrigen, 0, (SELECT COUNT(*) FROM stg.mongo_perfiles_pacientes), N'Extracción completa (Python)'
FROM stg.ControlCarga WHERE Fuente = N'MongoDB' AND Objeto = N'perfiles_pacientes'
UNION ALL
SELECT 7, N'stg perfiles → DIM_Paciente (TienePerfil = 1)',
       (SELECT COUNT(*) FROM stg.mongo_perfiles_pacientes),
       (SELECT COUNT(*) FROM stg.mongo_perfiles_pacientes) - (SELECT COUNT(*) FROM stg.perfil_vigente),
       (SELECT COUNT(*) FROM dbo.DIM_Paciente WHERE TienePerfil = 1),
       N'T12: perfiles antiguos de pacientes con más de un perfil (se queda el más reciente)'
UNION ALL
SELECT 8, N'MongoDB campanas → stg → DIM_Campana',
       FilasOrigen, 0, (SELECT COUNT(*) FROM dbo.DIM_Campana WHERE CampanaKey <> -1), N'Todas las campañas se cargan'
FROM stg.ControlCarga WHERE Fuente = N'MongoDB' AND Objeto = N'campanas';

SELECT Paso, FilasOrigen, Descartados, FilasDestino,
       CASE WHEN FilasOrigen - Descartados = FilasDestino THEN 'OK' ELSE 'REVISAR' END AS Cuadra,
       Explicacion
FROM @Conteos ORDER BY Orden;
GO

/* ═══════════════ 2) CUADRE DE DINERO ═══════════════
   Neto OLTP se calcula con la misma fórmula de línea:
   Cantidad × ValorUnitario − descuento redondeado a 2 decimales. */
WITH NetoOLTP AS (
    SELECT SUM(CAST(d.Cantidad * d.ValorUnitario AS DECIMAL(14,2))
             - CAST(ROUND(d.Cantidad * d.ValorUnitario * d.PorcentajeDescuento / 100.0, 2) AS DECIMAL(14,2))) AS Neto
    FROM CLINICABI_OLTP.dbo.DetalleAtencion d
    JOIN CLINICABI_OLTP.dbo.Atenciones a ON a.AtencionID = d.AtencionID
    JOIN CLINICABI_OLTP.dbo.EstadosAtencion e ON e.EstadoID = a.EstadoID
    WHERE e.Nombre = N'Realizada'
), PagosOLTP AS (
    SELECT SUM(p.Valor) AS Pagos,
           SUM(CASE WHEN m.EsAseguradora = 0 THEN p.Valor ELSE 0 END) AS PagosPaciente,
           SUM(CASE WHEN m.EsAseguradora = 1 THEN p.Valor ELSE 0 END) AS PagosAseguradora
    FROM CLINICABI_OLTP.dbo.Pagos p
    JOIN CLINICABI_OLTP.dbo.MediosPago m ON m.MedioPagoID = p.MedioPagoID
    JOIN CLINICABI_OLTP.dbo.Atenciones a ON a.AtencionID = p.AtencionID
    JOIN CLINICABI_OLTP.dbo.EstadosAtencion e ON e.EstadoID = a.EstadoID
    WHERE e.Nombre = N'Realizada'
), DW AS (
    SELECT SUM(ValorNeto) AS Neto, SUM(ValorPaciente) AS Paciente, SUM(ValorAseguradora) AS Aseguradora
    FROM dbo.FACT_Atenciones
)
SELECT o.Neto AS NetoOLTP, d.Neto AS NetoDW, p.Pagos AS PagosOLTP,
       CASE WHEN o.Neto = d.Neto AND d.Neto = p.Pagos THEN 'OK' ELSE 'REVISAR' END AS Cuadre_OLTP_DW_Pagos,
       p.PagosPaciente, d.Paciente AS ValorPacienteDW,
       p.PagosAseguradora, d.Aseguradora AS ValorAseguradoraDW,
       CASE WHEN p.PagosPaciente = d.Paciente AND p.PagosAseguradora = d.Aseguradora
             AND d.Paciente + d.Aseguradora = d.Neto THEN 'OK' ELSE 'REVISAR' END AS Cuadre_Paciente_Aseguradora
FROM NetoOLTP o CROSS JOIN PagosOLTP p CROSS JOIN DW d;

-- Cuadre fino (todas deben dar 0)
SELECT (SELECT COUNT(*) FROM dbo.FACT_Atenciones WHERE ValorPaciente + ValorAseguradora <> ValorNeto) AS LineasPacMasAsegDistintoNeto,
       (SELECT COUNT(*) FROM (SELECT f.AtencionID FROM dbo.FACT_Atenciones f GROUP BY f.AtencionID
                              HAVING SUM(f.ValorNeto) <> (SELECT SUM(p.Valor) FROM stg.oltp_Pagos p WHERE p.AtencionID = f.AtencionID)) x
       ) AS AtencionesNetoDistintoPagos,
       (SELECT COUNT(*) FROM (SELECT f.AtencionID, SUM(f.ValorPaciente) AS Pac FROM dbo.FACT_Atenciones f GROUP BY f.AtencionID) x
        WHERE x.Pac <> (SELECT ISNULL(SUM(p.Valor), 0) FROM stg.oltp_Pagos p JOIN stg.oltp_MediosPago m ON m.MedioPagoID = p.MedioPagoID
                        WHERE p.AtencionID = x.AtencionID AND m.EsAseguradora = 0)) AS AtencionesProrrateoPacienteDescuadrado;
GO

/* ═══════════════ 3) USO DEL MIEMBRO -1 ═══════════════ */
SELECT Hecho, Dimension, FilasConMenos1, Explicacion FROM (
    SELECT 'FACT_Atenciones' AS Hecho, 'DIM_Tiempo' AS Dimension, SUM(CASE WHEN TiempoKey = -1 THEN 1 ELSE 0 END) AS FilasConMenos1,
           N'Toda atención tiene fecha dentro del calendario' AS Explicacion, 1 AS o FROM dbo.FACT_Atenciones
    UNION ALL SELECT 'FACT_Atenciones', 'DIM_Paciente', SUM(CASE WHEN PacienteKey = -1 THEN 1 ELSE 0 END), N'Todo paciente de una atención existe en el OLTP (FK)', 2 FROM dbo.FACT_Atenciones
    UNION ALL SELECT 'FACT_Atenciones', 'DIM_Servicio', SUM(CASE WHEN ServicioKey = -1 THEN 1 ELSE 0 END), N'Todo servicio existe en el catálogo (FK)', 3 FROM dbo.FACT_Atenciones
    UNION ALL SELECT 'FACT_Atenciones', 'DIM_Sede', SUM(CASE WHEN SedeKey = -1 THEN 1 ELSE 0 END), N'Toda atención tiene sede', 4 FROM dbo.FACT_Atenciones
    UNION ALL SELECT 'FACT_Atenciones', 'DIM_Profesional', SUM(CASE WHEN ProfesionalKey = -1 THEN 1 ELSE 0 END), N'T8: líneas de atenciones con orden externa (sin profesional tratante)', 5 FROM dbo.FACT_Atenciones
    UNION ALL SELECT 'FACT_Atenciones', 'DIM_Aseguradora', SUM(CASE WHEN AseguradoraKey = -1 THEN 1 ELSE 0 END), N'T9: toda atención tiene pagador histórico', 6 FROM dbo.FACT_Atenciones
    UNION ALL SELECT 'FACT_Atenciones', 'DIM_Diagnostico', SUM(CASE WHEN DiagnosticoKey = -1 THEN 1 ELSE 0 END), N'T8: líneas de atenciones con orden externa (sin diagnóstico)', 7 FROM dbo.FACT_Atenciones
    UNION ALL SELECT 'FACT_Atenciones', 'DIM_Modalidad', SUM(CASE WHEN ModalidadKey = -1 THEN 1 ELSE 0 END), N'Toda atención tiene modalidad', 8 FROM dbo.FACT_Atenciones
    UNION ALL SELECT 'FACT_Atenciones', 'DIM_Campana', SUM(CASE WHEN CampanaKey = -1 THEN 1 ELSE 0 END), N'T21: líneas de atenciones NO atribuidas a ninguna campaña', 9 FROM dbo.FACT_Atenciones
    UNION ALL SELECT 'FACT_InteraccionCampana', 'DIM_Tiempo', SUM(CASE WHEN TiempoKey = -1 THEN 1 ELSE 0 END), N'T18: todas las fechas de evento se pudieron convertir', 10 FROM dbo.FACT_InteraccionCampana
    UNION ALL SELECT 'FACT_InteraccionCampana', 'DIM_Paciente', SUM(CASE WHEN PacienteKey = -1 THEN 1 ELSE 0 END), N'T19: pacienteId que no existe en el OLTP (se conserva en PacienteIdOrigen)', 11 FROM dbo.FACT_InteraccionCampana
    UNION ALL SELECT 'FACT_InteraccionCampana', 'DIM_Campana', SUM(CASE WHEN CampanaKey = -1 THEN 1 ELSE 0 END), N'T16: todo campanaId limpio existe en campanas', 12 FROM dbo.FACT_InteraccionCampana
    UNION ALL SELECT 'FACT_InteraccionCampana', 'DIM_CanalContacto', SUM(CASE WHEN CanalKey = -1 THEN 1 ELSE 0 END), N'T16: todas las variantes de canal tienen equivalencia', 13 FROM dbo.FACT_InteraccionCampana
) x ORDER BY o;

-- Detalle de los -1 de T8: deben coincidir con las líneas con orden externa
SELECT SUM(CAST(OrdenExterna AS INT)) AS LineasOrdenExterna,
       SUM(CASE WHEN ProfesionalKey = -1 AND DiagnosticoKey = -1 THEN 1 ELSE 0 END) AS LineasProfYDiagMenos1,
       SUM(CASE WHEN (ProfesionalKey = -1 OR DiagnosticoKey = -1) AND OrdenExterna = 0 THEN 1 ELSE 0 END) AS Menos1SinOrdenExterna_debe_ser_0
FROM dbo.FACT_Atenciones;
GO

/* ═══════════════ 4) TASAS POR MODALIDAD (T6) y PAGADOR HISTÓRICO (T9) ═══════════════ */
SELECT m.Nombre AS Modalidad,
       COUNT(*) AS Atenciones,
       SUM(CASE WHEN e.Nombre = N'Realizada'    THEN 1 ELSE 0 END) AS Realizadas,
       SUM(CASE WHEN e.Nombre = N'Cancelada'    THEN 1 ELSE 0 END) AS Canceladas,
       SUM(CASE WHEN e.Nombre = N'Inasistencia' THEN 1 ELSE 0 END) AS Inasistencias,
       CAST(100.0 * SUM(CASE WHEN e.Nombre = N'Cancelada'    THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS TasaCancelacionPct,
       CAST(100.0 * SUM(CASE WHEN e.Nombre = N'Inasistencia' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS TasaInasistenciaPct
FROM CLINICABI_OLTP.dbo.Atenciones a
JOIN CLINICABI_OLTP.dbo.EstadosAtencion e     ON e.EstadoID    = a.EstadoID
JOIN CLINICABI_OLTP.dbo.ModalidadesAtencion m ON m.ModalidadID = a.ModalidadID
GROUP BY ROLLUP (m.Nombre)
ORDER BY GROUPING(m.Nombre), m.Nombre;

SELECT 'T9' AS Regla, COUNT(*) AS AtencionesPagadorDistintoAlActual,
       SUM(CASE WHEN e.Nombre = N'Realizada' THEN 1 ELSE 0 END) AS DeEllasRealizadas
FROM CLINICABI_OLTP.dbo.Atenciones a
JOIN CLINICABI_OLTP.dbo.Pacientes p        ON p.PacienteID = a.PacienteID
JOIN CLINICABI_OLTP.dbo.EstadosAtencion e  ON e.EstadoID   = a.EstadoID
WHERE a.AseguradoraID <> p.AseguradoraID;
GO

/* ═══════════════ 5) REPORTE DE CALIDAD DE DATOS ═══════════════
   Una fila por problema: cuántos registros afectó (contados en el origen /
   stg crudo) y qué regla del ETL lo trató. Se recalcula en cada ejecución. */
DROP TABLE IF EXISTS dbo.ReporteCalidad;
CREATE TABLE dbo.ReporteCalidad (
    ID                 VARCHAR(5)    NOT NULL PRIMARY KEY,
    Fuente             NVARCHAR(30)  NOT NULL,
    Problema           NVARCHAR(200) NOT NULL,
    RegistrosAfectados INT           NOT NULL,
    Regla              VARCHAR(10)   NOT NULL,
    Tratamiento        NVARCHAR(200) NOT NULL
);

INSERT INTO dbo.ReporteCalidad
-- ── OLTP ──
SELECT 'S01', N'OLTP · Pacientes', N'Nombres o apellidos con espacios sobrantes (inicio, fin o dobles)',
       (SELECT COUNT(*) FROM stg.oltp_Pacientes
        WHERE Nombres + N'|' <> dbo.fn_LimpiarTexto(Nombres) + N'|' OR Apellidos + N'|' <> dbo.fn_LimpiarTexto(Apellidos) + N'|'),
       'T1', N'TRIM + espacios dobles a uno + CONCAT_WS'
UNION ALL SELECT 'S02', N'OLTP · Pacientes', N'Sexo NULL',
       (SELECT COUNT(*) FROM stg.oltp_Pacientes WHERE Sexo IS NULL), 'T2', N'Se carga como "Sin dato"'
UNION ALL SELECT 'S03', N'OLTP · Pacientes', N'Email o teléfono vacío (no se usan en el modelo)',
       (SELECT COUNT(*) FROM stg.oltp_Pacientes WHERE NULLIF(TRIM(Email), '') IS NULL OR NULLIF(TRIM(Telefono), '') IS NULL),
       '-', N'No se cargan al DW (datos de contacto fuera del alcance analítico)'
UNION ALL SELECT 'S04', N'OLTP · Atenciones', N'Atenciones canceladas o con inasistencia',
       (SELECT COUNT(*) FROM stg.oltp_Atenciones a JOIN stg.oltp_EstadosAtencion e ON e.EstadoID = a.EstadoID WHERE e.Nombre <> N'Realizada'),
       'T6', N'No se cargan al FACT; se reportan por modalidad'
UNION ALL SELECT 'S05', N'OLTP · Atenciones', N'Atenciones realizadas con orden externa (sin profesional ni diagnóstico)',
       (SELECT COUNT(*) FROM stg.oltp_Atenciones a JOIN stg.oltp_EstadosAtencion e ON e.EstadoID = a.EstadoID
        WHERE e.Nombre = N'Realizada' AND a.OrdenExterna = 1),
       'T8', N'ProfesionalKey y DiagnosticoKey = -1'
UNION ALL SELECT 'S06', N'OLTP · Atenciones', N'Pagador de la atención distinto a la aseguradora actual del paciente',
       (SELECT COUNT(*) FROM stg.oltp_Atenciones a JOIN stg.oltp_Pacientes p ON p.PacienteID = a.PacienteID WHERE a.AseguradoraID <> p.AseguradoraID),
       'T9', N'AseguradoraKey sale de Atenciones.AseguradoraID'
-- ── MongoDB · perfiles_pacientes ──
UNION ALL SELECT 'M01', N'Mongo · perfiles', N'pacienteId guardado como texto',
       (SELECT COUNT(*) FROM stg.mongo_perfiles_pacientes CROSS APPLY OPENJSON(Doc) j WHERE j.[key] = 'pacienteId' AND j.type = 1),
       'T11', N'Convertido a entero'
UNION ALL SELECT 'M02', N'Mongo · perfiles', N'Perfiles sobrantes de pacientes con más de un perfil',
       (SELECT COUNT(*) FROM stg.mongo_perfiles_pacientes) - (SELECT COUNT(*) FROM stg.perfil_vigente),
       'T12', N'Se conserva el de fechaActualizacion más reciente'
UNION ALL SELECT 'M03', N'Mongo · perfiles', N'Perfiles con lineasInteres no oficiales (mayúsculas, tildes, sinónimos)',
       (SELECT COUNT(*) FROM stg.mongo_perfiles_pacientes pp WHERE EXISTS (
            SELECT 1 FROM OPENJSON(pp.Doc, '$.lineasInteres') l
            WHERE l.value + N'|' COLLATE Latin1_General_BIN NOT IN (SELECT Nombre + N'|' COLLATE Latin1_General_BIN FROM stg.oltp_LineasServicio))),   -- '|' para no ignorar espacios finales
       'T13', N'Tabla de equivalencias stg.EquivalenciaLinea'
UNION ALL SELECT 'M04', N'Mongo · perfiles', N'Sin programaRiesgo',
       (SELECT COUNT(*) FROM stg.mongo_perfiles_pacientes WHERE JSON_QUERY(Doc, '$.programaRiesgo') IS NULL),
       'T14', N'"Sin programa" y nivel "No aplica"'
UNION ALL SELECT 'M05', N'Mongo · perfiles', N'nivelRiesgo con mayúsculas inconsistentes',
       (SELECT COUNT(*) FROM stg.mongo_perfiles_pacientes
        WHERE JSON_VALUE(Doc, '$.programaRiesgo.nivelRiesgo') COLLATE Latin1_General_BIN NOT IN (N'Alto', N'Medio', N'Bajo')),
       'T14', N'Normalizado a Alto / Medio / Bajo'
UNION ALL SELECT 'M06', N'Mongo · perfiles', N'Adherencia como texto "85%" o fracción 0.85',
       (SELECT COUNT(*) FROM stg.mongo_perfiles_pacientes
        WHERE JSON_VALUE(Doc, '$.programaRiesgo.adherencia') LIKE N'%[%]'
           OR TRY_CAST(JSON_VALUE(Doc, '$.programaRiesgo.adherencia') AS DECIMAL(9,4)) < 1),
       'T14', N'Convertida a entero 0–100'
UNION ALL SELECT 'M07', N'Mongo · perfiles', N'Consentimientos como texto "SI" / "NO"',
       (SELECT COUNT(*) FROM stg.mongo_perfiles_pacientes pp
        WHERE EXISTS (SELECT 1 FROM OPENJSON(pp.Doc, '$.consentimientos') c WHERE c.type = 1)),
       'T14', N'SI → 1, NO → 0'
UNION ALL SELECT 'M08', N'Mongo · perfiles', N'Sin encuestasSatisfaccion',
       (SELECT COUNT(*) FROM stg.mongo_perfiles_pacientes WHERE JSON_QUERY(Doc, '$.encuestasSatisfaccion') IS NULL),
       'T15', N'NPS NULL y TipoNPS "Sin encuesta"'
UNION ALL SELECT 'M09', N'Mongo · perfiles', N'Puntajes de encuesta como texto',
       (SELECT COUNT(*) FROM stg.mongo_perfiles_pacientes pp CROSS APPLY OPENJSON(pp.Doc, '$.encuestasSatisfaccion') e
        CROSS APPLY OPENJSON(e.value) x WHERE x.[key] = 'puntaje' AND x.type = 1),
       'T15', N'Convertidos a entero antes del promedio'
-- ── MongoDB · interacciones_campanas ──
UNION ALL SELECT 'M10', N'Mongo · interacciones', N'Documentos duplicados exactos (copias sobrantes)',
       (SELECT COUNT(*) - COUNT(DISTINCT HASHBYTES('SHA2_256', Doc)) FROM stg.mongo_interacciones_campanas),
       'T16', N'Eliminados; se conserva una copia'
UNION ALL SELECT 'M11', N'Mongo · interacciones', N'canal fuera de email / sms / whatsapp / app',
       (SELECT COUNT(*) FROM stg.mongo_interacciones_campanas
        WHERE JSON_VALUE(Doc, '$.canal') COLLATE Latin1_General_BIN NOT IN ('email', 'sms', 'whatsapp', 'app')
           OR DATALENGTH(JSON_VALUE(Doc, '$.canal')) <> DATALENGTH(TRIM(JSON_VALUE(Doc, '$.canal')))),
       'T16', N'Estandarizado (E-mail, correo, WA, push…)'
UNION ALL SELECT 'M12', N'Mongo · interacciones', N'campanaId con espacios o minúsculas',
       (SELECT COUNT(*) FROM stg.mongo_interacciones_campanas
        WHERE JSON_VALUE(Doc, '$.campanaId') COLLATE Latin1_General_BIN NOT LIKE 'CMP-[0-9][0-9][0-9][0-9]-[0-9][0-9]'),
       'T16', N'TRIM + MAYÚSCULAS'
UNION ALL SELECT 'M13', N'Mongo · interacciones', N'Documentos con fechas de evento en texto dd/mm/aaaa hh:mm',
       (SELECT COUNT(*) FROM stg.mongo_interacciones_campanas ic
        WHERE EXISTS (SELECT 1 FROM OPENJSON(ic.Doc, '$.eventos') e CROSS APPLY OPENJSON(e.value) x WHERE x.[key] = 'fecha' AND x.type = 1)),
       'T18', N'Convertidas (UTC) y pasadas a hora Colombia'
UNION ALL SELECT 'M14', N'Mongo · interacciones', N'pacienteId que no existe en el OLTP',
       (SELECT COUNT(*) FROM stg.mongo_interacciones_campanas
        WHERE CAST(JSON_VALUE(Doc, '$.pacienteId') AS INT) NOT IN (SELECT PacienteID FROM stg.oltp_Pacientes)),
       'T19', N'PacienteKey = -1 (se reporta en cumplimiento)'
UNION ALL SELECT 'M15', N'Mongo · interacciones', N'citaAgendada ausente (solo existe cuando hubo clic)',
       (SELECT COUNT(*) FROM stg.mongo_interacciones_campanas WHERE JSON_VALUE(Doc, '$.citaAgendada') IS NULL),
       'T17', N'CitaAgendada = 0'
UNION ALL SELECT 'M16', N'Mongo · interacciones', N'Canal app sin evento "enviado" (solo impresión)',
       (SELECT COUNT(*) FROM stg.mongo_interacciones_campanas
        WHERE LOWER(TRIM(JSON_VALUE(Doc, '$.canal'))) IN ('app', 'push') AND Doc NOT LIKE N'%"enviado"%'),
       'T17', N'Enviado = 0; el embudo de app empieza en Impresion'
UNION ALL SELECT 'M17', N'Mongo · interacciones', N'Apertura registrada como "abierto" o como "leido"',
       (SELECT COUNT(*) FROM stg.mongo_interacciones_campanas WHERE Doc LIKE N'%"abierto"%' OR Doc LIKE N'%"leido"%'),
       'T17', N'Abierto = abierto o leído'
-- ── MongoDB · campanas ──
UNION ALL SELECT 'M18', N'Mongo · campanas', N'presupuesto como texto ("9.200.000", "$22.500.000")',
       (SELECT COUNT(*) FROM stg.mongo_campanas c CROSS APPLY OPENJSON(c.Doc) j WHERE j.[key] = 'presupuesto' AND j.type = 1),
       'T20', N'Convertido a número'
UNION ALL SELECT 'M19', N'Mongo · campanas', N'responsable faltante o vacío',
       (SELECT COUNT(*) FROM stg.mongo_campanas WHERE NULLIF(TRIM(JSON_VALUE(Doc, '$.responsable')), N'') IS NULL),
       'T20', N'"Sin asignar"'
UNION ALL SELECT 'M20', N'Mongo · campanas', N'lineasPromocionadas no estandarizadas',
       (SELECT COUNT(*) FROM stg.mongo_campanas c WHERE EXISTS (
            SELECT 1 FROM OPENJSON(c.Doc, '$.lineasPromocionadas') l
            WHERE l.value + N'|' COLLATE Latin1_General_BIN NOT IN (SELECT Nombre + N'|' COLLATE Latin1_General_BIN FROM stg.oltp_LineasServicio))),   -- '|' para no ignorar espacios finales
       'T20+T13', N'Tabla de equivalencias'
UNION ALL SELECT 'M21', N'Mongo · campanas', N'Sin segmentoObjetivo (campaña abierta a todos)',
       (SELECT COUNT(*) FROM stg.mongo_campanas WHERE JSON_QUERY(Doc, '$.segmentoObjetivo') IS NULL),
       'T20', N'SexoObjetivo "Todos", EdadMin/EdadMax NULL'
UNION ALL SELECT 'M22', N'Mongo · campanas', N'segmentoObjetivo sin sexo (solo edad)',
       (SELECT COUNT(*) FROM stg.mongo_campanas
        WHERE JSON_QUERY(Doc, '$.segmentoObjetivo') IS NOT NULL AND JSON_VALUE(Doc, '$.segmentoObjetivo.sexo') IS NULL),
       'T20', N'SexoObjetivo "Todos"'
UNION ALL SELECT 'M23', N'Mongo · campanas', N'Sin codigoBeneficio',
       (SELECT COUNT(*) FROM stg.mongo_campanas WHERE JSON_VALUE(Doc, '$.codigoBeneficio') IS NULL),
       'T20', N'"Sin código"';

SELECT * FROM dbo.ReporteCalidad ORDER BY ID;
GO

/* ═══════════════ 6) REPORTE DE CUMPLIMIENTO (T19) ═══════════════
   Hallazgos por campaña y canal, sobre las interacciones ya depuradas (FACT). */
DROP TABLE IF EXISTS dbo.ReporteCumplimiento;

SELECT x.Hallazgo, x.Motivo, c.CampanaID, c.NombreCampana, ca.NombreCanal AS Canal, COUNT(*) AS Registros
INTO dbo.ReporteCumplimiento
FROM dbo.FACT_InteraccionCampana f
JOIN dbo.DIM_Campana       c  ON c.CampanaKey  = f.CampanaKey
JOIN dbo.DIM_CanalContacto ca ON ca.CanalKey   = f.CanalKey
JOIN dbo.DIM_Paciente      p  ON p.PacienteKey = f.PacienteKey
LEFT JOIN stg.perfil_vigente pv ON pv.PacienteID = f.PacienteIdOrigen
CROSS APPLY (
    SELECT N'Envío sin consentimiento (Ley 1581 de 2012)' AS Hallazgo,
           CASE WHEN pv.PacienteID IS NULL THEN N'Paciente sin perfil (sin autorización registrada)'
                ELSE N'Canal no autorizado en el perfil vigente' END AS Motivo
    WHERE f.EnviadoSinConsentimiento = 1
    UNION ALL
    SELECT N'Envío fuera del segmento objetivo',
           CASE WHEN c.SexoObjetivo IN (N'F', N'M') AND p.Sexo = N'Sin dato' THEN N'Sexo sin dato (no verificable)'
                WHEN c.SexoObjetivo IN (N'F', N'M') AND LEFT(p.Sexo, 1) <> c.SexoObjetivo THEN N'Sexo distinto al objetivo'
                ELSE N'Edad al inicio de la campaña fuera del rango' END
    WHERE f.FueraDeSegmento = 1
    UNION ALL
    SELECT N'Paciente inexistente en el OLTP', N'pacienteId sin registro en Pacientes (PacienteKey -1)'
    WHERE f.PacienteKey = -1
) x
GROUP BY x.Hallazgo, x.Motivo, c.CampanaID, c.NombreCampana, ca.NombreCanal;

-- Resumen (sobre el total de interacciones del FACT)
SELECT Hallazgo, Motivo, SUM(Registros) AS Registros,
       CAST(100.0 * SUM(Registros) / (SELECT COUNT(*) FROM dbo.FACT_InteraccionCampana) AS DECIMAL(5,2)) AS PctInteracciones
FROM dbo.ReporteCumplimiento
GROUP BY ROLLUP (Hallazgo, Motivo)
HAVING GROUPING(Hallazgo) = 0
ORDER BY Hallazgo, GROUPING(Motivo), Motivo;

SELECT COUNT(DISTINCT PacienteIdOrigen) AS PacienteIdsInexistentes
FROM dbo.FACT_InteraccionCampana WHERE PacienteKey = -1;

-- Detalle por campaña y canal (también queda en la tabla para Power BI / documento)
SELECT * FROM dbo.ReporteCumplimiento ORDER BY Hallazgo, CampanaID, Canal;
GO
