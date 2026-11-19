/* ════════════════════════════════════════════════════════════════════
   TALLER BI CLÍNICA · SCRIPT 02
   Poblar la base OPERACIONAL (OLTP) – CLINICABI_OLTP
   Requisito: haber ejecutado 01_Crear_OLTP.sql (tablas vacías)

   Genera datos realistas de 2 años (2024-01-01 a 2025-12-31):
     · 6.000 pacientes en 24 ciudades de Colombia, con 9 aseguradoras
       (EPS contributivo y subsidiado, prepagada, póliza y particular)
     · ~100 servicios en 6 líneas y 22 tipos de servicio (tarifas en COP)
     · 15 sedes (14 físicas + 1 virtual de telemedicina) y ~350 profesionales
     · ~57.000 atenciones, ~90.000 líneas de detalle y sus pagos
       (copago del paciente + cuenta por cobrar a la aseguradora)
   Con estacionalidad (picos respiratorios en abril-mayo y octubre-noviembre,
   baja en diciembre-enero y en fines de semana), crecimiento 2025 vs 2024,
   auge de la telemedicina en 2025 y algunos datos "sucios"
   (espacios de más, correos/teléfonos vacíos, sexo sin dato) para el ETL.

   Tiempo aproximado de ejecución: 20 a 60 segundos.
   Todos los datos son ficticios.
   ════════════════════════════════════════════════════════════════════ */

USE CLINICABI_OLTP;
GO

SET NOCOUNT ON;

/* ── Control: el script debe correr sobre tablas vacías ── */
IF EXISTS (SELECT 1 FROM Pacientes) OR EXISTS (SELECT 1 FROM Atenciones)
BEGIN
    RAISERROR(N'Las tablas ya tienen datos. Ejecute de nuevo 01_Crear_OLTP.sql antes de este script.', 16, 1);
    RETURN;   -- detiene la ejecución del script
END

/* ════════════════════════════════════════════
   PARÁMETROS (puede cambiarlos)
   ════════════════════════════════════════════ */
DECLARE @nPacientes   INT  = 6000;     -- NO cambiar: MongoDB usa pacienteId 1..6000
DECLARE @nCandidatos  INT  = 100000;   -- candidatos a atención (se conservan ~57%)
DECLARE @FechaInicio  DATE = '2024-01-01';
DECLARE @DiasPeriodo  INT  = 731;      -- 2024 (bisiesto, 366) + 2025 (365)

/* Tabla auxiliar de números 1..200.000 */
IF OBJECT_ID('tempdb..#N') IS NOT NULL DROP TABLE #N;
SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
INTO #N
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
CREATE UNIQUE CLUSTERED INDEX IX_N ON #N(n);

/* ════════════════════════════════════════════
   1. GEOGRAFÍA
   ════════════════════════════════════════════ */
INSERT INTO Paises (Nombre, CodigoISO) VALUES (N'Colombia', 'CO');

INSERT INTO Regiones (Nombre, PaisID)
SELECT r.Nombre, p.PaisID
FROM (VALUES (N'Andina'), (N'Caribe'), (N'Pacífica'), (N'Orinoquía')) AS r(Nombre)
CROSS JOIN Paises p WHERE p.CodigoISO = 'CO';

INSERT INTO Departamentos (Nombre, RegionID)
SELECT d.Nombre, r.RegionID
FROM (VALUES
    (N'Bogotá D.C.', N'Andina'), (N'Antioquia', N'Andina'), (N'Valle del Cauca', N'Pacífica'),
    (N'Atlántico', N'Caribe'),   (N'Bolívar', N'Caribe'),   (N'Santander', N'Andina'),
    (N'Risaralda', N'Andina'),   (N'Caldas', N'Andina'),    (N'Quindío', N'Andina'),
    (N'Nariño', N'Pacífica'),    (N'Cauca', N'Pacífica'),   (N'Meta', N'Orinoquía'),
    (N'Boyacá', N'Andina'),      (N'Tolima', N'Andina'),    (N'Huila', N'Andina'),
    (N'Magdalena', N'Caribe'),   (N'Córdoba', N'Caribe'),   (N'Norte de Santander', N'Andina'),
    (N'Cundinamarca', N'Andina'),(N'Casanare', N'Orinoquía')
) AS d(Nombre, Region)
JOIN Regiones r ON r.Nombre = d.Region;

/* Ciudades con un "peso" = % aproximado de pacientes que viven allí */
IF OBJECT_ID('tempdb..#CiudadCarga') IS NOT NULL DROP TABLE #CiudadCarga;
CREATE TABLE #CiudadCarga (Ciudad NVARCHAR(60), Departamento NVARCHAR(60), Peso INT);
INSERT INTO #CiudadCarga VALUES
    (N'Medellín', N'Antioquia', 20), (N'Bogotá', N'Bogotá D.C.', 18), (N'Cali', N'Valle del Cauca', 10),
    (N'Barranquilla', N'Atlántico', 6), (N'Cartagena', N'Bolívar', 4), (N'Bucaramanga', N'Santander', 4),
    (N'Pereira', N'Risaralda', 3), (N'Manizales', N'Caldas', 3), (N'Armenia', N'Quindío', 2),
    (N'Pasto', N'Nariño', 2), (N'Popayán', N'Cauca', 1), (N'Villavicencio', N'Meta', 2),
    (N'Tunja', N'Boyacá', 1), (N'Ibagué', N'Tolima', 2), (N'Neiva', N'Huila', 1),
    (N'Santa Marta', N'Magdalena', 2), (N'Montería', N'Córdoba', 2), (N'Cúcuta', N'Norte de Santander', 2),
    (N'Envigado', N'Antioquia', 5), (N'Bello', N'Antioquia', 5), (N'Palmira', N'Valle del Cauca', 1),
    (N'Soacha', N'Cundinamarca', 2), (N'Chía', N'Cundinamarca', 1), (N'Yopal', N'Casanare', 1);

INSERT INTO Ciudades (Nombre, DepartamentoID)
SELECT c.Ciudad, d.DepartamentoID
FROM #CiudadCarga c
JOIN Departamentos d ON d.Nombre = c.Departamento;

/* Rangos acumulados para asignar ciudades de forma ponderada */
IF OBJECT_ID('tempdb..#RangoCiudad') IS NOT NULL DROP TABLE #RangoCiudad;
SELECT ci.CiudadID,
       SUM(c.Peso) OVER (ORDER BY ci.CiudadID ROWS UNBOUNDED PRECEDING) - c.Peso + 1 AS Desde,
       SUM(c.Peso) OVER (ORDER BY ci.CiudadID ROWS UNBOUNDED PRECEDING)          AS Hasta
INTO #RangoCiudad
FROM #CiudadCarga c
JOIN Ciudades ci ON ci.Nombre = c.Ciudad;

DECLARE @PesoTotal INT = (SELECT SUM(Peso) FROM #CiudadCarga);

/* ════════════════════════════════════════════
   2. ASEGURAMIENTO
   ════════════════════════════════════════════ */
INSERT INTO TiposAfiliacion (Nombre, PorcentajeCopago, FactorTarifa, Descripcion) VALUES
    (N'Contributivo',       15, 0.80, N'Afiliado a EPS del régimen contributivo (paga cuota moderadora / copago)'),
    (N'Subsidiado',          5, 0.70, N'Afiliado a EPS del régimen subsidiado (copago bajo o exonerado)'),
    (N'Medicina prepagada', 10, 1.00, N'Plan voluntario de salud (paga bono por servicio)'),
    (N'Póliza de salud',    20, 0.95, N'Seguro de salud de una aseguradora (paga deducible)'),
    (N'Particular',        100, 1.00, N'Paga el 100% de la tarifa plena');

INSERT INTO Aseguradoras (Nombre, NIT, TipoAfiliacionID, DiasPagoPactados)
SELECT a.Nombre, a.NIT, t.TipoAfiliacionID, a.Dias
FROM (VALUES
    (N'Salud Andina EPS',               '830100101-1', N'Contributivo',        60),
    (N'Nueva Vida EPS',                 '830100202-2', N'Contributivo',        75),
    (N'Bienestar Total EPS',            '830100303-3', N'Contributivo',        90),
    (N'Comunidad Sana EPS-S',           '830100404-4', N'Subsidiado',         120),
    (N'Mutual del Pueblo EPS-S',        '830100505-5', N'Subsidiado',         120),
    (N'Vital Plus Medicina Prepagada',  '830100606-6', N'Medicina prepagada',  30),
    (N'Protege Medicina Prepagada',     '830100707-7', N'Medicina prepagada',  30),
    (N'Seguros Horizonte',              '830100808-8', N'Póliza de salud',     45),
    (N'Particular',                     '000000000-0', N'Particular',           0)
) AS a(Nombre, NIT, Tipo, Dias)
JOIN TiposAfiliacion t ON t.Nombre = a.Tipo;

/* Peso de cada aseguradora en la población de pacientes (%) */
IF OBJECT_ID('tempdb..#AsegCarga') IS NOT NULL DROP TABLE #AsegCarga;
CREATE TABLE #AsegCarga (Nombre NVARCHAR(100), Peso INT);
INSERT INTO #AsegCarga VALUES
    (N'Salud Andina EPS', 25), (N'Nueva Vida EPS', 20), (N'Bienestar Total EPS', 13),
    (N'Comunidad Sana EPS-S', 12), (N'Mutual del Pueblo EPS-S', 8),
    (N'Vital Plus Medicina Prepagada', 6), (N'Protege Medicina Prepagada', 4),
    (N'Seguros Horizonte', 4), (N'Particular', 8);

IF OBJECT_ID('tempdb..#RangoAseg') IS NOT NULL DROP TABLE #RangoAseg;
SELECT a.AseguradoraID,
       SUM(c.Peso) OVER (ORDER BY a.AseguradoraID ROWS UNBOUNDED PRECEDING) - c.Peso + 1 AS Desde,
       SUM(c.Peso) OVER (ORDER BY a.AseguradoraID ROWS UNBOUNDED PRECEDING)          AS Hasta
INTO #RangoAseg
FROM #AsegCarga c
JOIN Aseguradoras a ON a.Nombre = c.Nombre;

DECLARE @nAseg INT = (SELECT COUNT(*) FROM Aseguradoras);

/* ════════════════════════════════════════════
   3. PACIENTES
   ════════════════════════════════════════════ */
IF OBJECT_ID('tempdb..#Nombres') IS NOT NULL DROP TABLE #Nombres;
CREATE TABLE #Nombres (id INT IDENTITY(1,1), Nombre NVARCHAR(40), Genero CHAR(1));
INSERT INTO #Nombres (Nombre, Genero)
SELECT v.Nombre, 'F' FROM (VALUES
    (N'María'),(N'Ana'),(N'Laura'),(N'Valentina'),(N'Camila'),(N'Daniela'),(N'Sofía'),(N'Isabella'),
    (N'Paula'),(N'Natalia'),(N'Carolina'),(N'Andrea'),(N'Juliana'),(N'Mariana'),(N'Gabriela'),
    (N'Diana'),(N'Claudia'),(N'Sandra'),(N'Paola'),(N'Luisa'),(N'Alejandra'),(N'Catalina'),
    (N'Manuela'),(N'Sara'),(N'Lina'),(N'Viviana'),(N'Adriana'),(N'Mónica'),(N'Ángela'),(N'Lucía'),
    (N'Salomé'),(N'Antonella'),(N'Gloria'),(N'Martha'),(N'Rosa')) AS v(Nombre)
UNION ALL
SELECT v.Nombre, 'M' FROM (VALUES
    (N'Juan'),(N'Carlos'),(N'Andrés'),(N'Santiago'),(N'Sebastián'),(N'Felipe'),(N'Diego'),(N'Alejandro'),
    (N'Jorge'),(N'Luis'),(N'José'),(N'David'),(N'Daniel'),(N'Mateo'),(N'Samuel'),(N'Nicolás'),
    (N'Camilo'),(N'Julián'),(N'Ricardo'),(N'Fernando'),(N'Óscar'),(N'Mauricio'),(N'Javier'),
    (N'Miguel'),(N'Esteban'),(N'Tomás'),(N'Gustavo'),(N'Héctor'),(N'Iván'),(N'Pablo'),
    (N'Emiliano'),(N'Jerónimo'),(N'Álvaro'),(N'Hernán'),(N'Rubén')) AS v(Nombre);

IF OBJECT_ID('tempdb..#Apellidos') IS NOT NULL DROP TABLE #Apellidos;
CREATE TABLE #Apellidos (id INT IDENTITY(1,1), Apellido NVARCHAR(40));
INSERT INTO #Apellidos (Apellido) VALUES
    (N'Rodríguez'),(N'Gómez'),(N'González'),(N'Martínez'),(N'García'),(N'López'),(N'Hernández'),
    (N'Sánchez'),(N'Ramírez'),(N'Pérez'),(N'Díaz'),(N'Muñoz'),(N'Rojas'),(N'Moreno'),(N'Jiménez'),
    (N'Vargas'),(N'Castro'),(N'Gutiérrez'),(N'Ortiz'),(N'Álvarez'),(N'Ruiz'),(N'Suárez'),(N'Romero'),
    (N'Herrera'),(N'Valencia'),(N'Quintero'),(N'Restrepo'),(N'Cárdenas'),(N'Mejía'),(N'Arango'),
    (N'Ospina'),(N'Cardona'),(N'Zapata'),(N'Ríos'),(N'Torres'),(N'Parra'),(N'Salazar'),(N'Vásquez'),
    (N'Bermúdez'),(N'Montoya'),(N'Agudelo'),(N'Londoño'),(N'Correa'),(N'Uribe'),(N'Betancur');

DECLARE @nNom INT = (SELECT COUNT(*) FROM #Nombres);
DECLARE @nApe INT = (SELECT COUNT(*) FROM #Apellidos);

/* Nombres numerados por sexo */
IF OBJECT_ID('tempdb..#NomSexo') IS NOT NULL DROP TABLE #NomSexo;
SELECT Genero, Nombre, ROW_NUMBER() OVER (PARTITION BY Genero ORDER BY id) AS rn,
       COUNT(*) OVER (PARTITION BY Genero) AS Total
INTO #NomSexo FROM #Nombres;

/* Sorteos por paciente.
   La EDAD y el SEXO se calculan con un hash fijo del PacienteID (no con NEWID) para que
   coincidan en todas las corridas con los datos de MongoDB (programas, segmentos de campañas).
   El resto (nombre, ciudad, aseguradora, contacto) sí es aleatorio en cada corrida. */
IF OBJECT_ID('tempdb..#PacTmp') IS NOT NULL DROP TABLE #PacTmp;
SELECT n,
       ABS(CHECKSUM(NEWID()) % @PesoTotal) + 1 AS rCiudad,
       ABS(CHECKSUM(NEWID()) % 100) + 1        AS rAseg,
       ABS(CHECKSUM(NEWID()) % 1000)           AS rNombre,
       ABS(CHECKSUM(NEWID()) % @nApe) + 1      AS rApe1,
       ABS(CHECKSUM(NEWID()) % @nApe) + 1      AS rApe2,
       ABS(CHECKSUM(NEWID()) % 2922)           AS rRegistro,   -- 8 años en días
       ABS(CHECKSUM(NEWID()) % 100)            AS rCalidad,
       ABS(CHECKSUM(NEWID()) % 1000000000)     AS rTel,
       (CAST(n AS BIGINT) * 2654435761 % 4294967296) / 4096 % 1000 AS hGrupoEdad,
       (CAST(n AS BIGINT) * 2246822519 % 4294967296) / 4096 % 1000 AS hEdad,
       (CAST(n AS BIGINT) * 3266489917 % 4294967296) / 4096 % 365  AS hDiaNac,
       (CAST(n AS BIGINT) *  668265263 % 4294967296) / 4096 % 1000 AS hSexoNulo,
       (CAST(n AS BIGINT) *  374761393 % 4294967296) / 4096 % 100  AS hSexo
INTO #PacTmp
FROM #N
WHERE n <= @nPacientes;

/* Edad (en años cumplidos al 01-01-2024) según una pirámide simplificada */
IF OBJECT_ID('tempdb..#PacEdad') IS NOT NULL DROP TABLE #PacEdad;
SELECT t.*,
       CAST(CASE WHEN t.hGrupoEdad <  70 THEN 0  + t.hEdad % 6      -- primera infancia (7%)
                 WHEN t.hGrupoEdad < 130 THEN 6  + t.hEdad % 6      -- infancia (6%)
                 WHEN t.hGrupoEdad < 190 THEN 12 + t.hEdad % 6      -- adolescencia (6%)
                 WHEN t.hGrupoEdad < 360 THEN 18 + t.hEdad % 11     -- juventud (17%)
                 WHEN t.hGrupoEdad < 760 THEN 29 + t.hEdad % 31     -- adultez (40%)
                 ELSE                          60 + t.hEdad % 31 END AS INT) AS Edad,   -- vejez (24%)
       CASE WHEN t.hSexo < 52 THEN 'F' ELSE 'M' END AS Genero
INTO #PacEdad
FROM #PacTmp t;

SET IDENTITY_INSERT Pacientes ON;

INSERT INTO Pacientes (PacienteID, TipoDocumento, NumeroDocumento, Nombres, Apellidos, Sexo,
                       FechaNacimiento, Email, Telefono, Direccion, AseguradoraID, CiudadID, FechaRegistro)
SELECT
    t.n,
    CASE WHEN t.Edad < 7   THEN 'RC'
         WHEN t.Edad < 18  THEN 'TI'
         WHEN t.n % 41 = 0 THEN 'CE'
         WHEN t.n % 97 = 0 THEN 'PA'
         ELSE 'CC' END,
    CAST(1000000000 + t.n * 7919 AS VARCHAR(12)),
    /* 3% con espacios de más ("dato sucio") */
    CASE WHEN t.rCalidad < 3 THEN CONCAT(N'  ', nom.Nombre, N' ') ELSE nom.Nombre END,
    CASE WHEN t.rCalidad = 97 THEN CONCAT(a1.Apellido, N'  ', a2.Apellido, N' ')   -- doble espacio interno
         ELSE CONCAT(a1.Apellido, N' ', a2.Apellido) END,
    CASE WHEN t.hSexoNulo < 12 THEN NULL ELSE t.Genero END,                       -- 1,2% sin dato de sexo
    DATEADD(DAY, -(t.Edad * 365 + CAST(t.hDiaNac AS INT)), @FechaInicio),
    CASE WHEN t.rCalidad BETWEEN 3 AND 10 THEN NULL                               -- 8% sin correo
         WHEN t.Edad < 14 THEN CONCAT('acudiente', t.n, '@correo.com')
         ELSE CONCAT('paciente', t.n, '@correo.com') END,
    CASE WHEN t.rCalidad >= 90 THEN NULL                                          -- 10% sin teléfono
         ELSE CONCAT('3', RIGHT(CONCAT('000000000', t.rTel), 9)) END,
    CONCAT(N'Carrera ', t.n % 120 + 1, N' # ', t.n % 90 + 1, N' - ', t.n % 99 + 1),
    ra.AseguradoraID,
    rc.CiudadID,
    /* registro 2016-2023, nunca antes de nacer */
    CASE WHEN DATEADD(DAY, t.rRegistro, '2016-01-01') < DATEADD(DAY, -(t.Edad * 365 + CAST(t.hDiaNac AS INT)), @FechaInicio)
         THEN DATEADD(DAY, 30, DATEADD(DAY, -(t.Edad * 365 + CAST(t.hDiaNac AS INT)), @FechaInicio))
         ELSE DATEADD(DAY, t.rRegistro, '2016-01-01') END
FROM #PacEdad t
JOIN #RangoCiudad rc ON t.rCiudad BETWEEN rc.Desde AND rc.Hasta
JOIN #RangoAseg   ra ON t.rAseg   BETWEEN ra.Desde AND ra.Hasta
JOIN #NomSexo   nom ON nom.Genero = t.Genero AND nom.rn = t.rNombre % nom.Total + 1
JOIN #Apellidos a1  ON a1.id  = t.rApe1
JOIN #Apellidos a2  ON a2.id  = t.rApe2
ORDER BY t.n;

SET IDENTITY_INSERT Pacientes OFF;

/* ════════════════════════════════════════════
   4. PORTAFOLIO DE SERVICIOS
   ════════════════════════════════════════════ */
INSERT INTO LineasServicio (Nombre) VALUES
    (N'Consulta externa'), (N'Laboratorio clínico'), (N'Imágenes diagnósticas'),
    (N'Odontología'), (N'Promoción y prevención'), (N'Cirugía ambulatoria');

/* Tipo de servicio con su rango de tarifa y su "peso" de demanda */
IF OBJECT_ID('tempdb..#TipoCarga') IS NOT NULL DROP TABLE #TipoCarga;
CREATE TABLE #TipoCarga (Nombre NVARCHAR(60), Linea NVARCHAR(50), TMin DECIMAL(12,2), TMax DECIMAL(12,2), Peso INT);
INSERT INTO #TipoCarga VALUES
    (N'Consulta de medicina general',       N'Consulta externa',        38000,   85000, 20),
    (N'Consulta especializada primera vez', N'Consulta externa',        95000,  260000,  2),
    (N'Consulta especializada de control',  N'Consulta externa',        70000,  190000,  2),
    (N'Psicología',                         N'Consulta externa',        65000,  150000,  3),
    (N'Hematología',                        N'Laboratorio clínico',     12000,   65000,  5),
    (N'Química sanguínea',                  N'Laboratorio clínico',      9000,   95000,  5),
    (N'Microbiología',                      N'Laboratorio clínico',     22000,  160000,  2),
    (N'Pruebas especiales',                 N'Laboratorio clínico',     70000,  650000,  1),
    (N'Rayos X',                            N'Imágenes diagnósticas',   45000,  160000,  5),
    (N'Ecografía',                          N'Imágenes diagnósticas',   85000,  330000,  4),
    (N'Tomografía',                         N'Imágenes diagnósticas',  280000, 1100000,  1),
    (N'Resonancia magnética',               N'Imágenes diagnósticas',  550000, 2200000,  1),
    (N'Odontología general',                N'Odontología',             40000,  180000,  4),
    (N'Higiene oral',                       N'Odontología',             35000,   95000,  4),
    (N'Endodoncia',                         N'Odontología',            280000,  850000,  1),
    (N'Ortodoncia',                         N'Odontología',            120000, 2800000,  2),
    (N'Vacunación',                         N'Promoción y prevención',  25000,  380000,  3),
    (N'Tamizajes',                          N'Promoción y prevención',  35000,  220000,  3),
    (N'Control prenatal',                   N'Promoción y prevención',  55000,  160000,  2),
    (N'Cirugía menor',                      N'Cirugía ambulatoria',    320000, 1600000,  3),
    (N'Procedimientos endoscópicos',        N'Cirugía ambulatoria',    480000, 2100000,  2),
    (N'Cirugía oftalmológica',              N'Cirugía ambulatoria',   1800000, 6800000,  1);

INSERT INTO TiposServicio (Nombre, LineaID, TarifaMin, TarifaMax)
SELECT t.Nombre, l.LineaID, t.TMin, t.TMax
FROM #TipoCarga t
JOIN LineasServicio l ON l.Nombre = t.Linea;

INSERT INTO Especialidades (Nombre, EsQuirurgica) VALUES
    (N'Medicina general', 0), (N'Pediatría', 0), (N'Ginecología y obstetricia', 1), (N'Medicina interna', 0),
    (N'Cardiología', 0), (N'Dermatología', 0), (N'Ortopedia', 1), (N'Oftalmología', 1),
    (N'Otorrinolaringología', 1), (N'Gastroenterología', 0), (N'Psicología', 0), (N'Nutrición', 0),
    (N'Odontología general', 0), (N'Endodoncia', 0), (N'Ortodoncia', 0), (N'Bacteriología', 0),
    (N'Radiología', 0), (N'Enfermería', 0), (N'Cirugía general', 1);

/* Nombres base de los servicios. Especialidad NULL = se abre por cada especialidad de consulta */
IF OBJECT_ID('tempdb..#ServBase') IS NOT NULL DROP TABLE #ServBase;
CREATE TABLE #ServBase (id INT IDENTITY(1,1), Tipo NVARCHAR(60), Nombre NVARCHAR(120), Especialidad NVARCHAR(60) NULL);
INSERT INTO #ServBase (Tipo, Nombre, Especialidad) VALUES
    (N'Consulta de medicina general', N'Consulta de primera vez por medicina general', N'Medicina general'),
    (N'Consulta de medicina general', N'Consulta de control por medicina general',     N'Medicina general'),
    (N'Consulta de medicina general', N'Consulta prioritaria por medicina general',    N'Medicina general'),
    (N'Consulta especializada primera vez', N'Consulta de primera vez por', NULL),
    (N'Consulta especializada de control',  N'Consulta de control por',     NULL),
    (N'Psicología', N'Consulta de psicología de primera vez', N'Psicología'),
    (N'Psicología', N'Sesión de psicoterapia individual',     N'Psicología'),
    (N'Psicología', N'Sesión de psicoterapia de pareja',      N'Psicología'),
    (N'Hematología', N'Hemograma completo',                    N'Bacteriología'),
    (N'Hematología', N'Velocidad de sedimentación globular',   N'Bacteriología'),
    (N'Hematología', N'Tiempo de protrombina (PT)',            N'Bacteriología'),
    (N'Hematología', N'Tiempo de tromboplastina (PTT)',        N'Bacteriología'),
    (N'Hematología', N'Hemoclasificación',                     N'Bacteriología'),
    (N'Química sanguínea', N'Glucosa en ayunas',               N'Bacteriología'),
    (N'Química sanguínea', N'Hemoglobina glicosilada',         N'Bacteriología'),
    (N'Química sanguínea', N'Perfil lipídico',                 N'Bacteriología'),
    (N'Química sanguínea', N'Creatinina en suero',             N'Bacteriología'),
    (N'Química sanguínea', N'Transaminasas (ALT / AST)',       N'Bacteriología'),
    (N'Química sanguínea', N'Ácido úrico',                     N'Bacteriología'),
    (N'Química sanguínea', N'Hormona estimulante de tiroides (TSH)', N'Bacteriología'),
    (N'Microbiología', N'Urocultivo',                          N'Bacteriología'),
    (N'Microbiología', N'Coprológico',                         N'Bacteriología'),
    (N'Microbiología', N'Frotis de flujo vaginal',             N'Bacteriología'),
    (N'Microbiología', N'Hemocultivo',                         N'Bacteriología'),
    (N'Pruebas especiales', N'Antígeno prostático específico', N'Bacteriología'),
    (N'Pruebas especiales', N'Perfil hormonal femenino',       N'Bacteriología'),
    (N'Pruebas especiales', N'Prueba de VIH (ELISA)',          N'Bacteriología'),
    (N'Pruebas especiales', N'Panel de alergias',              N'Bacteriología'),
    (N'Pruebas especiales', N'Vitamina D',                     N'Bacteriología'),
    (N'Rayos X', N'Radiografía de tórax',                      N'Radiología'),
    (N'Rayos X', N'Radiografía de columna lumbar',             N'Radiología'),
    (N'Rayos X', N'Radiografía de rodilla',                    N'Radiología'),
    (N'Rayos X', N'Radiografía de mano',                       N'Radiología'),
    (N'Ecografía', N'Ecografía abdominal total',               N'Radiología'),
    (N'Ecografía', N'Ecografía obstétrica',                    N'Radiología'),
    (N'Ecografía', N'Ecografía de tiroides',                   N'Radiología'),
    (N'Ecografía', N'Ecografía pélvica',                       N'Radiología'),
    (N'Ecografía', N'Mamografía y ecografía de mama',          N'Radiología'),
    (N'Tomografía', N'Tomografía de cráneo simple',            N'Radiología'),
    (N'Tomografía', N'Tomografía de abdomen contrastada',      N'Radiología'),
    (N'Tomografía', N'Tomografía de tórax',                    N'Radiología'),
    (N'Resonancia magnética', N'Resonancia magnética de rodilla',         N'Radiología'),
    (N'Resonancia magnética', N'Resonancia magnética de columna lumbar',  N'Radiología'),
    (N'Resonancia magnética', N'Resonancia magnética cerebral',           N'Radiología'),
    (N'Odontología general', N'Consulta odontológica',         N'Odontología general'),
    (N'Odontología general', N'Obturación en resina',          N'Odontología general'),
    (N'Odontología general', N'Exodoncia simple',              N'Odontología general'),
    (N'Odontología general', N'Radiografía periapical',        N'Odontología general'),
    (N'Higiene oral', N'Profilaxis dental',                    N'Odontología general'),
    (N'Higiene oral', N'Detartraje supragingival',             N'Odontología general'),
    (N'Higiene oral', N'Aplicación de flúor',                  N'Odontología general'),
    (N'Higiene oral', N'Aplicación de sellantes',              N'Odontología general'),
    (N'Endodoncia', N'Endodoncia unirradicular',               N'Endodoncia'),
    (N'Endodoncia', N'Endodoncia multirradicular',             N'Endodoncia'),
    (N'Endodoncia', N'Retratamiento de endodoncia',            N'Endodoncia'),
    (N'Ortodoncia', N'Control mensual de ortodoncia',          N'Ortodoncia'),
    (N'Ortodoncia', N'Instalación de aparatología fija',       N'Ortodoncia'),
    (N'Ortodoncia', N'Retenedor removible',                    N'Ortodoncia'),
    (N'Vacunación', N'Vacuna contra la influenza',             N'Enfermería'),
    (N'Vacunación', N'Vacuna contra el VPH',                   N'Enfermería'),
    (N'Vacunación', N'Vacuna contra la hepatitis B',           N'Enfermería'),
    (N'Vacunación', N'Vacuna contra el neumococo',             N'Enfermería'),
    (N'Vacunación', N'Vacuna contra la fiebre amarilla',       N'Enfermería'),
    (N'Tamizajes', N'Citología cervicouterina',                N'Enfermería'),
    (N'Tamizajes', N'Tamizaje de riesgo cardiovascular',       N'Medicina general'),
    (N'Tamizajes', N'Tamizaje de agudeza visual',              N'Enfermería'),
    (N'Tamizajes', N'Valoración de crecimiento y desarrollo',  N'Enfermería'),
    (N'Control prenatal', N'Control prenatal de primera vez',  N'Ginecología y obstetricia'),
    (N'Control prenatal', N'Control prenatal de seguimiento',  N'Enfermería'),
    (N'Control prenatal', N'Curso de preparación para la maternidad', N'Enfermería'),
    (N'Cirugía menor', N'Resección de lesión de piel',         N'Dermatología'),
    (N'Cirugía menor', N'Drenaje de absceso',                  N'Cirugía general'),
    (N'Cirugía menor', N'Retiro de uña encarnada',             N'Cirugía general'),
    (N'Cirugía menor', N'Sutura de herida',                    N'Cirugía general'),
    (N'Cirugía menor', N'Infiltración articular',              N'Ortopedia'),
    (N'Procedimientos endoscópicos', N'Endoscopia digestiva alta', N'Gastroenterología'),
    (N'Procedimientos endoscópicos', N'Colonoscopia total',        N'Gastroenterología'),
    (N'Procedimientos endoscópicos', N'Rectosigmoidoscopia',       N'Gastroenterología'),
    (N'Cirugía oftalmológica', N'Cirugía de catarata',         N'Oftalmología'),
    (N'Cirugía oftalmológica', N'Cirugía refractiva láser',    N'Oftalmología'),
    (N'Cirugía oftalmológica', N'Resección de pterigión',      N'Oftalmología');

/* Especialidades que abren consulta especializada */
IF OBJECT_ID('tempdb..#EspConsulta') IS NOT NULL DROP TABLE #EspConsulta;
CREATE TABLE #EspConsulta (Especialidad NVARCHAR(60));
INSERT INTO #EspConsulta VALUES
    (N'Pediatría'), (N'Ginecología y obstetricia'), (N'Medicina interna'), (N'Cardiología'),
    (N'Dermatología'), (N'Ortopedia'), (N'Oftalmología'), (N'Otorrinolaringología'),
    (N'Gastroenterología'), (N'Nutrición');

IF OBJECT_ID('tempdb..#ServLista') IS NOT NULL DROP TABLE #ServLista;
SELECT ROW_NUMBER() OVER (ORDER BY ts.TipoServicioID, x.Nombre) AS n,
       x.Nombre, ts.TipoServicioID, ts.TarifaMin, ts.TarifaMax, e.EspecialidadID
INTO #ServLista
FROM (
    SELECT b.Tipo, b.Nombre, b.Especialidad FROM #ServBase b WHERE b.Especialidad IS NOT NULL
    UNION ALL
    SELECT b.Tipo,
           CONCAT(b.Nombre, N' ', LOWER(ec.Especialidad)),
           ec.Especialidad
    FROM #ServBase b CROSS JOIN #EspConsulta ec
    WHERE b.Especialidad IS NULL
) AS x
JOIN TiposServicio  ts ON ts.Nombre = x.Tipo
JOIN Especialidades e  ON e.Nombre  = x.Especialidad;

IF OBJECT_ID('tempdb..#ServCalc') IS NOT NULL DROP TABLE #ServCalc;
SELECT s.*,
       /* tarifa sesgada hacia el rango bajo, redondeada a centenas */
       CAST(ROUND(s.TarifaMin + (s.TarifaMax - s.TarifaMin) * POWER(ABS(CHECKSUM(NEWID()) % 10001) / 10000.0, 1.5), -2)
            AS DECIMAL(12,2)) AS Tarifa,
       ABS(CHECKSUM(NEWID()) % 26) AS rCosto,
       ABS(CHECKSUM(NEWID()) % 100) AS rActivo
INTO #ServCalc
FROM #ServLista s;

SET IDENTITY_INSERT Servicios ON;

INSERT INTO Servicios (ServicioID, CodigoServicio, Nombre, TipoServicioID, EspecialidadID,
                       CostoUnitario, Tarifa, Activo)
SELECT n,
       CONCAT('SRV-', RIGHT(CONCAT('00000', n), 5)),
       Nombre, TipoServicioID, EspecialidadID,
       CAST(ROUND(Tarifa * (0.40 + rCosto / 100.0), -2) AS DECIMAL(12,2)),   -- costo = 40% a 65% de la tarifa plena
       Tarifa,
       CASE WHEN rActivo < 97 THEN 1 ELSE 0 END
FROM #ServCalc
ORDER BY n;

SET IDENTITY_INSERT Servicios OFF;

/* Diagnósticos (CIE-10) agrupados por la línea de servicio en que suelen aparecer */
IF OBJECT_ID('tempdb..#DiagCarga') IS NOT NULL DROP TABLE #DiagCarga;
CREATE TABLE #DiagCarga (Codigo VARCHAR(6), Descripcion NVARCHAR(150), Capitulo NVARCHAR(100), Linea NVARCHAR(50));
INSERT INTO #DiagCarga VALUES
    ('I10X', N'Hipertensión esencial (primaria)',                 N'Enfermedades del sistema circulatorio',       N'Consulta externa'),
    ('E119', N'Diabetes mellitus tipo 2 sin complicaciones',      N'Enfermedades endocrinas y metabólicas',       N'Consulta externa'),
    ('J069', N'Infección aguda de las vías respiratorias superiores', N'Enfermedades del sistema respiratorio',  N'Consulta externa'),
    ('J459', N'Asma no especificada',                             N'Enfermedades del sistema respiratorio',       N'Consulta externa'),
    ('K297', N'Gastritis no especificada',                        N'Enfermedades del sistema digestivo',          N'Consulta externa'),
    ('M545', N'Lumbago no especificado',                          N'Enfermedades del sistema osteomuscular',      N'Consulta externa'),
    ('L700', N'Acné vulgar',                                      N'Enfermedades de la piel',                     N'Consulta externa'),
    ('H527', N'Trastorno de la refracción no especificado',       N'Enfermedades del ojo y sus anexos',           N'Consulta externa'),
    ('F411', N'Trastorno de ansiedad generalizada',               N'Trastornos mentales y del comportamiento',    N'Consulta externa'),
    ('N390', N'Infección de vías urinarias, sitio no especificado', N'Enfermedades del sistema genitourinario',   N'Consulta externa'),
    ('E669', N'Obesidad no especificada',                         N'Enfermedades endocrinas y metabólicas',       N'Consulta externa'),
    ('R51X', N'Cefalea',                                          N'Síntomas y signos no clasificados',           N'Consulta externa'),
    ('R101', N'Dolor abdominal localizado en parte superior',     N'Síntomas y signos no clasificados',           N'Laboratorio clínico'),
    ('Z017', N'Examen de laboratorio',                            N'Factores que influyen en el estado de salud', N'Laboratorio clínico'),
    ('E785', N'Hiperlipidemia no especificada',                   N'Enfermedades endocrinas y metabólicas',       N'Laboratorio clínico'),
    ('M255', N'Dolor en articulación',                            N'Enfermedades del sistema osteomuscular',      N'Imágenes diagnósticas'),
    ('R928', N'Hallazgo anormal en imagen de mama',               N'Síntomas y signos no clasificados',           N'Imágenes diagnósticas'),
    ('S934', N'Esguince de tobillo',                              N'Traumatismos',                                N'Imágenes diagnósticas'),
    ('K021', N'Caries de la dentina',                             N'Enfermedades del sistema digestivo',          N'Odontología'),
    ('K051', N'Gingivitis crónica',                               N'Enfermedades del sistema digestivo',          N'Odontología'),
    ('K040', N'Pulpitis',                                         N'Enfermedades del sistema digestivo',          N'Odontología'),
    ('K076', N'Trastornos de la articulación temporomaxilar',     N'Enfermedades del sistema digestivo',          N'Odontología'),
    ('Z000', N'Examen médico general',                            N'Factores que influyen en el estado de salud', N'Promoción y prevención'),
    ('Z238', N'Necesidad de inmunización contra otra enfermedad', N'Factores que influyen en el estado de salud', N'Promoción y prevención'),
    ('Z348', N'Supervisión de otros embarazos normales',          N'Factores que influyen en el estado de salud', N'Promoción y prevención'),
    ('Z124', N'Examen de pesquisa de tumor de cuello uterino',    N'Factores que influyen en el estado de salud', N'Promoción y prevención'),
    ('Z136', N'Examen de pesquisa de trastornos cardiovasculares', N'Factores que influyen en el estado de salud', N'Promoción y prevención'),
    ('H259', N'Catarata senil no especificada',                   N'Enfermedades del ojo y sus anexos',           N'Cirugía ambulatoria'),
    ('H110', N'Pterigión',                                        N'Enfermedades del ojo y sus anexos',           N'Cirugía ambulatoria'),
    ('K635', N'Pólipo del colon',                                 N'Enfermedades del sistema digestivo',          N'Cirugía ambulatoria'),
    ('D230', N'Tumor benigno de la piel',                         N'Tumores (neoplasias)',                        N'Cirugía ambulatoria'),
    ('L600', N'Uña encarnada',                                    N'Enfermedades de la piel',                     N'Cirugía ambulatoria'),
    ('L029', N'Absceso cutáneo de sitio no especificado',         N'Enfermedades de la piel',                     N'Cirugía ambulatoria');

INSERT INTO Diagnosticos (CodigoCIE10, Descripcion, Capitulo)
SELECT Codigo, Descripcion, Capitulo FROM #DiagCarga ORDER BY Codigo;

IF OBJECT_ID('tempdb..#DiagLinea') IS NOT NULL DROP TABLE #DiagLinea;
SELECT dc.Linea, d.DiagnosticoID,
       ROW_NUMBER() OVER (PARTITION BY dc.Linea ORDER BY d.DiagnosticoID) AS rn,
       COUNT(*)     OVER (PARTITION BY dc.Linea)                          AS Total
INTO #DiagLinea
FROM #DiagCarga dc
JOIN Diagnosticos d ON d.CodigoCIE10 = dc.Codigo;

/* ════════════════════════════════════════════
   5. MODALIDADES, SEDES Y PROFESIONALES
   ════════════════════════════════════════════ */
INSERT INTO ModalidadesAtencion (Nombre) VALUES
    (N'Presencial'), (N'Telemedicina'), (N'Domiciliaria'), (N'Extramural');

INSERT INTO Sedes (Nombre, TipoSede, CiudadID, Direccion, NumeroConsultorios, FechaApertura)
SELECT s.Nombre, s.Tipo, c.CiudadID, s.Direccion, s.Consultorios, s.Apertura
FROM (VALUES
    (N'Medellín El Poblado',   N'Física',  N'Medellín',     N'Carrera 43A # 7-50',        28, CAST('2012-02-01' AS DATE)),
    (N'Medellín Laureles',     N'Física',  N'Medellín',     N'Circular 4 # 70-12',        22, CAST('2014-08-15' AS DATE)),
    (N'Envigado',              N'Física',  N'Envigado',     N'Calle 38 Sur # 43-20',      16, CAST('2017-03-01' AS DATE)),
    (N'Bello',                 N'Física',  N'Bello',        N'Carrera 50 # 46-31',        14, CAST('2019-05-20' AS DATE)),
    (N'Bogotá Usaquén',        N'Física',  N'Bogotá',       N'Calle 127 # 15-40',         26, CAST('2013-06-01' AS DATE)),
    (N'Bogotá Chapinero',      N'Física',  N'Bogotá',       N'Carrera 13 # 63-18',        20, CAST('2015-09-10' AS DATE)),
    (N'Bogotá Kennedy',        N'Física',  N'Bogotá',       N'Avenida 1 de Mayo # 72-05', 18, CAST('2018-01-15' AS DATE)),
    (N'Cali Ciudad Jardín',    N'Física',  N'Cali',         N'Carrera 105 # 14-30',       18, CAST('2016-04-05' AS DATE)),
    (N'Cali Centro',           N'Física',  N'Cali',         N'Calle 10 # 5-22',           14, CAST('2020-07-01' AS DATE)),
    (N'Barranquilla Norte',    N'Física',  N'Barranquilla', N'Calle 84 # 51B-10',         16, CAST('2016-11-12' AS DATE)),
    (N'Cartagena Bocagrande',  N'Física',  N'Cartagena',    N'Avenida San Martín # 9-45', 12, CAST('2019-03-03' AS DATE)),
    (N'Bucaramanga Cabecera',  N'Física',  N'Bucaramanga',  N'Carrera 33 # 48-20',        12, CAST('2018-10-01' AS DATE)),
    (N'Pereira Pinares',       N'Física',  N'Pereira',      N'Avenida Circunvalar # 12-60', 10, CAST('2021-02-19' AS DATE)),
    (N'Manizales Cable',       N'Física',  N'Manizales',    N'Carrera 23 # 65-11',        10, CAST('2022-01-15' AS DATE)),
    (N'Sede Virtual – Telemedicina', N'Virtual', N'Medellín', N'Centro de telesalud, Edificio Torre Médica', 0, CAST('2020-04-01' AS DATE))
) AS s(Nombre, Tipo, Ciudad, Direccion, Consultorios, Apertura)
JOIN Ciudades c ON c.Nombre = s.Ciudad;

INSERT INTO Cargos (Nombre) VALUES
    (N'Médico general'), (N'Médico especialista'), (N'Odontólogo'), (N'Enfermero jefe'),
    (N'Bacteriólogo'), (N'Psicólogo'), (N'Nutricionista');

/* Plantilla por especialidad: cuántos profesionales en cada sede física y en la virtual */
IF OBJECT_ID('tempdb..#EspCargo') IS NOT NULL DROP TABLE #EspCargo;
CREATE TABLE #EspCargo (Especialidad NVARCHAR(60), Cargo NVARCHAR(50), CantFisica INT, CantVirtual INT);
INSERT INTO #EspCargo VALUES
    (N'Medicina general',          N'Médico general',      3, 4),
    (N'Pediatría',                 N'Médico especialista', 1, 1),
    (N'Ginecología y obstetricia', N'Médico especialista', 1, 0),
    (N'Medicina interna',          N'Médico especialista', 1, 1),
    (N'Cardiología',               N'Médico especialista', 1, 1),
    (N'Dermatología',              N'Médico especialista', 1, 1),
    (N'Ortopedia',                 N'Médico especialista', 1, 0),
    (N'Oftalmología',              N'Médico especialista', 1, 0),
    (N'Otorrinolaringología',      N'Médico especialista', 1, 0),
    (N'Gastroenterología',         N'Médico especialista', 1, 0),
    (N'Psicología',                N'Psicólogo',           1, 2),
    (N'Nutrición',                 N'Nutricionista',       1, 1),
    (N'Odontología general',       N'Odontólogo',          2, 0),
    (N'Endodoncia',                N'Odontólogo',          1, 0),
    (N'Ortodoncia',                N'Odontólogo',          1, 0),
    (N'Bacteriología',             N'Bacteriólogo',        2, 0),
    (N'Radiología',                N'Médico especialista', 1, 0),
    (N'Enfermería',                N'Enfermero jefe',      2, 0),
    (N'Cirugía general',           N'Médico especialista', 1, 0);

IF OBJECT_ID('tempdb..#Plantilla') IS NOT NULL DROP TABLE #Plantilla;
SELECT s.SedeID, c.CargoID, e.EspecialidadID, k.n AS Consecutivo,
       ABS(CHECKSUM(NEWID()) % @nNom) + 1 AS rNom,
       ABS(CHECKSUM(NEWID()) % @nApe) + 1 AS rA1,
       ABS(CHECKSUM(NEWID()) % @nApe) + 1 AS rA2,
       ABS(CHECKSUM(NEWID()) % 3600)      AS rIngreso
INTO #Plantilla
FROM Sedes s
JOIN #EspCargo p ON 1 = 1
JOIN Cargos c         ON c.Nombre = p.Cargo
JOIN Especialidades e ON e.Nombre = p.Especialidad
JOIN #N k ON k.n <= CASE WHEN s.TipoSede = N'Física' THEN p.CantFisica ELSE p.CantVirtual END;

INSERT INTO Profesionales (NumeroDocumento, RegistroMedico, Nombres, Apellidos, CargoID, EspecialidadID, SedeID, FechaIngreso)
SELECT CAST(43000000 + ROW_NUMBER() OVER (ORDER BY x.SedeID, x.EspecialidadID, x.Consecutivo) * 977 AS VARCHAR(12)),
       CONCAT('RM-', 50000 + ROW_NUMBER() OVER (ORDER BY x.SedeID, x.EspecialidadID, x.Consecutivo) * 13),
       nom.Nombre,
       CONCAT(a1.Apellido, N' ', a2.Apellido),
       x.CargoID, x.EspecialidadID, x.SedeID,
       DATEADD(DAY, x.rIngreso, '2012-01-01')
FROM #Plantilla AS x
JOIN #Nombres   nom ON nom.id = x.rNom
JOIN #Apellidos a1  ON a1.id  = x.rA1
JOIN #Apellidos a2  ON a2.id  = x.rA2;

/* ════════════════════════════════════════════
   6. CATÁLOGOS TRANSACCIONALES
   ════════════════════════════════════════════ */
INSERT INTO MediosPago (Nombre, EsAseguradora) VALUES
    (N'Efectivo', 0), (N'Tarjeta débito', 0), (N'Tarjeta crédito', 0),
    (N'Transferencia PSE', 0), (N'Billetera digital', 0), (N'Cargo a aseguradora', 1);

INSERT INTO EstadosAtencion (Nombre) VALUES (N'Realizada'), (N'Cancelada'), (N'Inasistencia');

/* ════════════════════════════════════════════
   7. ATENCIONES (encabezado)
   ════════════════════════════════════════════ */

/* Estacionalidad por mes (picos respiratorios y baja en vacaciones) */
IF OBJECT_ID('tempdb..#PesoMes') IS NOT NULL DROP TABLE #PesoMes;
CREATE TABLE #PesoMes (Mes INT PRIMARY KEY, Peso INT);
INSERT INTO #PesoMes VALUES (1,80),(2,95),(3,105),(4,112),(5,112),(6,95),
                            (7,90),(8,100),(9,100),(10,110),(11,108),(12,72);

/* Candidatos con todos sus sorteos */
IF OBJECT_ID('tempdb..#AtnCand') IS NOT NULL DROP TABLE #AtnCand;
SELECT n,
       DATEADD(DAY, ABS(CHECKSUM(NEWID()) % @DiasPeriodo), @FechaInicio) AS Fecha,
       ABS(CHECKSUM(NEWID()) % 1000)     AS rAcepta,
       ABS(CHECKSUM(NEWID()) % 1000000)  AS rPaciente,
       ABS(CHECKSUM(NEWID()) % 100)      AS rModal,
       ABS(CHECKSUM(NEWID()) % 100)      AS rLinea,
       ABS(CHECKSUM(NEWID()) % 1000)     AS rSede,
       ABS(CHECKSUM(NEWID()) % 1000)     AS rProf,
       ABS(CHECKSUM(NEWID()) % 1000)     AS rDiag,
       ABS(CHECKSUM(NEWID()) % 100)      AS rEstado,
       ABS(CHECKSUM(NEWID()) % 1000)     AS rHora,
       ABS(CHECKSUM(NEWID()) % 60)       AS rMinuto,
       ABS(CHECKSUM(NEWID()) % 100)      AS rLineas,
       ABS(CHECKSUM(NEWID()) % 100)      AS rOrden,
       ABS(CHECKSUM(NEWID()) % 100)      AS rPago
INTO #AtnCand
FROM #N
WHERE n <= @nCandidatos;

/* Se conservan según estacionalidad (mes), día de la semana
   (sábado 65%, domingo 30%) y crecimiento (2024 = 88%, 2025 = 100%).
   DATEDIFF(...) % 7: 0 = lunes ... 6 = domingo, sin depender de SET DATEFIRST */
IF OBJECT_ID('tempdb..#AtnBase') IS NOT NULL DROP TABLE #AtnBase;
SELECT ROW_NUMBER() OVER (ORDER BY y.FechaAtencion, y.n) AS AtencionID,
       y.*
INTO #AtnBase
FROM (
    SELECT x.*,
           /* línea principal según la modalidad */
           CASE x.Modalidad
                WHEN N'Telemedicina' THEN N'Consulta externa'
                WHEN N'Domiciliaria' THEN CASE WHEN x.rLinea < 50 THEN N'Laboratorio clínico'
                                               WHEN x.rLinea < 80 THEN N'Promoción y prevención'
                                               ELSE N'Consulta externa' END
                WHEN N'Extramural'   THEN CASE WHEN x.rLinea < 75 THEN N'Promoción y prevención'
                                               ELSE N'Odontología' END
                ELSE CASE WHEN x.rLinea < 42 THEN N'Consulta externa'
                          WHEN x.rLinea < 60 THEN N'Laboratorio clínico'
                          WHEN x.rLinea < 72 THEN N'Imágenes diagnósticas'
                          WHEN x.rLinea < 85 THEN N'Odontología'
                          WHEN x.rLinea < 95 THEN N'Promoción y prevención'
                          ELSE N'Cirugía ambulatoria' END
           END AS LineaPrincipal,
           CASE WHEN x.rEstado < 88 THEN N'Realizada'
                WHEN x.rEstado < 94 THEN N'Cancelada'
                ELSE N'Inasistencia' END AS Estado,
           DATEADD(MINUTE, x.rMinuto,
               DATEADD(HOUR,
                   CASE x.Modalidad WHEN N'Telemedicina' THEN 7 + x.rHora % 15   -- 7 a 21 h
                                    WHEN N'Presencial'   THEN 6 + x.rHora % 13   -- 6 a 18 h
                                    ELSE 7 + x.rHora % 9 END,                     -- 7 a 15 h
                   CAST(x.Fecha AS DATETIME2(0)))) AS FechaAtencion
    FROM (
        SELECT c.*,
               DATEDIFF(DAY, '19000101', c.Fecha) % 7 AS DiaSemana,
               /* la telemedicina gana participación en 2025 */
               CASE WHEN YEAR(c.Fecha) = 2024 THEN
                         CASE WHEN c.rModal < 72 THEN N'Presencial' WHEN c.rModal < 87 THEN N'Telemedicina'
                              WHEN c.rModal < 95 THEN N'Domiciliaria' ELSE N'Extramural' END
                    ELSE CASE WHEN c.rModal < 63 THEN N'Presencial' WHEN c.rModal < 86 THEN N'Telemedicina'
                              WHEN c.rModal < 95 THEN N'Domiciliaria' ELSE N'Extramural' END
               END AS Modalidad
        FROM #AtnCand c
        JOIN #PesoMes pm ON pm.Mes = MONTH(c.Fecha)
        WHERE c.rAcepta * 1500 < pm.Peso
                               * CASE WHEN YEAR(c.Fecha) = 2024 THEN 88 ELSE 100 END
                               * CASE DATEDIFF(DAY, '19000101', c.Fecha) % 7 WHEN 5 THEN 65 WHEN 6 THEN 30 ELSE 112 END
    ) AS x
) AS y;

/* Número de servicios y orden externa según la línea principal */
IF OBJECT_ID('tempdb..#AtnLineas') IS NOT NULL DROP TABLE #AtnLineas;
SELECT b.*,
       CASE WHEN b.Modalidad = N'Telemedicina' THEN 1
            WHEN b.LineaPrincipal = N'Consulta externa' THEN
                 CASE WHEN b.rLineas < 40 THEN 1 WHEN b.rLineas < 65 THEN 2 WHEN b.rLineas < 85 THEN 3 ELSE 4 END
            WHEN b.LineaPrincipal = N'Laboratorio clínico' THEN
                 CASE WHEN b.rLineas < 30 THEN 1 WHEN b.rLineas < 60 THEN 2 WHEN b.rLineas < 85 THEN 3 ELSE 4 END
            WHEN b.LineaPrincipal = N'Cirugía ambulatoria' THEN
                 CASE WHEN b.rLineas < 50 THEN 1 WHEN b.rLineas < 80 THEN 2 ELSE 3 END
            ELSE CASE WHEN b.rLineas < 65 THEN 1 ELSE 2 END
       END AS Lineas,
       /* la mitad de los exámenes llegan con orden de otro prestador: no hay profesional tratante */
       CASE WHEN b.LineaPrincipal IN (N'Laboratorio clínico', N'Imágenes diagnósticas')
             AND b.Modalidad IN (N'Presencial', N'Domiciliaria') AND b.rOrden < 50 THEN 1 ELSE 0 END AS OrdenExterna
INTO #AtnLineas
FROM #AtnBase b;

/* ════════════════════════════════════════════
   8. SELECCIÓN DE SERVICIOS (ponderada por demanda)
   ════════════════════════════════════════════ */
IF OBJECT_ID('tempdb..#ServPeso') IS NOT NULL DROP TABLE #ServPeso;
SELECT s.ServicioID, ts.LineaID, l.Nombre AS Linea, s.EspecialidadID, ts.Nombre AS TipoServicio, tc.Peso
INTO #ServPeso
FROM Servicios s
JOIN TiposServicio  ts ON ts.TipoServicioID = s.TipoServicioID
JOIN LineasServicio l  ON l.LineaID = ts.LineaID
JOIN #TipoCarga     tc ON tc.Nombre = ts.Nombre
WHERE s.Activo = 1;

/* Rangos por línea (modalidades con sede física) */
IF OBJECT_ID('tempdb..#ServRango') IS NOT NULL DROP TABLE #ServRango;
SELECT sp.*,
       SUM(sp.Peso) OVER (PARTITION BY sp.Linea ORDER BY sp.ServicioID ROWS UNBOUNDED PRECEDING) - sp.Peso + 1 AS Desde,
       SUM(sp.Peso) OVER (PARTITION BY sp.Linea ORDER BY sp.ServicioID ROWS UNBOUNDED PRECEDING)           AS Hasta,
       SUM(sp.Peso) OVER (PARTITION BY sp.Linea)                                                           AS Total
INTO #ServRango
FROM #ServPeso sp;

/* Rangos para telemedicina: solo consultas de especialidades con profesionales en la sede virtual */
IF OBJECT_ID('tempdb..#ServRangoTele') IS NOT NULL DROP TABLE #ServRangoTele;
SELECT sp.*,
       SUM(sp.Peso) OVER (ORDER BY sp.ServicioID ROWS UNBOUNDED PRECEDING) - sp.Peso + 1 AS Desde,
       SUM(sp.Peso) OVER (ORDER BY sp.ServicioID ROWS UNBOUNDED PRECEDING)           AS Hasta,
       SUM(sp.Peso) OVER ()                                                          AS Total
INTO #ServRangoTele
FROM #ServPeso sp
JOIN Especialidades e ON e.EspecialidadID = sp.EspecialidadID
JOIN #EspCargo ec     ON ec.Especialidad = e.Nombre AND ec.CantVirtual > 0
WHERE sp.Linea = N'Consulta externa';

/* Una fila por servicio solicitado; el 1.º es el principal, los demás son órdenes complementarias */
IF OBJECT_ID('tempdb..#DetTmp') IS NOT NULL DROP TABLE #DetTmp;
SELECT a.AtencionID, a.FechaAtencion, k.n AS k,
       CASE WHEN k.n = 1 THEN a.LineaPrincipal
            WHEN a.LineaPrincipal IN (N'Odontología', N'Promoción y prevención') THEN a.LineaPrincipal
            WHEN a.LineaPrincipal = N'Consulta externa' AND k.n = 4 THEN N'Imágenes diagnósticas'
            ELSE N'Laboratorio clínico' END AS LineaDetalle,
       CASE WHEN a.Modalidad = N'Telemedicina' AND k.n = 1 THEN 1 ELSE 0 END AS UsaTele,
       ABS(CHECKSUM(NEWID()) % 1000000) AS rServ,
       ABS(CHECKSUM(NEWID()) % 100)     AS rCantidad,
       ABS(CHECKSUM(NEWID()) % 100)     AS rDescuento
INTO #DetTmp
FROM #AtnLineas a
JOIN #N k ON k.n <= a.Lineas;

IF OBJECT_ID('tempdb..#DetSel') IS NOT NULL DROP TABLE #DetSel;
SELECT z.*
INTO #DetSel
FROM (
    SELECT u.*, ROW_NUMBER() OVER (PARTITION BY u.AtencionID, u.ServicioID ORDER BY u.k) AS rep
    FROM (
        SELECT d.AtencionID, d.FechaAtencion, d.k, d.rCantidad, d.rDescuento,
               sr.ServicioID, sr.EspecialidadID, sr.TipoServicio, sr.Linea
        FROM #DetTmp d
        JOIN #ServRango sr ON sr.Linea = d.LineaDetalle
                          AND d.UsaTele = 0
                          AND d.rServ % sr.Total + 1 BETWEEN sr.Desde AND sr.Hasta
        UNION ALL
        SELECT d.AtencionID, d.FechaAtencion, d.k, d.rCantidad, d.rDescuento,
               st.ServicioID, st.EspecialidadID, st.TipoServicio, st.Linea
        FROM #DetTmp d
        JOIN #ServRangoTele st ON d.UsaTele = 1
                              AND d.rServ % st.Total + 1 BETWEEN st.Desde AND st.Hasta
    ) AS u
) AS z
WHERE z.rep = 1;            -- un mismo servicio no se repite en la atención

/* ════════════════════════════════════════════
   9. PACIENTE, SEDE, PROFESIONAL Y DIAGNÓSTICO
   ════════════════════════════════════════════ */

/* Grupos de pacientes: todos, mujeres de 15 a 49 años (ginecología / prenatal) y menores (pediatría).
   Se ordenan por PacienteID: los ID bajos consultan más (pacientes crónicos / frecuentes). */
IF OBJECT_ID('tempdb..#Pool') IS NOT NULL DROP TABLE #Pool;
SELECT g.Grupo, g.PacienteID,
       ROW_NUMBER() OVER (PARTITION BY g.Grupo ORDER BY g.PacienteID) AS rn,
       COUNT(*)     OVER (PARTITION BY g.Grupo)                       AS Total
INTO #Pool
FROM (
    SELECT 'GEN' AS Grupo, p.PacienteID FROM Pacientes p
    UNION ALL
    SELECT 'FEM', p.PacienteID FROM Pacientes p
    WHERE p.Sexo = 'F' AND DATEDIFF(YEAR, p.FechaNacimiento, '2025-01-01') BETWEEN 15 AND 49
    UNION ALL
    SELECT 'PED', p.PacienteID FROM Pacientes p
    WHERE DATEDIFF(YEAR, p.FechaNacimiento, '2025-01-01') < 18
) AS g;

IF OBJECT_ID('tempdb..#PoolTotal') IS NOT NULL DROP TABLE #PoolTotal;
SELECT Grupo, MAX(Total) AS Total INTO #PoolTotal FROM #Pool GROUP BY Grupo;

/* Servicio principal de cada atención */
IF OBJECT_ID('tempdb..#Principal') IS NOT NULL DROP TABLE #Principal;
SELECT d.AtencionID, d.ServicioID, d.EspecialidadID, d.TipoServicio, e.Nombre AS Especialidad,
       CASE WHEN e.Nombre = N'Pediatría' THEN 'PED'
            WHEN e.Nombre = N'Ginecología y obstetricia' OR d.TipoServicio = N'Control prenatal' THEN 'FEM'
            ELSE 'GEN' END AS Grupo
INTO #Principal
FROM #DetSel d
JOIN Especialidades e ON e.EspecialidadID = d.EspecialidadID
WHERE d.k = 1;

/* Sedes físicas numeradas en general y por ciudad */
IF OBJECT_ID('tempdb..#SedeFisica') IS NOT NULL DROP TABLE #SedeFisica;
SELECT ROW_NUMBER() OVER (ORDER BY SedeID) AS rn, SedeID, CiudadID,
       ROW_NUMBER() OVER (PARTITION BY CiudadID ORDER BY SedeID) AS rnCiudad,
       COUNT(*)     OVER (PARTITION BY CiudadID)                 AS TotalCiudad
INTO #SedeFisica FROM Sedes WHERE TipoSede = N'Física';
DECLARE @nSedeFis    INT = (SELECT COUNT(*) FROM #SedeFisica);
DECLARE @SedeVirtual INT = (SELECT TOP 1 SedeID FROM Sedes WHERE TipoSede = N'Virtual');

/* Profesionales numerados por sede y especialidad */
IF OBJECT_ID('tempdb..#ProfSede') IS NOT NULL DROP TABLE #ProfSede;
SELECT SedeID, EspecialidadID, ProfesionalID,
       ROW_NUMBER() OVER (PARTITION BY SedeID, EspecialidadID ORDER BY ProfesionalID) AS rn,
       COUNT(*)     OVER (PARTITION BY SedeID, EspecialidadID)                        AS Total
INTO #ProfSede FROM Profesionales;

IF OBJECT_ID('tempdb..#AtnPac') IS NOT NULL DROP TABLE #AtnPac;
SELECT a.*, pr.ServicioID AS ServicioPrincipal, pr.EspecialidadID AS EspPrincipal, po.PacienteID
INTO #AtnPac
FROM #AtnLineas a
JOIN #Principal pr ON pr.AtencionID = a.AtencionID
JOIN #PoolTotal pt ON pt.Grupo = pr.Grupo
JOIN #Pool po      ON po.Grupo = pr.Grupo
                  AND po.rn = 1 + CAST(FLOOR(pt.Total * POWER(a.rPaciente / 1000000.0, 1.6)) AS INT);

/* Sede: telemedicina → sede virtual; demás → sede de la ciudad del paciente o, si no hay, una al azar.
   Aseguradora de la atención: la actual del paciente, salvo 4% que en 2024 estaba en otra. */
IF OBJECT_ID('tempdb..#AtnFinal') IS NOT NULL DROP TABLE #AtnFinal;
SELECT ap.*, s.SedeID,
       CASE WHEN ap.OrdenExterna = 1 THEN NULL ELSE ps.ProfesionalID END AS ProfesionalID,
       CASE WHEN ap.OrdenExterna = 1 THEN NULL ELSE dl.DiagnosticoID END AS DiagnosticoID,
       CASE WHEN YEAR(ap.FechaAtencion) = 2024 AND ap.PacienteID % 25 = 0
            THEN p.AseguradoraID % (@nAseg - 1) + 1          -- aseguradora anterior (otra de la lista)
            ELSE p.AseguradoraID END AS AseguradoraAtencion
INTO #AtnFinal
FROM #AtnPac ap
JOIN Pacientes p ON p.PacienteID = ap.PacienteID
LEFT JOIN #SedeFisica sc ON sc.CiudadID = p.CiudadID AND sc.rnCiudad = ap.rSede % sc.TotalCiudad + 1
LEFT JOIN #SedeFisica sf ON sf.rn = ap.rSede % @nSedeFis + 1
CROSS APPLY (SELECT CASE WHEN ap.Modalidad = N'Telemedicina' THEN @SedeVirtual
                         ELSE COALESCE(sc.SedeID, sf.SedeID) END AS SedeID) AS s
LEFT JOIN #ProfSede ps ON ps.SedeID = s.SedeID
                      AND ps.EspecialidadID = ap.EspPrincipal
                      AND ps.rn = ap.rProf % ps.Total + 1
LEFT JOIN #DiagLinea dl ON dl.Linea = ap.LineaPrincipal
                       AND dl.rn = ap.rDiag % dl.Total + 1;

SET IDENTITY_INSERT Atenciones ON;

INSERT INTO Atenciones (AtencionID, NumeroAtencion, PacienteID, SedeID, ProfesionalID, ModalidadID, EstadoID,
                        DiagnosticoID, AseguradoraID, OrdenExterna, FechaAtencion)
SELECT f.AtencionID,
       CONCAT('ATN-', RIGHT(CONCAT('0000000', f.AtencionID), 7)),
       f.PacienteID, f.SedeID, f.ProfesionalID, m.ModalidadID, ea.EstadoID,
       f.DiagnosticoID, f.AseguradoraAtencion, f.OrdenExterna, f.FechaAtencion
FROM #AtnFinal f
JOIN ModalidadesAtencion m  ON m.Nombre  = f.Modalidad
JOIN EstadosAtencion     ea ON ea.Nombre = f.Estado
ORDER BY f.AtencionID;

SET IDENTITY_INSERT Atenciones OFF;

/* ════════════════════════════════════════════
   10. DETALLE DE ATENCIONES
   ════════════════════════════════════════════ */
INSERT INTO DetalleAtencion (AtencionID, ServicioID, Cantidad, ValorUnitario, CostoUnitario, PorcentajeDescuento)
SELECT d.AtencionID,
       d.ServicioID,
       CASE WHEN d.TipoServicio = N'Psicología'          THEN 1 + d.rCantidad % 4    -- paquete de sesiones
            WHEN d.TipoServicio = N'Odontología general' THEN 1 + d.rCantidad % 3    -- varias piezas
            WHEN d.TipoServicio = N'Vacunación' AND d.rCantidad < 15 THEN 2
            ELSE 1 END,
       /* tarifa pactada con la aseguradora; las tarifas de 2024 eran 7% menores */
       CAST(ROUND(s.Tarifa * ta.FactorTarifa / CASE WHEN YEAR(d.FechaAtencion) = 2024 THEN 1.07 ELSE 1 END, -2)
            AS DECIMAL(12,2)),
       CAST(ROUND(s.CostoUnitario / CASE WHEN YEAR(d.FechaAtencion) = 2024 THEN 1.07 ELSE 1 END, -2)
            AS DECIMAL(12,2)),
       /* solo los particulares reciben descuento; en octubre y noviembre (campañas) es mayor */
       CASE WHEN ta.Nombre <> N'Particular' THEN 0
            WHEN MONTH(d.FechaAtencion) IN (10, 11) THEN
                 CASE WHEN d.rDescuento < 35 THEN 0 WHEN d.rDescuento < 60 THEN 10
                      WHEN d.rDescuento < 85 THEN 15 ELSE 25 END
            ELSE CASE WHEN d.rDescuento < 60 THEN 0 WHEN d.rDescuento < 78 THEN 5
                      WHEN d.rDescuento < 92 THEN 10 ELSE 15 END
       END
FROM #DetSel d
JOIN #AtnFinal       f  ON f.AtencionID = d.AtencionID
JOIN Servicios       s  ON s.ServicioID = d.ServicioID
JOIN Aseguradoras    a  ON a.AseguradoraID = f.AseguradoraAtencion
JOIN TiposAfiliacion ta ON ta.TipoAfiliacionID = a.TipoAfiliacionID
ORDER BY d.AtencionID, d.k;

/* ════════════════════════════════════════════
   11. PAGOS (solo atenciones realizadas)
       · Pago del paciente: copago / cuota moderadora / bono / tarifa particular
         (Promoción y prevención no cobra copago; 40% del subsidiado está exonerado)
       · Cuenta por cobrar a la aseguradora por el saldo, con fecha según los días pactados
   ════════════════════════════════════════════ */
IF OBJECT_ID('tempdb..#PagoCalc') IS NOT NULL DROP TABLE #PagoCalc;
SELECT f.AtencionID, f.FechaAtencion, f.Modalidad, f.rPago, a.DiasPagoPactados, t.Total,
       CASE WHEN ta.Nombre = N'Particular' THEN t.Total
            WHEN f.LineaPrincipal = N'Promoción y prevención' THEN 0
            WHEN ta.Nombre = N'Subsidiado' AND f.rPago < 40 THEN 0
            ELSE CAST(ROUND(t.Total * ta.PorcentajeCopago / 100, -2) AS DECIMAL(14,2)) END AS ValorPaciente
INTO #PagoCalc
FROM #AtnFinal f
JOIN Aseguradoras    a  ON a.AseguradoraID = f.AseguradoraAtencion
JOIN TiposAfiliacion ta ON ta.TipoAfiliacionID = a.TipoAfiliacionID
CROSS APPLY (
    SELECT CAST(SUM(da.Cantidad * da.ValorUnitario * (100 - da.PorcentajeDescuento) / 100) AS DECIMAL(14,2)) AS Total
    FROM DetalleAtencion da
    WHERE da.AtencionID = f.AtencionID
) AS t
WHERE f.Estado = N'Realizada';

INSERT INTO Pagos (AtencionID, MedioPagoID, FechaPago, Valor, NumeroCuotas)
SELECT x.AtencionID, mp.MedioPagoID, x.FechaPago, x.Valor, x.NumeroCuotas
FROM (
    /* pago del paciente */
    SELECT c.AtencionID, c.FechaAtencion AS FechaPago, c.ValorPaciente AS Valor,
           CASE WHEN c.Modalidad = N'Telemedicina' THEN
                     CASE WHEN c.rPago < 50 THEN N'Transferencia PSE' WHEN c.rPago < 85 THEN N'Tarjeta crédito'
                          ELSE N'Billetera digital' END
                WHEN c.Modalidad = N'Presencial' THEN
                     CASE WHEN c.rPago < 35 THEN N'Efectivo' WHEN c.rPago < 65 THEN N'Tarjeta débito'
                          WHEN c.rPago < 85 THEN N'Tarjeta crédito' ELSE N'Billetera digital' END
                ELSE CASE WHEN c.rPago < 50 THEN N'Efectivo' WHEN c.rPago < 80 THEN N'Billetera digital'
                          ELSE N'Tarjeta débito' END
           END AS Medio,
           CASE WHEN c.ValorPaciente >= 600000 AND c.rPago BETWEEN 65 AND 84 THEN CHOOSE(c.rPago % 3 + 1, 3, 6, 12)
                ELSE 1 END AS NumeroCuotas
    FROM #PagoCalc c
    WHERE c.ValorPaciente > 0
    UNION ALL
    /* saldo a cargo de la aseguradora */
    SELECT c.AtencionID, DATEADD(DAY, c.DiasPagoPactados, c.FechaAtencion), c.Total - c.ValorPaciente,
           N'Cargo a aseguradora', 1
    FROM #PagoCalc c
    WHERE c.Total - c.ValorPaciente > 0
) AS x
JOIN MediosPago mp ON mp.Nombre = x.Medio
ORDER BY x.AtencionID, x.FechaPago;

/* Limpieza de tablas temporales */
DROP TABLE #N, #CiudadCarga, #RangoCiudad, #AsegCarga, #RangoAseg, #Nombres, #NomSexo, #Apellidos,
           #PacTmp, #PacEdad, #TipoCarga, #ServBase, #EspConsulta, #ServLista, #ServCalc,
           #DiagCarga, #DiagLinea, #EspCargo, #Plantilla, #PesoMes, #AtnCand, #AtnBase, #AtnLineas,
           #ServPeso, #ServRango, #ServRangoTele, #DetTmp, #DetSel, #Pool, #PoolTotal, #Principal,
           #SedeFisica, #ProfSede, #AtnPac, #AtnFinal, #PagoCalc;

GO

/* ════════════════════════════════════════════
   12. VALIDACIÓN
   ════════════════════════════════════════════ */
SELECT 'Paises' AS Tabla, COUNT(*) AS Registros FROM Paises
UNION ALL SELECT 'Regiones', COUNT(*) FROM Regiones
UNION ALL SELECT 'Departamentos', COUNT(*) FROM Departamentos
UNION ALL SELECT 'Ciudades', COUNT(*) FROM Ciudades
UNION ALL SELECT 'TiposAfiliacion', COUNT(*) FROM TiposAfiliacion
UNION ALL SELECT 'Aseguradoras', COUNT(*) FROM Aseguradoras
UNION ALL SELECT 'Pacientes', COUNT(*) FROM Pacientes
UNION ALL SELECT 'LineasServicio', COUNT(*) FROM LineasServicio
UNION ALL SELECT 'TiposServicio', COUNT(*) FROM TiposServicio
UNION ALL SELECT 'Especialidades', COUNT(*) FROM Especialidades
UNION ALL SELECT 'Servicios', COUNT(*) FROM Servicios
UNION ALL SELECT 'Diagnosticos', COUNT(*) FROM Diagnosticos
UNION ALL SELECT 'ModalidadesAtencion', COUNT(*) FROM ModalidadesAtencion
UNION ALL SELECT 'Sedes', COUNT(*) FROM Sedes
UNION ALL SELECT 'Cargos', COUNT(*) FROM Cargos
UNION ALL SELECT 'Profesionales', COUNT(*) FROM Profesionales
UNION ALL SELECT 'MediosPago', COUNT(*) FROM MediosPago
UNION ALL SELECT 'EstadosAtencion', COUNT(*) FROM EstadosAtencion
UNION ALL SELECT 'Atenciones', COUNT(*) FROM Atenciones
UNION ALL SELECT 'DetalleAtencion', COUNT(*) FROM DetalleAtencion
UNION ALL SELECT 'Pagos', COUNT(*) FROM Pagos;

/* Control de integridad: solo las atenciones con orden externa deben quedar sin profesional (debe dar 0) */
SELECT COUNT(*) AS AtencionesSinProfesionalNoEsperadas
FROM Atenciones
WHERE ProfesionalID IS NULL AND OrdenExterna = 0;

/* Facturación por año y mes (se debe notar la baja de diciembre-enero y el crecimiento de 2025) */
SELECT YEAR(a.FechaAtencion) AS Anio, MONTH(a.FechaAtencion) AS Mes,
       COUNT(DISTINCT a.AtencionID) AS Atenciones,
       SUM(d.Cantidad * d.ValorUnitario * (100 - d.PorcentajeDescuento) / 100) AS FacturacionNeta
FROM Atenciones a
JOIN DetalleAtencion d ON d.AtencionID = a.AtencionID
JOIN EstadosAtencion e ON e.EstadoID = a.EstadoID
WHERE e.Nombre = N'Realizada'
GROUP BY YEAR(a.FechaAtencion), MONTH(a.FechaAtencion)
ORDER BY Anio, Mes;

/* Atenciones realizadas por modalidad y año (la telemedicina debe crecer más) */
SELECT m.Nombre AS Modalidad, YEAR(a.FechaAtencion) AS Anio, COUNT(*) AS Atenciones
FROM Atenciones a
JOIN ModalidadesAtencion m ON m.ModalidadID = a.ModalidadID
JOIN EstadosAtencion e     ON e.EstadoID = a.EstadoID
WHERE e.Nombre = N'Realizada'
GROUP BY m.Nombre, YEAR(a.FechaAtencion)
ORDER BY m.Nombre, Anio;
GO
