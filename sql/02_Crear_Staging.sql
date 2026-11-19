/* ════════════════════════════════════════════════════════════════════
   SCRIPT 02 · Área de staging (esquema stg) dentro del DW
   1) Copia "tal cual" las tablas del OLTP que usa el ETL (extracción SQL).
   2) Crea las tablas crudas que llena mongo/extraer_mongo.py: un documento
      de MongoDB por fila, como JSON sin tocar. Así TODAS las reglas T11–T20
      se aplican y se ven en T-SQL (script 04), no en Python.
   3) Tabla de control con los conteos de origen (para la validación).
   Se ejecuta después de 01_Crear_DW.sql (base recién creada → stg vacío).
   ════════════════════════════════════════════════════════════════════ */
USE CLINICABI_DW_Grupo1;
GO
CREATE SCHEMA stg;
GO

/* ── Control de carga: filas leídas en cada origen y escritas en stg ── */
CREATE TABLE stg.ControlCarga (
    Fuente      NVARCHAR(20)  NOT NULL,     -- OLTP / MongoDB
    Objeto      NVARCHAR(60)  NOT NULL,     -- tabla o colección
    FilasOrigen INT           NOT NULL,
    FilasStg    INT           NOT NULL,
    FechaCarga  DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO

/* ════════════ 1) EXTRACCIÓN OLTP → stg (copia completa) ════════════ */
SELECT * INTO stg.oltp_Paises              FROM CLINICABI_OLTP.dbo.Paises;
SELECT * INTO stg.oltp_Regiones            FROM CLINICABI_OLTP.dbo.Regiones;
SELECT * INTO stg.oltp_Departamentos       FROM CLINICABI_OLTP.dbo.Departamentos;
SELECT * INTO stg.oltp_Ciudades            FROM CLINICABI_OLTP.dbo.Ciudades;
SELECT * INTO stg.oltp_TiposAfiliacion     FROM CLINICABI_OLTP.dbo.TiposAfiliacion;
SELECT * INTO stg.oltp_Aseguradoras        FROM CLINICABI_OLTP.dbo.Aseguradoras;
SELECT * INTO stg.oltp_Pacientes           FROM CLINICABI_OLTP.dbo.Pacientes;
SELECT * INTO stg.oltp_LineasServicio      FROM CLINICABI_OLTP.dbo.LineasServicio;
SELECT * INTO stg.oltp_TiposServicio       FROM CLINICABI_OLTP.dbo.TiposServicio;
SELECT * INTO stg.oltp_Especialidades      FROM CLINICABI_OLTP.dbo.Especialidades;
SELECT * INTO stg.oltp_Servicios           FROM CLINICABI_OLTP.dbo.Servicios;
SELECT * INTO stg.oltp_Diagnosticos        FROM CLINICABI_OLTP.dbo.Diagnosticos;
SELECT * INTO stg.oltp_ModalidadesAtencion FROM CLINICABI_OLTP.dbo.ModalidadesAtencion;
SELECT * INTO stg.oltp_Sedes               FROM CLINICABI_OLTP.dbo.Sedes;
SELECT * INTO stg.oltp_Cargos              FROM CLINICABI_OLTP.dbo.Cargos;
SELECT * INTO stg.oltp_Profesionales       FROM CLINICABI_OLTP.dbo.Profesionales;
SELECT * INTO stg.oltp_MediosPago          FROM CLINICABI_OLTP.dbo.MediosPago;
SELECT * INTO stg.oltp_EstadosAtencion     FROM CLINICABI_OLTP.dbo.EstadosAtencion;
SELECT * INTO stg.oltp_Atenciones          FROM CLINICABI_OLTP.dbo.Atenciones;
SELECT * INTO stg.oltp_DetalleAtencion     FROM CLINICABI_OLTP.dbo.DetalleAtencion;
SELECT * INTO stg.oltp_Pagos               FROM CLINICABI_OLTP.dbo.Pagos;

CREATE INDEX IX_stg_Detalle_Atencion ON stg.oltp_DetalleAtencion(AtencionID);
CREATE INDEX IX_stg_Pagos_Atencion   ON stg.oltp_Pagos(AtencionID);
CREATE INDEX IX_stg_Aten_Paciente    ON stg.oltp_Atenciones(PacienteID, FechaAtencion);

/* Conteos origen vs stg de las tablas transaccionales */
INSERT INTO stg.ControlCarga (Fuente, Objeto, FilasOrigen, FilasStg)
SELECT N'OLTP', N'Pacientes',       (SELECT COUNT(*) FROM CLINICABI_OLTP.dbo.Pacientes),       (SELECT COUNT(*) FROM stg.oltp_Pacientes)       UNION ALL
SELECT N'OLTP', N'Atenciones',      (SELECT COUNT(*) FROM CLINICABI_OLTP.dbo.Atenciones),      (SELECT COUNT(*) FROM stg.oltp_Atenciones)      UNION ALL
SELECT N'OLTP', N'DetalleAtencion', (SELECT COUNT(*) FROM CLINICABI_OLTP.dbo.DetalleAtencion), (SELECT COUNT(*) FROM stg.oltp_DetalleAtencion) UNION ALL
SELECT N'OLTP', N'Pagos',           (SELECT COUNT(*) FROM CLINICABI_OLTP.dbo.Pagos),           (SELECT COUNT(*) FROM stg.oltp_Pagos);
GO

/* ════════════ 2) TABLAS CRUDAS DE MONGODB (las llena Python) ════════════
   MongoId = _id del documento; Doc = documento completo SIN _id, en
   Extended JSON relajado (fechas como {"$date":"…Z"}, tipos originales:
   "3091" sigue siendo texto y 3091 número). Sin _id, dos duplicados exactos
   tienen el mismo Doc → T16 los detecta comparando Doc. */
CREATE TABLE stg.mongo_campanas (
    MongoId VARCHAR(30)   NOT NULL,          -- aquí el _id es el código CMP-AAAA-MM
    Doc     NVARCHAR(MAX) NOT NULL CHECK (ISJSON(Doc) = 1)
);
CREATE TABLE stg.mongo_perfiles_pacientes (
    MongoId VARCHAR(30)   NOT NULL,
    Doc     NVARCHAR(MAX) NOT NULL CHECK (ISJSON(Doc) = 1)
);
CREATE TABLE stg.mongo_interacciones_campanas (
    MongoId VARCHAR(30)   NOT NULL,
    Doc     NVARCHAR(MAX) NOT NULL CHECK (ISJSON(Doc) = 1)
);
GO

SELECT Fuente, Objeto, FilasOrigen, FilasStg FROM stg.ControlCarga;
GO
