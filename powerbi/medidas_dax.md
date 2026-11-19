# Power BI · BI_Grupo1.pbix — guía de armado y medidas DAX

El dashboard se conecta **solo** al DW `CLINICABI_DW_Grupo1` (nunca al OLTP ni a MongoDB).
Antes de empezar: correr `.\run_etl.ps1` para que el DW esté cargado.

---

## 1. Conexión y Power Query

1. *Archivo → Opciones → Configuración regional* (archivo actual): **Español (Colombia)** → formato de pesos `$ 1.234.567`.
2. *Obtener datos → SQL Server* · Servidor `localhost\SQLEXPRESS` · Base de datos `CLINICABI_DW_Grupo1` · modo **Importar**.
3. Marcar las 12 tablas del esquema `dbo`: las 10 `DIM_*` y las 2 `FACT_*`. **No** cargar las tablas de `stg` ni los reportes.
4. *Transformar datos* → tabla `DIM_Tiempo` → filtrar `TiempoKey` ≠ **-1**.
   Una tabla de fechas no admite fechas vacías, y ningún hecho usa el -1 de tiempo (la validación lo demuestra).
5. *Cerrar y aplicar*.

## 2. Modelo

**Relaciones:** todas son *varios a uno* (hecho → dimensión) con filtro cruzado **único**. Power BI las detecta por nombre de columna; revísalas en la vista Modelo.

| Desde (varios) | Hacia (uno) |
|---|---|
| FACT_Atenciones[TiempoKey] | DIM_Tiempo[TiempoKey] |
| FACT_Atenciones[PacienteKey] | DIM_Paciente[PacienteKey] |
| FACT_Atenciones[ServicioKey] | DIM_Servicio[ServicioKey] |
| FACT_Atenciones[SedeKey] | DIM_Sede[SedeKey] |
| FACT_Atenciones[ProfesionalKey] | DIM_Profesional[ProfesionalKey] |
| FACT_Atenciones[AseguradoraKey] | DIM_Aseguradora[AseguradoraKey] |
| FACT_Atenciones[DiagnosticoKey] | DIM_Diagnostico[DiagnosticoKey] |
| FACT_Atenciones[ModalidadKey] | DIM_Modalidad[ModalidadKey] |
| FACT_Atenciones[CampanaKey] | DIM_Campana[CampanaKey] (atribución T21) |
| FACT_InteraccionCampana[TiempoKey] | DIM_Tiempo[TiempoKey] |
| FACT_InteraccionCampana[PacienteKey] | DIM_Paciente[PacienteKey] |
| FACT_InteraccionCampana[CampanaKey] | DIM_Campana[CampanaKey] |
| FACT_InteraccionCampana[CanalKey] | DIM_CanalContacto[CanalKey] |

Borra cualquier otra relación que Power BI cree por su cuenta.

**Tabla de fechas:**
- Selecciona `DIM_Tiempo` → *Herramientas de tabla → Marcar como tabla de fechas* → columna `Fecha`.
- *Ordenar por columna*: `NombreMes` y `MesCorto` por `Mes`; `NombreDia` por `DiaSemana`.
- **Jerarquía** `Calendario`: clic derecho en `Anio` → *Crear jerarquía*, y agrega en este orden `NombreTrimestre` → `NombreMes` → `Dia`.

**Limpieza:**
- Oculta las columnas `*Key` de los hechos.
- Crea una tabla vacía `_Medidas` (*Especificar datos* → Cargar) y pon ahí todas las medidas.
- Formato: medidas de dinero en **Moneda $ Español (Colombia)** con 0 decimales; tasas en **Porcentaje** con 1 decimal.

## 3. Medidas DAX (32)

Cada medida va sola en *Nueva medida* (copiar sin los comentarios `--`). Cubren la rúbrica: **CALCULATE** (Año Anterior, Presupuesto, Facturación Atribuida, % Promotores), **DIVIDE** (todas las tasas y %), **inteligencia de tiempo** (SAMEPERIODLASTYEAR y DATEADD) y medidas que reutilizan otras (ROI, NPS, crecimientos).

```DAX
-- ═════════ Atenciones (páginas 1 y 2) ═════════
Facturación Neta = SUM ( FACT_Atenciones[ValorNeto] )
Margen = SUM ( FACT_Atenciones[Margen] )
Atenciones = DISTINCTCOUNT ( FACT_Atenciones[NumeroAtencion] )
Margen % = DIVIDE ( [Margen], [Facturación Neta] )
Pacientes Atendidos = DISTINCTCOUNT ( FACT_Atenciones[PacienteKey] )
Cartera Aseguradora = SUM ( FACT_Atenciones[ValorAseguradora] )
Valor Promedio por Atención = DIVIDE ( [Facturación Neta], [Atenciones] )
Facturación Año Anterior = CALCULATE ( [Facturación Neta], SAMEPERIODLASTYEAR ( DIM_Tiempo[Fecha] ) )
Crecimiento Facturación % = DIVIDE ( [Facturación Neta] - [Facturación Año Anterior], [Facturación Año Anterior] )
Margen Año Anterior = CALCULATE ( [Margen], SAMEPERIODLASTYEAR ( DIM_Tiempo[Fecha] ) )
Crecimiento Margen % = DIVIDE ( [Margen] - [Margen Año Anterior], [Margen Año Anterior] )
Atenciones Año Anterior = CALCULATE ( [Atenciones], DATEADD ( DIM_Tiempo[Fecha], -1, YEAR ) )
Crecimiento Atenciones % = DIVIDE ( [Atenciones] - [Atenciones Año Anterior], [Atenciones Año Anterior] )
Atenciones x Paciente = DIVIDE ( [Atenciones], [Pacientes Atendidos] )

-- ═════════ Campañas y experiencia (página 3) ═════════
Contactos = COUNTROWS ( FACT_InteraccionCampana )            -- 1 fila = 1 documento único
Enviados = SUM ( FACT_InteraccionCampana[Enviado] )
Entregados = SUM ( FACT_InteraccionCampana[Entregado] )
Abiertos = SUM ( FACT_InteraccionCampana[Abierto] )
Clics = SUM ( FACT_InteraccionCampana[Clic] )
Citas Agendadas = SUM ( FACT_InteraccionCampana[CitaAgendada] )
Tasa Apertura = DIVIDE ( [Abiertos], [Entregados] )
Tasa Clic = DIVIDE ( [Clics], [Contactos] )                    -- base contactos: app no tiene "entregado"
Tasa Cita = DIVIDE ( [Citas Agendadas], [Contactos] )
Presupuesto = CALCULATE ( SUM ( DIM_Campana[Presupuesto] ), DIM_Campana[CampanaKey] <> -1 )
Costo por Clic = DIVIDE ( [Presupuesto], [Clics] )
Costo por Cita = DIVIDE ( [Presupuesto], [Citas Agendadas] )
Facturación Atribuida = CALCULATE ( [Facturación Neta], FACT_Atenciones[CampanaKey] <> -1 )   -- T21
ROI Campaña = DIVIDE ( [Facturación Atribuida] - [Presupuesto], [Presupuesto] )
% Sin Consentimiento = DIVIDE ( SUM ( FACT_InteraccionCampana[EnviadoSinConsentimiento] ), [Contactos] )
% Fuera de Segmento = DIVIDE ( SUM ( FACT_InteraccionCampana[FueraDeSegmento] ), [Contactos] )
% Promotores = DIVIDE ( CALCULATE ( COUNTROWS ( DIM_Paciente ), DIM_Paciente[TipoNPS] = "Promotor" ),
               CALCULATE ( COUNTROWS ( DIM_Paciente ), DIM_Paciente[TipoNPS] <> "Sin encuesta" ) )
% Detractores = DIVIDE ( CALCULATE ( COUNTROWS ( DIM_Paciente ), DIM_Paciente[TipoNPS] = "Detractor" ),
                           CALCULATE ( COUNTROWS ( DIM_Paciente ), DIM_Paciente[TipoNPS] <> "Sin encuesta" ) )
NPS = ( [% Promotores] - [% Detractores] ) * 100
```

Notas para la sustentación:
- **El presupuesto es de la campaña, no del canal.** Por eso el costo por clic, el costo por cita y el ROI se muestran **por campaña**.
- **El embudo de app empieza en Impresión**, porque app no tiene evento "enviado" (es el problema M16 del reporte de calidad).
- **El NPS se calcula por paciente**, con el perfil vigente (T15); el segmentador de año no lo filtra.

## 4. Páginas

Usa el mismo tema en las 3 páginas (*Vista → Temas*, por ejemplo "Ejecutivo"). Cada título debe decir el hallazgo; abajo van sugerencias con las cifras de control de `docs/preguntas_negocio.sql`.

**Segmentadores:**

| Segmentador | Columna | Páginas |
|---|---|---|
| Año | `DIM_Tiempo[Anio]` | 1, 2, 3 (en la 1, deja **2025** seleccionado para que el crecimiento compare contra 2024) |
| Región | `DIM_Sede[Region]` | 1, 2 |
| Línea de servicio | `DIM_Servicio[LineaServicio]` | 1, 2 |
| Modalidad | `DIM_Modalidad[Modalidad]` | 1, 2 |
| Canal de contacto | `DIM_CanalContacto[NombreCanal]` | 3 |

Para que un segmentador aplique a varias páginas: *Vista → Sincronizar segmentaciones*.

En las tablas y gráficos de campañas, diagnósticos y profesionales, excluye el miembro -1 con el panel de filtros: "Sin campaña", "Sin diagnóstico (orden externa)", "Sin profesional (orden externa)".

### Página 1 · Resumen ejecutivo
- **Tarjetas:** Facturación Neta, Margen %, Atenciones, Pacientes Atendidos, Valor Promedio por Atención, Crecimiento Facturación %.
- **Facturación mensual 2025 frente a 2024:** gráfico de líneas. Eje `DIM_Tiempo[MesCorto]`, leyenda `DIM_Tiempo[Anio]`, valores Facturación Neta. Usa la jerarquía para el drill-down.
  - Título: **"La facturación creció 13,5 % en 2025 ($4.315 M frente a $3.801 M) y el margen 13,3 %, estable en 36 %"**
- **Atenciones por modalidad:** columnas agrupadas con Atenciones y Crecimiento Atenciones % (P3).
  - Título: **"Telemedicina es la modalidad que más crece: +73 % de atenciones y +88 % de facturación"**

### Página 2 · Pacientes, servicios y territorio
- **Facturación por región → departamento → sede:** mapa de árbol o barras con drill-down.
  - Título: **"La región Andina concentra el 76 % de la facturación"**
- **Facturación por línea y especialidad:** barras.
  - Título: **"Consulta externa (23,5 %) y Cirugía ambulatoria (21 %) concentran casi la mitad de la facturación"**
- **Facturación por curso de vida y sexo:** columnas apiladas (`CursoVida` × `Sexo`).
- **Margen y cartera por aseguradora y tipo de afiliación:** matriz (`TipoAfiliacion` → `NombreAseguradora`) con Margen, Margen % y Cartera Aseguradora.
  - Título: **"Medicina prepagada deja el mejor margen (47,6 %); Salud Andina y Nueva Vida concentran el 49 % de la cartera"**
- **Top 10 diagnósticos:** barras con `DIM_Diagnostico[Descripcion]` y filtro *N superior* = 10 por Atenciones.
- **Atenciones por paciente según programa y nivel de riesgo:** matriz (`ProgramaRiesgo`, `NivelRiesgo`) con Atenciones x Paciente.
  - Título: **"Los pacientes en programa de riesgo consultan 21 % más (9,4 frente a 7,8 atenciones); con riesgo alto, 11,5"**

### Página 3 · Campañas y experiencia
- **Embudo:** visual *Embudo* con Enviados → Entregados → Abiertos → Clics → Citas Agendadas.
- **Tasas por canal:** columnas agrupadas con Tasa Apertura, Tasa Clic y Tasa Cita.
  - Título: **"WhatsApp convierte 2,6 veces más que el email: 8,4 % de los contactos terminan en cita"**
- **Tasas por campaña:** tabla con Tasa Apertura, Tasa Clic, Tasa Cita, Costo por Clic y Costo por Cita.
- **Facturación atribuida y ROI por campaña:** columnas con Facturación Atribuida y Presupuesto, más una línea con ROI Campaña.
  - Título: **"La Semana de la salud 2025 multiplicó por 2,6 la facturación atribuida ($21,9 M frente a $8,4 M) y casi recupera su inversión (ROI −2,6 % frente a −53,4 %)"**
- **NPS:** tarjeta con NPS y anillo con `TipoNPS`. Cifra de control: NPS **2,3** (30,7 % promotores − 28,4 % detractores).
- **Cumplimiento:** tarjetas % Sin Consentimiento y % Fuera de Segmento, más barras por campaña.
  - Título: **"1.096 envíos (3 %) sin consentimiento y 216 fuera de segmento, concentrados en Octubre rosa y Corazón sano"**

## 5. Cifras de control (para verificar el dashboard)

| Dato | Valor esperado |
|---|---|
| Facturación 2024 / 2025 | $3.801.206.340 / $4.314.847.360 (+13,5 %) |
| Margen % 2024 / 2025 | 36,30 % / 36,23 % |
| Atenciones 2024 / 2025 | 23.686 / 26.906 |
| Contactos de campaña / citas agendadas | 36.073 / 1.662 |
| Facturación atribuida total | $62.174.625 |
| NPS | 2,3 |

Guardar como `powerbi/BI_Grupo1.pbix`.
