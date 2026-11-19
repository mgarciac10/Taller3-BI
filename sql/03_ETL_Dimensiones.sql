/* ════════════════════════════════════════════════════════════════════
   SCRIPT 03 · ETL de dimensiones desde el OLTP (stg.oltp_*)
   Transformaciones: T1, T2, T3, T4 (Paciente, Sede), T5 (Servicio), T10 (Tiempo)
   + Profesional, Aseguradora, Diagnóstico, Modalidad, Canal de contacto.
   Requisitos: 01, 02 y mongo/extraer_mongo.py ya ejecutados.
   DIM_Paciente se carga aquí con los datos del OLTP; los atributos de
   MongoDB se completan en el script 04 (T11–T15).
   ════════════════════════════════════════════════════════════════════ */
USE CLINICABI_DW_Grupo1;
GO

/* ── T1 · Función de limpieza de texto ─────────────────────────────
   TRIM quita espacios al inicio/fin. Para reducir espacios dobles internos
   a uno: cada ' ' se vuelve CHAR(30)+CHAR(31); luego se borra toda pareja
   CHAR(31)+CHAR(30) (que solo aparece entre dos espacios seguidos) y lo que
   queda (CHAR(30)+CHAR(31)) vuelve a ser un solo espacio.
   'Ospina␣␣Díaz␣' → 'Ospina Díaz'                                       */
CREATE OR ALTER FUNCTION dbo.fn_LimpiarTexto (@t NVARCHAR(400))
RETURNS NVARCHAR(400)
AS
BEGIN
    RETURN REPLACE(REPLACE(REPLACE(TRIM(@t), N' ', NCHAR(30) + NCHAR(31)),
                           NCHAR(31) + NCHAR(30), N''),
                   NCHAR(30) + NCHAR(31), N' ');
END;
GO

/* ════════════ T10 · DIM_Tiempo ════════════
   Años completos (1-ene a 31-dic) desde el primer hasta el último año con
   datos (atenciones y campañas), sin huecos. DiaSemana se calcula con
   DATEDIFF desde el 1900-01-01 (que fue lunes) y los nombres salen de
   CHOOSE: así NO depende de SET DATEFIRST ni del idioma del servidor. */
DECLARE @AnioIni INT, @AnioFin INT;
SELECT @AnioIni = MIN(a), @AnioFin = MAX(a)
FROM (
    SELECT YEAR(FechaAtencion) AS a FROM stg.oltp_Atenciones
    UNION ALL SELECT CAST(LEFT(JSON_VALUE(Doc, '$.fechaInicio."$date"'), 4) AS INT) FROM stg.mongo_campanas
    UNION ALL SELECT CAST(LEFT(JSON_VALUE(Doc, '$.fechaFin."$date"'), 4) AS INT)    FROM stg.mongo_campanas
) x;

DECLARE @Ini DATE = DATEFROMPARTS(@AnioIni, 1, 1),
        @Fin DATE = DATEFROMPARTS(@AnioFin, 12, 31);

WITH n AS (
    SELECT TOP (DATEDIFF(DAY, @Ini, @Fin) + 1)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
), f AS (
    SELECT DATEADD(DAY, i, @Ini) AS Fecha FROM n
), c AS (
    SELECT Fecha, MONTH(Fecha) AS Mes,
           (DATEDIFF(DAY, '19000101', Fecha) % 7) + 1 AS DiaSemana      -- 1 = lunes … 7 = domingo
    FROM f
)
INSERT INTO dbo.DIM_Tiempo (TiempoKey, Fecha, Anio, Semestre, Trimestre, NombreTrimestre, Mes, NombreMes,
                            MesCorto, AnioMes, Dia, DiaSemana, NombreDia, EsFinDeSemana)
SELECT CONVERT(INT, CONVERT(CHAR(8), Fecha, 112)),
       Fecha,
       YEAR(Fecha),
       CASE WHEN Mes <= 6 THEN 1 ELSE 2 END,
       (Mes - 1) / 3 + 1,
       CONCAT(N'T', (Mes - 1) / 3 + 1),
       Mes,
       CHOOSE(Mes, N'Enero', N'Febrero', N'Marzo', N'Abril', N'Mayo', N'Junio', N'Julio',
                   N'Agosto', N'Septiembre', N'Octubre', N'Noviembre', N'Diciembre'),
       CHOOSE(Mes, N'Ene', N'Feb', N'Mar', N'Abr', N'May', N'Jun', N'Jul', N'Ago', N'Sep', N'Oct', N'Nov', N'Dic'),
       CONVERT(CHAR(7), Fecha, 120),
       DAY(Fecha),
       DiaSemana,
       CHOOSE(DiaSemana, N'Lunes', N'Martes', N'Miércoles', N'Jueves', N'Viernes', N'Sábado', N'Domingo'),
       CASE WHEN DiaSemana IN (6, 7) THEN 1 ELSE 0 END
FROM c;
GO

/* ════════════ DIM_Paciente (parte OLTP) · T1, T2, T3, T4 ════════════ */
INSERT INTO dbo.DIM_Paciente (PacienteID, TipoDocumento, NombreTipoDocumento, NumeroDocumento, NombreCompleto,
       Sexo, FechaNacimiento, Edad, CursoVida, Ciudad, Departamento, Region, Pais,
       TienePerfil, OrigenRegistro, CanalPreferido, AceptaEmail, AceptaSMS, AceptaWhatsApp,
       LineasInteres, ProgramaRiesgo, NivelRiesgo, Adherencia, NPSPromedio, TipoNPS)
SELECT p.PacienteID,
       p.TipoDocumento,
       -- T2 · decodificación del tipo de documento
       CASE p.TipoDocumento WHEN 'CC' THEN N'Cédula de ciudadanía'
                            WHEN 'TI' THEN N'Tarjeta de identidad'
                            WHEN 'RC' THEN N'Registro civil'
                            WHEN 'CE' THEN N'Cédula de extranjería'
                            WHEN 'PA' THEN N'Pasaporte'
                            ELSE N'Desconocido' END,
       TRIM(p.NumeroDocumento),
       -- T1 · limpieza + nombre completo con CONCAT_WS
       CONCAT_WS(N' ', dbo.fn_LimpiarTexto(p.Nombres), dbo.fn_LimpiarTexto(p.Apellidos)),
       -- T2 · decodificación del sexo
       CASE p.Sexo WHEN 'F' THEN N'Femenino' WHEN 'M' THEN N'Masculino' ELSE N'Sin dato' END,
       p.FechaNacimiento,
       e.Edad,
       -- T3 · curso de vida (Resolución 3280 de 2018)
       CASE WHEN e.Edad <= 5  THEN N'Primera infancia'
            WHEN e.Edad <= 11 THEN N'Infancia'
            WHEN e.Edad <= 17 THEN N'Adolescencia'
            WHEN e.Edad <= 28 THEN N'Juventud'
            WHEN e.Edad <= 59 THEN N'Adultez'
            ELSE N'Vejez' END,
       -- T4 · geografía desnormalizada Ciudad → Departamento → Región → País
       ci.Nombre, de.Nombre, re.Nombre, pa.Nombre,
       -- Atributos MongoDB: valores por defecto; el script 04 los actualiza
       0, N'Sin perfil', N'Sin perfil', 0, 0, 0, N'', N'Sin programa', N'No aplica', NULL, NULL, N'Sin encuesta'
FROM stg.oltp_Pacientes p
/* T3 · edad cumplida al 31-12-2025: años de diferencia, menos 1 si aún no
   había cumplido años en esa fecha */
CROSS APPLY (SELECT DATEDIFF(YEAR, p.FechaNacimiento, '20251231')
                    - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.FechaNacimiento, '20251231'), p.FechaNacimiento) > '20251231'
                           THEN 1 ELSE 0 END AS Edad) e
JOIN stg.oltp_Ciudades      ci ON ci.CiudadID       = p.CiudadID
JOIN stg.oltp_Departamentos de ON de.DepartamentoID = ci.DepartamentoID
JOIN stg.oltp_Regiones      re ON re.RegionID       = de.RegionID
JOIN stg.oltp_Paises        pa ON pa.PaisID         = re.PaisID;
GO

/* ════════════ DIM_Servicio · T5 ════════════
   Desnormaliza Tipo de servicio → Línea y la Especialidad.
   RangoTarifa según la tarifa plena del servicio. */
INSERT INTO dbo.DIM_Servicio (ServicioID, CodigoServicio, NombreServicio, TipoServicio, LineaServicio,
                              Especialidad, EsQuirurgica, Tarifa, CostoUnitario, RangoTarifa)
SELECT s.ServicioID, s.CodigoServicio, dbo.fn_LimpiarTexto(s.Nombre), ts.Nombre, l.Nombre,
       es.Nombre, es.EsQuirurgica, s.Tarifa, s.CostoUnitario,
       CASE WHEN s.Tarifa < 100000  THEN N'Menos de $100.000'
            WHEN s.Tarifa < 1000000 THEN N'$100.000 a $999.999'
            ELSE N'$1.000.000 o más' END
FROM stg.oltp_Servicios s
JOIN stg.oltp_TiposServicio   ts ON ts.TipoServicioID = s.TipoServicioID
JOIN stg.oltp_LineasServicio  l  ON l.LineaID         = ts.LineaID
JOIN stg.oltp_Especialidades  es ON es.EspecialidadID = s.EspecialidadID;
GO

/* ════════════ DIM_Sede · T4 (geografía) + tipo física/virtual ════════════ */
INSERT INTO dbo.DIM_Sede (SedeID, NombreSede, TipoSede, Ciudad, Departamento, Region, Pais, NumeroConsultorios, FechaApertura)
SELECT s.SedeID, dbo.fn_LimpiarTexto(s.Nombre), s.TipoSede, ci.Nombre, de.Nombre, re.Nombre, pa.Nombre,
       s.NumeroConsultorios, s.FechaApertura
FROM stg.oltp_Sedes s
JOIN stg.oltp_Ciudades      ci ON ci.CiudadID       = s.CiudadID
JOIN stg.oltp_Departamentos de ON de.DepartamentoID = ci.DepartamentoID
JOIN stg.oltp_Regiones      re ON re.RegionID       = de.RegionID
JOIN stg.oltp_Paises        pa ON pa.PaisID         = re.PaisID;
GO

/* ════════════ DIM_Profesional · cargo, especialidad y sede ════════════ */
INSERT INTO dbo.DIM_Profesional (ProfesionalID, RegistroMedico, NombreCompleto, Cargo, Especialidad, Sede)
SELECT pr.ProfesionalID, pr.RegistroMedico,
       CONCAT_WS(N' ', dbo.fn_LimpiarTexto(pr.Nombres), dbo.fn_LimpiarTexto(pr.Apellidos)),
       c.Nombre, es.Nombre, dbo.fn_LimpiarTexto(s.Nombre)
FROM stg.oltp_Profesionales pr
JOIN stg.oltp_Cargos         c  ON c.CargoID         = pr.CargoID
JOIN stg.oltp_Especialidades es ON es.EspecialidadID = pr.EspecialidadID
JOIN stg.oltp_Sedes          s  ON s.SedeID          = pr.SedeID;
GO

/* ════════════ DIM_Aseguradora · con su tipo de afiliación ════════════ */
INSERT INTO dbo.DIM_Aseguradora (AseguradoraID, NombreAseguradora, NIT, TipoAfiliacion, PorcentajeCopago, FactorTarifa, DiasPagoPactados)
SELECT a.AseguradoraID, a.Nombre, a.NIT, t.Nombre, t.PorcentajeCopago, t.FactorTarifa, a.DiasPagoPactados
FROM stg.oltp_Aseguradoras a
JOIN stg.oltp_TiposAfiliacion t ON t.TipoAfiliacionID = a.TipoAfiliacionID;
GO

/* ════════════ DIM_Diagnostico · DIM_Modalidad ════════════ */
INSERT INTO dbo.DIM_Diagnostico (DiagnosticoID, CodigoCIE10, Descripcion, Capitulo)
SELECT DiagnosticoID, CodigoCIE10, Descripcion, Capitulo FROM stg.oltp_Diagnosticos;

INSERT INTO dbo.DIM_Modalidad (ModalidadID, Modalidad)
SELECT ModalidadID, Nombre FROM stg.oltp_ModalidadesAtencion;
GO

/* ════════════ DIM_CanalContacto · catálogo estandarizado (T16) ════════════
   Los 4 canales oficiales. App no requiere autorización de habeas data (T19). */
INSERT INTO dbo.DIM_CanalContacto (CodigoCanal, NombreCanal, RequiereConsentimiento)
VALUES ('email', N'Email', 1), ('sms', N'SMS', 1), ('whatsapp', N'WhatsApp', 1), ('app', N'App', 0);
GO

SELECT 'DIM_Tiempo' AS Dimension, COUNT(*) AS Filas FROM dbo.DIM_Tiempo
UNION ALL SELECT 'DIM_Paciente',      COUNT(*) FROM dbo.DIM_Paciente
UNION ALL SELECT 'DIM_Servicio',      COUNT(*) FROM dbo.DIM_Servicio
UNION ALL SELECT 'DIM_Sede',          COUNT(*) FROM dbo.DIM_Sede
UNION ALL SELECT 'DIM_Profesional',   COUNT(*) FROM dbo.DIM_Profesional
UNION ALL SELECT 'DIM_Aseguradora',   COUNT(*) FROM dbo.DIM_Aseguradora
UNION ALL SELECT 'DIM_Diagnostico',   COUNT(*) FROM dbo.DIM_Diagnostico
UNION ALL SELECT 'DIM_Modalidad',     COUNT(*) FROM dbo.DIM_Modalidad
UNION ALL SELECT 'DIM_CanalContacto', COUNT(*) FROM dbo.DIM_CanalContacto;
GO
