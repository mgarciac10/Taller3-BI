/* ════════════════════════════════════════════════════════════════════
   TALLER BI CLÍNICA · SCRIPT 01
   Creación de la base de datos OPERACIONAL (OLTP) – CLINICABI_OLTP
   Modelo relacional normalizado (3FN) de una red de IPS ambulatorias
   en Colombia (consulta externa, apoyo diagnóstico, odontología,
   promoción y prevención y cirugía ambulatoria).
   Motor: SQL Server Express 2019 / 2022
   Todos los datos son ficticios.
   ════════════════════════════════════════════════════════════════════ */

USE master;
GO

/* Si la base ya existe, se elimina para empezar desde cero */
IF DB_ID(N'CLINICABI_OLTP') IS NOT NULL
BEGIN
    ALTER DATABASE CLINICABI_OLTP SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE CLINICABI_OLTP;
END
GO

CREATE DATABASE CLINICABI_OLTP;
GO

USE CLINICABI_OLTP;
GO

/* ════════════════════════════════════════════
   1. GEOGRAFÍA  (País → Región → Departamento → Ciudad)
   ════════════════════════════════════════════ */
CREATE TABLE Paises (
    PaisID        INT IDENTITY(1,1) PRIMARY KEY,
    Nombre        NVARCHAR(60) NOT NULL UNIQUE,
    CodigoISO     CHAR(2)      NOT NULL UNIQUE
);

CREATE TABLE Regiones (
    RegionID      INT IDENTITY(1,1) PRIMARY KEY,
    Nombre        NVARCHAR(60) NOT NULL,
    PaisID        INT NOT NULL FOREIGN KEY REFERENCES Paises(PaisID)
);

CREATE TABLE Departamentos (
    DepartamentoID INT IDENTITY(1,1) PRIMARY KEY,
    Nombre         NVARCHAR(60) NOT NULL,
    RegionID       INT NOT NULL FOREIGN KEY REFERENCES Regiones(RegionID)
);

CREATE TABLE Ciudades (
    CiudadID       INT IDENTITY(1,1) PRIMARY KEY,
    Nombre         NVARCHAR(60) NOT NULL,
    DepartamentoID INT NOT NULL FOREIGN KEY REFERENCES Departamentos(DepartamentoID)
);

/* ════════════════════════════════════════════
   2. PACIENTES Y ASEGURAMIENTO
      TipoAfiliacion → Aseguradora → Paciente
   ════════════════════════════════════════════ */
CREATE TABLE TiposAfiliacion (
    TipoAfiliacionID  INT IDENTITY(1,1) PRIMARY KEY,
    Nombre            NVARCHAR(40)  NOT NULL UNIQUE,      -- Contributivo, Subsidiado, Prepagada...
    PorcentajeCopago  DECIMAL(5,2)  NOT NULL,             -- % que paga el paciente (copago / cuota moderadora)
    FactorTarifa      DECIMAL(4,2)  NOT NULL,             -- tarifa pactada = tarifa plena × factor
    Descripcion       NVARCHAR(150) NULL
);

CREATE TABLE Aseguradoras (
    AseguradoraID     INT IDENTITY(1,1) PRIMARY KEY,
    Nombre            NVARCHAR(100) NOT NULL UNIQUE,
    NIT               VARCHAR(15)   NOT NULL UNIQUE,
    TipoAfiliacionID  INT NOT NULL FOREIGN KEY REFERENCES TiposAfiliacion(TipoAfiliacionID),
    DiasPagoPactados  INT NOT NULL DEFAULT 60           -- plazo de pago de las cuentas
);

CREATE TABLE Pacientes (
    PacienteID        INT IDENTITY(1,1) PRIMARY KEY,
    TipoDocumento     VARCHAR(3)    NOT NULL CHECK (TipoDocumento IN ('CC','TI','RC','CE','PA')),
    NumeroDocumento   VARCHAR(20)   NOT NULL UNIQUE,
    Nombres           NVARCHAR(100) NOT NULL,
    Apellidos         NVARCHAR(100) NOT NULL,
    Sexo              CHAR(1)       NULL CHECK (Sexo IN ('F','M')),   -- NULL = sin dato
    FechaNacimiento   DATE          NOT NULL,
    Email             VARCHAR(120)  NULL,
    Telefono          VARCHAR(20)   NULL,
    Direccion         NVARCHAR(150) NULL,
    AseguradoraID     INT NOT NULL FOREIGN KEY REFERENCES Aseguradoras(AseguradoraID),
    CiudadID          INT NOT NULL FOREIGN KEY REFERENCES Ciudades(CiudadID),
    FechaRegistro     DATE NOT NULL,
    Activo            BIT  NOT NULL DEFAULT 1,
    FechaCreacion     DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),   -- auditoría (ETL incremental)
    FechaModificacion DATETIME2(0) NULL
);

/* ════════════════════════════════════════════
   3. PORTAFOLIO DE SERVICIOS
      LíneaServicio → TipoServicio → Servicio (+ Especialidad)
   ════════════════════════════════════════════ */
CREATE TABLE LineasServicio (
    LineaID       INT IDENTITY(1,1) PRIMARY KEY,
    Nombre        NVARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE TiposServicio (
    TipoServicioID INT IDENTITY(1,1) PRIMARY KEY,
    Nombre         NVARCHAR(60) NOT NULL,
    LineaID        INT NOT NULL FOREIGN KEY REFERENCES LineasServicio(LineaID),
    TarifaMin      DECIMAL(12,2) NOT NULL,   -- rango de tarifas de referencia (COP)
    TarifaMax      DECIMAL(12,2) NOT NULL
);

CREATE TABLE Especialidades (
    EspecialidadID INT IDENTITY(1,1) PRIMARY KEY,
    Nombre         NVARCHAR(60) NOT NULL UNIQUE,
    EsQuirurgica   BIT NOT NULL DEFAULT 0
);

CREATE TABLE Servicios (
    ServicioID        INT IDENTITY(1,1) PRIMARY KEY,
    CodigoServicio    VARCHAR(20)   NOT NULL UNIQUE,     -- código interno estilo CUPS
    Nombre            NVARCHAR(150) NOT NULL,
    TipoServicioID    INT NOT NULL FOREIGN KEY REFERENCES TiposServicio(TipoServicioID),
    EspecialidadID    INT NOT NULL FOREIGN KEY REFERENCES Especialidades(EspecialidadID),
    CostoUnitario     DECIMAL(12,2) NOT NULL,
    Tarifa            DECIMAL(12,2) NOT NULL,            -- tarifa plena (particular)
    Activo            BIT NOT NULL DEFAULT 1,
    FechaCreacion     DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    FechaModificacion DATETIME2(0) NULL,
    CONSTRAINT CK_Servicios_Tarifa CHECK (Tarifa >= CostoUnitario)
);

CREATE TABLE Diagnosticos (
    DiagnosticoID  INT IDENTITY(1,1) PRIMARY KEY,
    CodigoCIE10    VARCHAR(6)    NOT NULL UNIQUE,
    Descripcion    NVARCHAR(150) NOT NULL,
    Capitulo       NVARCHAR(100) NOT NULL
);

/* ════════════════════════════════════════════
   4. ORGANIZACIÓN  (Modalidades, Sedes, Profesionales)
   ════════════════════════════════════════════ */
CREATE TABLE ModalidadesAtencion (
    ModalidadID   INT IDENTITY(1,1) PRIMARY KEY,
    Nombre        NVARCHAR(40) NOT NULL UNIQUE           -- Presencial, Telemedicina, Domiciliaria, Extramural
);

CREATE TABLE Sedes (
    SedeID        INT IDENTITY(1,1) PRIMARY KEY,
    Nombre        NVARCHAR(80) NOT NULL,
    TipoSede      NVARCHAR(20) NOT NULL CHECK (TipoSede IN (N'Física', N'Virtual')),
    CiudadID      INT NOT NULL FOREIGN KEY REFERENCES Ciudades(CiudadID),
    Direccion     NVARCHAR(150) NULL,
    NumeroConsultorios INT NOT NULL DEFAULT 0,
    FechaApertura DATE NOT NULL
);

CREATE TABLE Cargos (
    CargoID       INT IDENTITY(1,1) PRIMARY KEY,
    Nombre        NVARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE Profesionales (
    ProfesionalID    INT IDENTITY(1,1) PRIMARY KEY,
    NumeroDocumento  VARCHAR(20)   NOT NULL UNIQUE,
    RegistroMedico   VARCHAR(20)   NOT NULL UNIQUE,      -- registro profesional (ReTHUS)
    Nombres          NVARCHAR(100) NOT NULL,
    Apellidos        NVARCHAR(100) NOT NULL,
    CargoID          INT NOT NULL FOREIGN KEY REFERENCES Cargos(CargoID),
    EspecialidadID   INT NOT NULL FOREIGN KEY REFERENCES Especialidades(EspecialidadID),
    SedeID           INT NOT NULL FOREIGN KEY REFERENCES Sedes(SedeID),
    FechaIngreso     DATE NOT NULL,
    Activo           BIT  NOT NULL DEFAULT 1
);

/* ════════════════════════════════════════════
   5. TRANSACCIONES  (Atenciones, Detalle, Pagos)
   ════════════════════════════════════════════ */
CREATE TABLE MediosPago (
    MedioPagoID   INT IDENTITY(1,1) PRIMARY KEY,
    Nombre        NVARCHAR(40) NOT NULL UNIQUE,
    EsAseguradora BIT NOT NULL DEFAULT 0                 -- 1 = cuenta por cobrar a la aseguradora
);

CREATE TABLE EstadosAtencion (
    EstadoID      INT IDENTITY(1,1) PRIMARY KEY,
    Nombre        NVARCHAR(30) NOT NULL UNIQUE           -- Realizada, Cancelada, Inasistencia
);

CREATE TABLE Atenciones (
    AtencionID      INT IDENTITY(1,1) PRIMARY KEY,
    NumeroAtencion  VARCHAR(20) NULL UNIQUE,             -- se asigna al cargar (ATN-0000001)
    PacienteID      INT NOT NULL FOREIGN KEY REFERENCES Pacientes(PacienteID),
    SedeID          INT NOT NULL FOREIGN KEY REFERENCES Sedes(SedeID),
    ProfesionalID   INT NULL     FOREIGN KEY REFERENCES Profesionales(ProfesionalID),  -- NULL si llega con orden externa
    ModalidadID     INT NOT NULL FOREIGN KEY REFERENCES ModalidadesAtencion(ModalidadID),
    EstadoID        INT NOT NULL FOREIGN KEY REFERENCES EstadosAtencion(EstadoID),
    DiagnosticoID   INT NULL     FOREIGN KEY REFERENCES Diagnosticos(DiagnosticoID),   -- diagnóstico principal
    AseguradoraID   INT NOT NULL FOREIGN KEY REFERENCES Aseguradoras(AseguradoraID),   -- quién respondía al momento de la atención
    OrdenExterna    BIT NOT NULL DEFAULT 0,              -- 1 = el paciente trae la orden de otro prestador
    FechaAtencion   DATETIME2(0) NOT NULL,
    FechaCreacion   DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE DetalleAtencion (
    DetalleID           INT IDENTITY(1,1) PRIMARY KEY,
    AtencionID          INT NOT NULL FOREIGN KEY REFERENCES Atenciones(AtencionID),
    ServicioID          INT NOT NULL FOREIGN KEY REFERENCES Servicios(ServicioID),
    Cantidad            INT NOT NULL CHECK (Cantidad > 0),
    ValorUnitario       DECIMAL(12,2) NOT NULL,     -- tarifa cobrada en ese momento
    CostoUnitario       DECIMAL(12,2) NOT NULL,     -- costo en ese momento
    PorcentajeDescuento DECIMAL(5,2)  NOT NULL DEFAULT 0 CHECK (PorcentajeDescuento BETWEEN 0 AND 100),
    CONSTRAINT UQ_Detalle_Atencion_Servicio UNIQUE (AtencionID, ServicioID)
);

CREATE TABLE Pagos (
    PagoID        INT IDENTITY(1,1) PRIMARY KEY,
    AtencionID    INT NOT NULL FOREIGN KEY REFERENCES Atenciones(AtencionID),
    MedioPagoID   INT NOT NULL FOREIGN KEY REFERENCES MediosPago(MedioPagoID),
    FechaPago     DATETIME2(0) NOT NULL,
    Valor         DECIMAL(14,2) NOT NULL CHECK (Valor >= 0),
    NumeroCuotas  INT NOT NULL DEFAULT 1
);

/* Índices de apoyo para las consultas y el ETL */
CREATE INDEX IX_Atenciones_Fecha     ON Atenciones(FechaAtencion);
CREATE INDEX IX_Atenciones_Paciente  ON Atenciones(PacienteID);
CREATE INDEX IX_Detalle_Atencion     ON DetalleAtencion(AtencionID);
CREATE INDEX IX_Detalle_Servicio     ON DetalleAtencion(ServicioID);
CREATE INDEX IX_Pagos_Atencion       ON Pagos(AtencionID);
GO

/* Verificación: deben aparecer 21 tablas */
SELECT TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME;
GO
