/* ════════════════════════════════════════════════════════════════════
   SCRIPT 01 · Creación del Data Warehouse CLINICABI_DW_Grupo1
   Esquema en ESTRELLA: 2 tablas de hechos que comparten 10 dimensiones.
   - Cada dimensión: clave sustituta (…Key, IDENTITY) + clave natural (…ID)
     para rastrear el dato hasta la fuente + miembro desconocido -1.
   - Se borra y recrea la base completa → el ETL siempre arranca desde cero
     y da el mismo resultado (requisito de re-ejecución).
   Por qué estrella y no copo de nieve: las jerarquías (geografía, línea →
   tipo → servicio, tipo de afiliación → aseguradora) se desnormalizan en
   una sola tabla por dimensión. Así cada consulta/visual hace 1 solo JOIN
   hecho→dimensión, Power BI trabaja mejor (relaciones 1:N directas, filtros
   simples) y el costo de repetir textos es mínimo (dimensiones pequeñas).
   ════════════════════════════════════════════════════════════════════ */
USE master;
GO
IF DB_ID(N'CLINICABI_DW_Grupo1') IS NOT NULL
BEGIN
    ALTER DATABASE CLINICABI_DW_Grupo1 SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE CLINICABI_DW_Grupo1;
END
GO
CREATE DATABASE CLINICABI_DW_Grupo1;
GO
ALTER DATABASE CLINICABI_DW_Grupo1 SET RECOVERY SIMPLE;
GO
USE CLINICABI_DW_Grupo1;
GO

/* ════════════════ DIMENSIONES ════════════════ */

/* DIM_Tiempo · grano: día. Conformada (la usan los 2 hechos). Clave inteligente AAAAMMDD. */
CREATE TABLE dbo.DIM_Tiempo (
    TiempoKey       INT          NOT NULL PRIMARY KEY,   -- AAAAMMDD; -1 = desconocido
    Fecha           DATE         NULL,
    Anio            INT          NULL,
    Semestre        TINYINT      NULL,
    Trimestre       TINYINT      NULL,
    NombreTrimestre NVARCHAR(10) NULL,                   -- 'T1'..'T4'
    Mes             TINYINT      NULL,
    NombreMes       NVARCHAR(15) NULL,                   -- en español (T10)
    MesCorto        NVARCHAR(5)  NULL,
    AnioMes         CHAR(7)      NULL,                   -- '2025-01'
    Dia             TINYINT      NULL,
    DiaSemana       TINYINT      NULL,                   -- 1 = lunes … 7 = domingo (sin DATEFIRST)
    NombreDia       NVARCHAR(15) NULL,
    EsFinDeSemana   BIT          NULL
);

/* DIM_Paciente · grano: paciente. Conformada. OLTP (T1–T4) + enriquecida con MongoDB (T11–T15). */
CREATE TABLE dbo.DIM_Paciente (
    PacienteKey          INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    PacienteID           INT           NOT NULL,          -- clave natural (OLTP y Mongo)
    TipoDocumento        VARCHAR(3)    NOT NULL,
    NombreTipoDocumento  NVARCHAR(30)  NOT NULL,          -- T2
    NumeroDocumento      VARCHAR(20)   NOT NULL,
    NombreCompleto       NVARCHAR(210) NOT NULL,          -- T1
    Sexo                 NVARCHAR(10)  NOT NULL,          -- T2: Femenino / Masculino / Sin dato
    FechaNacimiento      DATE          NULL,
    Edad                 INT           NULL,              -- T3: al 31-12-2025
    CursoVida            NVARCHAR(20)  NOT NULL,          -- T3: Res. 3280/2018
    Ciudad               NVARCHAR(60)  NOT NULL,          -- T4
    Departamento         NVARCHAR(60)  NOT NULL,
    Region               NVARCHAR(60)  NOT NULL,
    Pais                 NVARCHAR(60)  NOT NULL,
    -- Atributos de MongoDB (perfil vigente)
    TienePerfil          BIT           NOT NULL,
    OrigenRegistro       NVARCHAR(20)  NOT NULL,
    CanalPreferido       NVARCHAR(15)  NOT NULL,
    AceptaEmail          BIT           NOT NULL,          -- T14
    AceptaSMS            BIT           NOT NULL,
    AceptaWhatsApp       BIT           NOT NULL,
    LineasInteres        NVARCHAR(250) NOT NULL,          -- T13 (separadas por coma)
    ProgramaRiesgo       NVARCHAR(40)  NOT NULL,          -- T14
    NivelRiesgo          NVARCHAR(10)  NOT NULL,          -- T14
    Adherencia           INT           NULL,              -- T14: 0-100
    NPSPromedio          DECIMAL(4,2)  NULL,              -- T15
    TipoNPS              NVARCHAR(15)  NOT NULL,          -- T15: Promotor / Pasivo / Detractor / Sin encuesta
    CONSTRAINT UQ_DIM_Paciente_ID UNIQUE (PacienteID)
);

/* DIM_Servicio · grano: servicio. Jerarquía Línea → Tipo → Servicio desnormalizada (T5). */
CREATE TABLE dbo.DIM_Servicio (
    ServicioKey     INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    ServicioID      INT           NOT NULL,
    CodigoServicio  VARCHAR(20)   NOT NULL,
    NombreServicio  NVARCHAR(150) NOT NULL,
    TipoServicio    NVARCHAR(60)  NOT NULL,
    LineaServicio   NVARCHAR(50)  NOT NULL,
    Especialidad    NVARCHAR(60)  NOT NULL,
    EsQuirurgica    BIT           NOT NULL,
    Tarifa          DECIMAL(12,2) NULL,
    CostoUnitario   DECIMAL(12,2) NULL,
    RangoTarifa     NVARCHAR(30)  NOT NULL,               -- T5
    CONSTRAINT UQ_DIM_Servicio_ID UNIQUE (ServicioID)
);

/* DIM_Sede · grano: sede. Geografía desnormalizada (T4). */
CREATE TABLE dbo.DIM_Sede (
    SedeKey            INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SedeID             INT          NOT NULL,
    NombreSede         NVARCHAR(80) NOT NULL,
    TipoSede           NVARCHAR(20) NOT NULL,             -- Física / Virtual
    Ciudad             NVARCHAR(60) NOT NULL,
    Departamento       NVARCHAR(60) NOT NULL,
    Region             NVARCHAR(60) NOT NULL,
    Pais               NVARCHAR(60) NOT NULL,
    NumeroConsultorios INT          NULL,
    FechaApertura      DATE         NULL,
    CONSTRAINT UQ_DIM_Sede_ID UNIQUE (SedeID)
);

/* DIM_Profesional · grano: profesional. Con cargo, especialidad y sede (texto, sin copo de nieve). */
CREATE TABLE dbo.DIM_Profesional (
    ProfesionalKey  INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    ProfesionalID   INT           NOT NULL,
    RegistroMedico  VARCHAR(20)   NOT NULL,
    NombreCompleto  NVARCHAR(210) NOT NULL,
    Cargo           NVARCHAR(50)  NOT NULL,
    Especialidad    NVARCHAR(60)  NOT NULL,
    Sede            NVARCHAR(80)  NOT NULL,
    CONSTRAINT UQ_DIM_Profesional_ID UNIQUE (ProfesionalID)
);

/* DIM_Aseguradora · grano: aseguradora (pagador). Con su tipo de afiliación. */
CREATE TABLE dbo.DIM_Aseguradora (
    AseguradoraKey    INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    AseguradoraID     INT           NOT NULL,
    NombreAseguradora NVARCHAR(100) NOT NULL,
    NIT               VARCHAR(15)   NOT NULL,
    TipoAfiliacion    NVARCHAR(40)  NOT NULL,
    PorcentajeCopago  DECIMAL(5,2)  NULL,
    FactorTarifa      DECIMAL(4,2)  NULL,
    DiasPagoPactados  INT           NULL,
    CONSTRAINT UQ_DIM_Aseguradora_ID UNIQUE (AseguradoraID)
);

/* DIM_Diagnostico · grano: diagnóstico CIE-10. */
CREATE TABLE dbo.DIM_Diagnostico (
    DiagnosticoKey INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    DiagnosticoID  INT           NOT NULL,
    CodigoCIE10    VARCHAR(6)    NOT NULL,
    Descripcion    NVARCHAR(150) NOT NULL,
    Capitulo       NVARCHAR(100) NOT NULL,
    CONSTRAINT UQ_DIM_Diagnostico_ID UNIQUE (DiagnosticoID)
);

/* DIM_Modalidad · grano: modalidad (Presencial, Telemedicina, Domiciliaria, Extramural). */
CREATE TABLE dbo.DIM_Modalidad (
    ModalidadKey INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    ModalidadID  INT          NOT NULL,
    Modalidad    NVARCHAR(40) NOT NULL,
    CONSTRAINT UQ_DIM_Modalidad_ID UNIQUE (ModalidadID)
);

/* DIM_Campana · grano: campaña. Desde MongoDB con T20 (+ líneas estandarizadas T13). */
CREATE TABLE dbo.DIM_Campana (
    CampanaKey          INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    CampanaID           VARCHAR(20)   NOT NULL,           -- _id de Mongo: CMP-AAAA-MM
    NombreCampana       NVARCHAR(100) NOT NULL,
    Objetivo            NVARCHAR(60)  NOT NULL,
    Estado              NVARCHAR(20)  NOT NULL,
    FechaInicio         DATETIME2(0)  NULL,               -- hora de Colombia (UTC-5)
    FechaFin            DATETIME2(0)  NULL,
    Anio                INT           NULL,
    Canales             NVARCHAR(100) NOT NULL,           -- T20: texto separado por comas
    LineasPromocionadas NVARCHAR(250) NOT NULL,           -- T20 + T13
    SexoObjetivo        NVARCHAR(10)  NOT NULL,           -- T20: F / M / Todos
    EdadMin             INT           NULL,
    EdadMax             INT           NULL,
    DescuentoOfrecido   DECIMAL(5,2)  NULL,
    CodigoBeneficio     NVARCHAR(20)  NOT NULL,
    Presupuesto         DECIMAL(14,2) NULL,               -- T20: texto → número
    Responsable         NVARCHAR(80)  NOT NULL,           -- T20: vacío → 'Sin asignar'
    CONSTRAINT UQ_DIM_Campana_ID UNIQUE (CampanaID)
);

/* DIM_CanalContacto · grano: canal (email, sms, whatsapp, app). */
CREATE TABLE dbo.DIM_CanalContacto (
    CanalKey               INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    CodigoCanal            VARCHAR(10)  NOT NULL,         -- clave natural estandarizada (T16)
    NombreCanal            NVARCHAR(20) NOT NULL,
    RequiereConsentimiento BIT          NOT NULL,         -- app = 0 (T19)
    CONSTRAINT UQ_DIM_Canal_Codigo UNIQUE (CodigoCanal)
);
GO

/* ════════════════ HECHOS ════════════════ */

/* FACT_Atenciones · grano: un servicio prestado en una atención REALIZADA
   (= una línea de DetalleAtencion). */
CREATE TABLE dbo.FACT_Atenciones (
    AtencionServicioKey BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    TiempoKey           INT NOT NULL REFERENCES dbo.DIM_Tiempo(TiempoKey),
    PacienteKey         INT NOT NULL REFERENCES dbo.DIM_Paciente(PacienteKey),
    ServicioKey         INT NOT NULL REFERENCES dbo.DIM_Servicio(ServicioKey),
    SedeKey             INT NOT NULL REFERENCES dbo.DIM_Sede(SedeKey),
    ProfesionalKey      INT NOT NULL REFERENCES dbo.DIM_Profesional(ProfesionalKey),   -- T8: -1 si orden externa
    AseguradoraKey      INT NOT NULL REFERENCES dbo.DIM_Aseguradora(AseguradoraKey),   -- T9: pagador histórico
    DiagnosticoKey      INT NOT NULL REFERENCES dbo.DIM_Diagnostico(DiagnosticoKey),   -- T8
    ModalidadKey        INT NOT NULL REFERENCES dbo.DIM_Modalidad(ModalidadKey),
    CampanaKey          INT NOT NULL REFERENCES dbo.DIM_Campana(CampanaKey),           -- T21: -1 = no atribuida
    -- Dimensiones degeneradas / trazabilidad
    DetalleID           INT          NOT NULL,            -- clave natural de la línea
    AtencionID          INT          NOT NULL,
    NumeroAtencion      VARCHAR(20)  NOT NULL,
    MedioPagoPrincipal  NVARCHAR(40) NOT NULL,            -- T7: pago de mayor valor
    OrdenExterna        BIT          NOT NULL,
    -- Medidas
    Cantidad            INT           NOT NULL,
    ValorUnitario       DECIMAL(12,2) NOT NULL,
    PorcentajeDescuento DECIMAL(5,2)  NOT NULL,
    CostoUnitario       DECIMAL(12,2) NOT NULL,
    ValorBruto          DECIMAL(14,2) NOT NULL,           -- Cantidad × ValorUnitario
    ValorDescuento      DECIMAL(14,2) NOT NULL,           -- ValorBruto × %Desc / 100
    ValorNeto           DECIMAL(14,2) NOT NULL,           -- ValorBruto − ValorDescuento
    CostoTotal          DECIMAL(14,2) NOT NULL,           -- Cantidad × CostoUnitario
    Margen              DECIMAL(14,2) NOT NULL,           -- ValorNeto − CostoTotal
    ValorPaciente       DECIMAL(14,2) NOT NULL,           -- T7: prorrateo pagos EsAseguradora = 0
    ValorAseguradora    DECIMAL(14,2) NOT NULL,           -- T7: prorrateo pagos EsAseguradora = 1 (cartera)
    CONSTRAINT UQ_FACT_Atenciones_Detalle UNIQUE (DetalleID)
);

/* FACT_InteraccionCampana · grano: una interacción paciente–campaña
   (un documento ÚNICO de interacciones_campanas, después de T16). */
CREATE TABLE dbo.FACT_InteraccionCampana (
    InteraccionKey           BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    TiempoKey                INT NOT NULL REFERENCES dbo.DIM_Tiempo(TiempoKey),         -- T18: 1er evento en hora Colombia
    PacienteKey              INT NOT NULL REFERENCES dbo.DIM_Paciente(PacienteKey),     -- T19: -1 si no existe en OLTP
    CampanaKey               INT NOT NULL REFERENCES dbo.DIM_Campana(CampanaKey),
    CanalKey                 INT NOT NULL REFERENCES dbo.DIM_CanalContacto(CanalKey),
    -- Trazabilidad / degeneradas
    MongoId                  VARCHAR(24)  NOT NULL,       -- _id del documento conservado
    PacienteIdOrigen         INT          NOT NULL,       -- pacienteId tal como venía (para reportar los -1)
    Dispositivo              NVARCHAR(15) NOT NULL,
    FechaPrimerEvento        DATETIME2(0) NULL,           -- hora Colombia
    FechaClic                DATETIME2(0) NULL,           -- hora Colombia (insumo de T21)
    -- Banderas 0/1 (T17) y cumplimiento (T19)
    Enviado                  TINYINT NOT NULL,
    Entregado                TINYINT NOT NULL,
    Rebotado                 TINYINT NOT NULL,
    Abierto                  TINYINT NOT NULL,            -- abierto o leído
    Impresion                TINYINT NOT NULL,
    Clic                     TINYINT NOT NULL,
    BajaSuscripcion          TINYINT NOT NULL,
    CitaAgendada             TINYINT NOT NULL,
    EnviadoSinConsentimiento TINYINT NOT NULL,
    FueraDeSegmento          TINYINT NOT NULL,
    HorasHastaApertura       DECIMAL(10,2) NULL,          -- entregado → abierto/leído
    CONSTRAINT UQ_FACT_Interaccion_Mongo UNIQUE (MongoId)
);
GO

/* ════════════════ MIEMBROS DESCONOCIDOS (-1) ════════════════
   Se insertan al crear el DW para que toda FK tenga a dónde apuntar
   cuando falte el dato (orden externa, paciente inexistente, sin campaña…). */
INSERT INTO dbo.DIM_Tiempo (TiempoKey, NombreMes, NombreDia, NombreTrimestre) VALUES (-1, N'Desconocido', N'Desconocido', N'N/A');

SET IDENTITY_INSERT dbo.DIM_Paciente ON;
INSERT INTO dbo.DIM_Paciente (PacienteKey, PacienteID, TipoDocumento, NombreTipoDocumento, NumeroDocumento, NombreCompleto,
    Sexo, CursoVida, Ciudad, Departamento, Region, Pais, TienePerfil, OrigenRegistro, CanalPreferido,
    AceptaEmail, AceptaSMS, AceptaWhatsApp, LineasInteres, ProgramaRiesgo, NivelRiesgo, TipoNPS)
VALUES (-1, -1, 'N/A', N'Desconocido', 'N/A', N'Paciente desconocido', N'Sin dato', N'Desconocido',
    N'Desconocida', N'Desconocido', N'Desconocida', N'Desconocido', 0, N'Desconocido', N'Desconocido',
    0, 0, 0, N'', N'Sin programa', N'No aplica', N'Sin encuesta');
SET IDENTITY_INSERT dbo.DIM_Paciente OFF;

SET IDENTITY_INSERT dbo.DIM_Servicio ON;
INSERT INTO dbo.DIM_Servicio (ServicioKey, ServicioID, CodigoServicio, NombreServicio, TipoServicio, LineaServicio, Especialidad, EsQuirurgica, RangoTarifa)
VALUES (-1, -1, 'N/A', N'Servicio desconocido', N'Desconocido', N'Desconocida', N'Desconocida', 0, N'Desconocido');
SET IDENTITY_INSERT dbo.DIM_Servicio OFF;

SET IDENTITY_INSERT dbo.DIM_Sede ON;
INSERT INTO dbo.DIM_Sede (SedeKey, SedeID, NombreSede, TipoSede, Ciudad, Departamento, Region, Pais)
VALUES (-1, -1, N'Sede desconocida', N'Desconocido', N'Desconocida', N'Desconocido', N'Desconocida', N'Desconocido');
SET IDENTITY_INSERT dbo.DIM_Sede OFF;

SET IDENTITY_INSERT dbo.DIM_Profesional ON;
INSERT INTO dbo.DIM_Profesional (ProfesionalKey, ProfesionalID, RegistroMedico, NombreCompleto, Cargo, Especialidad, Sede)
VALUES (-1, -1, 'N/A', N'Sin profesional (orden externa)', N'No aplica', N'No aplica', N'No aplica');
SET IDENTITY_INSERT dbo.DIM_Profesional OFF;

SET IDENTITY_INSERT dbo.DIM_Aseguradora ON;
INSERT INTO dbo.DIM_Aseguradora (AseguradoraKey, AseguradoraID, NombreAseguradora, NIT, TipoAfiliacion)
VALUES (-1, -1, N'Aseguradora desconocida', 'N/A', N'Desconocido');
SET IDENTITY_INSERT dbo.DIM_Aseguradora OFF;

SET IDENTITY_INSERT dbo.DIM_Diagnostico ON;
INSERT INTO dbo.DIM_Diagnostico (DiagnosticoKey, DiagnosticoID, CodigoCIE10, Descripcion, Capitulo)
VALUES (-1, -1, 'N/A', N'Sin diagnóstico (orden externa)', N'No aplica');
SET IDENTITY_INSERT dbo.DIM_Diagnostico OFF;

SET IDENTITY_INSERT dbo.DIM_Modalidad ON;
INSERT INTO dbo.DIM_Modalidad (ModalidadKey, ModalidadID, Modalidad) VALUES (-1, -1, N'Desconocida');
SET IDENTITY_INSERT dbo.DIM_Modalidad OFF;

SET IDENTITY_INSERT dbo.DIM_Campana ON;
INSERT INTO dbo.DIM_Campana (CampanaKey, CampanaID, NombreCampana, Objetivo, Estado, Canales, LineasPromocionadas,
    SexoObjetivo, CodigoBeneficio, Responsable)
VALUES (-1, 'N/A', N'Sin campaña', N'No aplica', N'No aplica', N'', N'', N'Todos', N'Sin código', N'Sin asignar');
SET IDENTITY_INSERT dbo.DIM_Campana OFF;

SET IDENTITY_INSERT dbo.DIM_CanalContacto ON;
INSERT INTO dbo.DIM_CanalContacto (CanalKey, CodigoCanal, NombreCanal, RequiereConsentimiento) VALUES (-1, 'N/A', N'Desconocido', 0);
SET IDENTITY_INSERT dbo.DIM_CanalContacto OFF;
GO

/* Verificación: 12 tablas (10 DIM + 2 FACT), cada dimensión con su fila -1 */
SELECT t.name AS Tabla,
       (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0,1)) AS Filas
FROM sys.tables t
ORDER BY CASE WHEN t.name LIKE 'FACT%' THEN 1 ELSE 0 END, t.name;
GO
