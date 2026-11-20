"""Genera el documento técnico (≤ 12 páginas) en Word.
Uso: python docs/generar_diagramas.py && python docs/generar_documento.py
Salida: docs/Documento_Tecnico_BI_Grupo1.docx
Las cifras salen de la última ejecución de run_etl.ps1 (sección 07 Validación)
y de docs/preguntas_negocio.sql."""
import os
from docx import Document
from docx.enum.section import WD_ORIENT
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

BASE = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(BASE)
IMG = os.path.join(BASE, "img")
CAP = os.path.join(RAIZ, "evidencias", "capturas")
SALIDA = os.path.join(BASE, "Documento_Tecnico_BI_Grupo1.docx")
AZUL = RGBColor(0x1F, 0x4E, 0x79)

doc = Document()
sec = doc.sections[0]
sec.page_width, sec.page_height = Cm(21.59), Cm(27.94)          # carta
sec.left_margin = sec.right_margin = Cm(2.0)
sec.top_margin = sec.bottom_margin = Cm(1.8)

st = doc.styles["Normal"]
st.font.name = "Calibri"; st.font.size = Pt(10)
st.element.rPr.rFonts.set(qn("w:eastAsia"), "Calibri")
st.paragraph_format.space_after = Pt(4)
st.paragraph_format.line_spacing = 1.08
for nombre, tam in (("Heading 1", 14), ("Heading 2", 11.5)):
    h = doc.styles[nombre]
    h.font.name = "Calibri"; h.font.size = Pt(tam); h.font.bold = True; h.font.color.rgb = AZUL
    h.element.rPr.rFonts.set(qn("w:asciiTheme"), "") if False else None
    rf = h.element.rPr.find(qn("w:rFonts"))
    if rf is None:
        rf = OxmlElement("w:rFonts"); h.element.rPr.append(rf)
    for a in ("w:ascii", "w:hAnsi", "w:cs"):
        rf.set(qn(a), "Calibri")
    for a in ("w:asciiTheme", "w:hAnsiTheme", "w:cstheme"):
        if rf.get(qn(a)) is not None:
            del rf.attrib[qn(a)]
    h.paragraph_format.space_before = Pt(10 if nombre == "Heading 1" else 6)
    h.paragraph_format.space_after = Pt(4)
    h.paragraph_format.keep_with_next = True
lb = doc.styles["List Bullet"]
lb.font.name = "Calibri"; lb.font.size = Pt(10)
lb.paragraph_format.space_after = Pt(2)

# pie de página con número
pie = sec.footer.paragraphs[0]
pie.alignment = WD_ALIGN_PARAGRAPH.RIGHT
r = pie.add_run("Trabajo Final BI · Grupo 1 · pág. "); r.font.size = Pt(8)
for tipo, txt in (("begin", None), (None, "PAGE"), ("end", None)):
    run = pie.add_run(); run.font.size = Pt(8)
    if tipo:
        fc = OxmlElement("w:fldChar"); fc.set(qn("w:fldCharType"), tipo); run._r.append(fc)
    else:
        it = OxmlElement("w:instrText"); it.set(qn("xml:space"), "preserve"); it.text = txt; run._r.append(it)


def h1(t): doc.add_heading(t, level=1)
def h2(t): doc.add_heading(t, level=2)


def p(texto, negrita_inicio=None, size=None, italic=False, align=None):
    par = doc.add_paragraph()
    if negrita_inicio:
        rr = par.add_run(negrita_inicio); rr.bold = True
        if size: rr.font.size = Pt(size)
    rr = par.add_run(texto); rr.italic = italic
    if size: rr.font.size = Pt(size)
    if align: par.alignment = align
    return par


def bullets(items):
    for it in items:
        par = doc.add_paragraph(style="List Bullet")
        if isinstance(it, tuple):
            par.add_run(it[0]).bold = True; par.add_run(it[1])
        else:
            par.add_run(it)


def sombrear(celda, color):
    tcPr = celda._tc.get_or_add_tcPr()
    sh = OxmlElement("w:shd"); sh.set(qn("w:val"), "clear"); sh.set(qn("w:color"), "auto"); sh.set(qn("w:fill"), color)
    tcPr.append(sh)


def tabla(filas, anchos, size=8, encabezado=True, alinear_der=()):
    t = doc.add_table(rows=len(filas), cols=len(filas[0]))
    t.style = "Table Grid"; t.alignment = WD_TABLE_ALIGNMENT.CENTER; t.autofit = False
    for i, fila in enumerate(filas):
        for j, valor in enumerate(fila):
            c = t.cell(i, j); c.width = Cm(anchos[j])
            c.paragraphs[0].paragraph_format.space_after = Pt(0)
            c.paragraphs[0].paragraph_format.line_spacing = 1.0
            rr = c.paragraphs[0].add_run(str(valor)); rr.font.size = Pt(size)
            if j in alinear_der and i > 0:
                c.paragraphs[0].alignment = WD_ALIGN_PARAGRAPH.RIGHT
            if encabezado and i == 0:
                rr.bold = True; rr.font.color.rgb = RGBColor(0xFF, 0xFF, 0xFF); sombrear(c, "1F4E79")
    # repetir encabezado si la tabla salta de página
    if encabezado:
        trPr = t.rows[0]._tr.get_or_add_trPr()
        th = OxmlElement("w:tblHeader"); th.set(qn("w:val"), "true"); trPr.append(th)
    doc.add_paragraph().paragraph_format.space_after = Pt(0)
    return t


def figura(ruta, ancho_cm, pie_txt):
    doc.add_picture(ruta, width=Cm(ancho_cm))
    doc.paragraphs[-1].alignment = WD_ALIGN_PARAGRAPH.CENTER
    par = p(pie_txt, size=8.5, italic=True, align=WD_ALIGN_PARAGRAPH.CENTER)
    par.paragraph_format.space_after = Pt(6)


# ═════════════════════════ PORTADA (encabezado) ═════════════════════════
t = doc.add_paragraph(); t.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = t.add_run("Área de Inteligencia de Negocios · Red Médica Altavista IPS"); r.bold = True; r.font.size = Pt(17); r.font.color.rgb = AZUL
t = doc.add_paragraph(); t.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = t.add_run("Documento técnico · Trabajo Final BI · Bases de Datos Avanzadas"); r.font.size = Pt(11)
t = doc.add_paragraph(); t.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = t.add_run("Grupo 1 · Integrantes: Mateo García Carreño y Moisés Vergara Garcés · Noviembre de 2026"); r.font.size = Pt(10)

h1("1. Objetivo y alcance")
p("Se construyó un área de BI que integra las dos fuentes de la red: la base transaccional en SQL Server "
  "(CLINICABI_OLTP: pacientes, atenciones, servicios, pagos) y la base documental en MongoDB (clinica_bi: "
  "campañas, perfiles de pacientes e interacciones). Ambas se unen por el identificador del paciente y se cargan "
  "en un Data Warehouse en estrella (CLINICABI_DW_Grupo1) con dos hechos y diez dimensiones. Sobre el DW se "
  "construyó un dashboard de Power BI de tres páginas que responde las ocho preguntas de negocio. "
  "Todo el proceso corre desde una base vacía con un solo comando (run_etl.ps1) y termina con un script de "
  "validación que demuestra que ningún registro se pierde sin explicación.")

# ═════════════════════════ 2. ARQUITECTURA ═════════════════════════
h1("2. Arquitectura del área de BI")
figura(os.path.join(IMG, "arquitectura.png"), 17.0, "Figura 1. Arquitectura: fuentes → staging → transformación T-SQL → DW estrella → Power BI.")
bullets([
    ("Fuentes. ", "CLINICABI_OLTP (21 tablas) y clinica_bi (24 campañas, 5.215 perfiles, 36.313 interacciones). No se modifican."),
    ("Staging (esquema stg). ", "stg.oltp_* es una copia 1:1 de las tablas del OLTP. stg.mongo_* guarda cada documento "
     "crudo (MongoId + Doc en JSON, con sus tipos originales). Así las reglas se aplican y auditan en un solo lugar (T-SQL) "
     "y la fuente no se vuelve a consultar durante la transformación. stg.ControlCarga registra los conteos de cada paso."),
    ("Transformación. ", "Scripts T-SQL numerados. Los documentos JSON se desanidan con OPENJSON. Cada regla está "
     "comentada en el script con su código Tx y el porqué."),
    ("DW y consumo. ", "Esquema estrella con miembro -1 en cada dimensión. Power BI se conecta solo al DW (modo importación)."),
])
h2("2.1 Orden de ejecución (run_etl.ps1)")
tabla([
    ["Paso", "Archivo", "Qué hace"],
    ["1", "sql/01_Crear_DW.sql", "Borra y crea CLINICABI_DW_Grupo1, los esquemas dbo y stg, las 12 tablas del modelo e inserta los miembros -1"],
    ["2", "sql/02_Crear_Staging.sql", "Crea las tablas stg y copia el OLTP (stg.oltp_*)"],
    ["3", "mongo/extraer_mongo.py", "Extrae las 3 colecciones de MongoDB a stg.mongo_* (crudo, sin transformar)"],
    ["4", "sql/03_ETL_Dimensiones.sql", "T1–T5 y T10: DIM_Tiempo, Paciente (parte OLTP), Servicio, Sede, Profesional, Aseguradora, Diagnóstico, Modalidad, Canal"],
    ["5", "sql/04_ETL_Mongo_Transform.sql", "T11–T15 (perfil vigente → DIM_Paciente) y T20 (DIM_Campana)"],
    ["6", "sql/05_ETL_Hechos.sql", "T6–T9 (FACT_Atenciones) y T16–T19 (FACT_InteraccionCampana)"],
    ["7", "sql/06_Atribucion_T21.sql", "T21: asigna la campaña atribuida en FACT_Atenciones.CampanaKey"],
    ["8", "sql/07_Validacion.sql", "Conteos, cuadre de dinero, uso de -1, tasas T6, ReporteCalidad y ReporteCumplimiento"],
], [1.2, 5.0, 11.3])
p("Método de extracción de MongoDB: script de Python con pymongo + pyodbc. ", None)
doc.paragraphs[-1].runs[0].bold = True
doc.paragraphs[-1].add_run(
    "Se eligió porque es reproducible con un solo comando, no deja archivos intermedios ni depende de rutas que el "
    "servicio de SQL Server deba poder leer (problema típico de BULK INSERT/OPENROWSET), lee la base viva y es "
    "re-ejecutable (TRUNCATE antes de cargar). El script no corrige nada: guarda el documento completo en JSON relajado "
    "(los números y textos conservan su tipo; las fechas llegan como {\"$date\": …}), y todas las reglas T11–T20 se "
    "aplican después en T-SQL, donde quedan visibles y auditables. Ejecución completa medida: ≈ 15 s.")

# ═════════════════════════ 3. MODELO ═════════════════════════
h1("3. Modelo dimensional")
figura(os.path.join(IMG, "modelo_estrella.png"), 16.5, "Figura 2. Modelo estrella de CLINICABI_DW_Grupo1 (filas cargadas entre paréntesis, incluido el miembro -1).")
h2("3.1 Granularidad")
tabla([
    ["Tabla", "Una fila por…", "Filas", "Origen"],
    ["FACT_Atenciones", "servicio prestado (línea de DetalleAtencion) en una atención en estado Realizada", "82.448", "OLTP + campaña atribuida (T21)"],
    ["FACT_InteraccionCampana", "interacción paciente–campaña: documento único de interacciones_campanas (tras quitar duplicados, T16)", "36.073", "MongoDB"],
    ["DIM_Tiempo", "día (clave AAAAMMDD), 2024-01-01 a 2025-12-31", "731 + 1", "Generada (T10)"],
    ["DIM_Paciente", "paciente", "6.000 + 1", "OLTP + perfil vigente Mongo"],
    ["DIM_Servicio / Sede / Profesional", "servicio / sede / profesional", "99 / 15 / 347 (+1)", "OLTP"],
    ["DIM_Aseguradora / Diagnóstico / Modalidad", "pagador / código CIE-10 / modalidad", "9 / 33 / 4 (+1)", "OLTP"],
    ["DIM_Campana / DIM_CanalContacto", "campaña / canal (email, sms, whatsapp, app)", "24 / 4 (+1)", "MongoDB / catálogo T16"],
], [4.2, 7.3, 2.4, 3.6], alinear_der=(2,))
h2("3.2 Reglas de diseño")
bullets([
    ("Claves sustitutas y naturales. ", "Cada dimensión tiene …Key (IDENTITY) y la clave natural de la fuente (PacienteID, "
     "ServicioID, CampanaID, CodigoCanal…) para rastrear cada fila. DIM_Tiempo usa la clave AAAAMMDD."),
    ("Miembro desconocido -1 ", "en las diez dimensiones, insertado al crear el DW. Se usa en orden externa sin profesional "
     "ni diagnóstico (T8), pacienteId de Mongo inexistente en el OLTP (T19) y atención sin campaña atribuida (T21)."),
    ("Dimensiones conformadas: ", "DIM_Tiempo, DIM_Paciente y DIM_Campana las comparten ambos hechos, lo que permite cruzar "
     "facturación atribuida con presupuesto y conversiones en un mismo visual."),
    ("Dimensiones degeneradas ", "en los hechos: NumeroAtencion, MedioPagoPrincipal, OrdenExterna (atenciones) y MongoId "
     "(interacciones). Son atributos de la transacción que no justifican una tabla propia."),
])
h2("3.3 ¿Por qué estrella y no copo de nieve?")
p("Las jerarquías (País → Región → Departamento → Ciudad; Línea → Tipo → Servicio; Tipo de afiliación → Aseguradora) se "
  "aplanaron dentro de cada dimensión (T4, T5). Así cada pregunta se resuelve con un solo JOIN hecho–dimensión, el motor de "
  "Power BI trabaja con relaciones 1:N directas en una dirección (sin cadenas de dimensiones que propaguen filtros) y los "
  "segmentadores de región o línea filtran directo al hecho. La redundancia que se acepta es mínima porque las dimensiones "
  "son pequeñas (≤ 6.000 filas). El copo de nieve solo compensaría con dimensiones enormes o subdimensiones que cambien "
  "con frecuencia, y no es el caso.")

# ═════════════════════════ 4. CATÁLOGO ═════════════════════════
h1("4. Catálogo de transformaciones")
p("Columnas: regla del enunciado, cómo se implementó y resultado obtenido en la carga. Script: 03 = Dimensiones, "
  "04 = Mongo, 05 = Hechos, 06 = Atribución.", size=9)
cat = [
    ["#", "Implementación (script)", "Resultado"],
    ["T1", "Función dbo.fn_LimpiarTexto: TRIM + reducción de espacios dobles internos a uno; nombre completo con CONCAT_WS (03)", "253 pacientes con espacios sobrantes"],
    ["T2", "CASE: F/M/NULL → Femenino/Masculino/Sin dato; CC, TI, RC, CE, PA → nombre completo del documento (03)", "74 pacientes con sexo Sin dato"],
    ["T3", "Edad = DATEDIFF(YEAR) al 31-12-2025, menos 1 si no había cumplido años; CASE de curso de vida Res. 3280/2018 (03)", "Adultez 2.427 · Vejez 1.586 · Juventud 958 · Infancia 394 · Adolescencia 361 · Primera infancia 274"],
    ["T4", "JOIN Ciudad → Departamento → Región → País, aplanado en DIM_Paciente y DIM_Sede (03)", "Jerarquía geográfica sin tablas extra"],
    ["T5", "JOIN TipoServicio → Línea y Especialidad; RangoTarifa con CASE (< $100.000, $100.000–$999.999, ≥ $1.000.000) (03)", "99 servicios en 6 líneas"],
    ["T6", "Solo atenciones con estado Realizada entran al hecho; las demás se cuentan por modalidad en 07 (05)", "57.543 → 50.592 atenciones; 6.951 reportadas"],
    ["T7", "Medio principal = pago de mayor valor (ROW_NUMBER). Pago del paciente prorrateado por ValorNeto y redondeado; el residuo va a la línea de mayor neto; ValorAseguradora = Neto − Paciente (05)", "Cuadre al peso: 0 atenciones descuadradas"],
    ["T8", "OrdenExterna = 1 → ProfesionalKey = -1 y DiagnosticoKey = -1 (05)", "6.240 atenciones (11.655 líneas)"],
    ["T9", "AseguradoraKey sale de Atenciones.AseguradoraID (pagador histórico), no del paciente (05)", "988 atenciones con pagador distinto al actual (852 realizadas)"],
    ["T10", "Calendario de años completos según los datos; DiaSemana = DATEDIFF(DAY,'19000101',fecha) % 7 (1900-01-01 fue lunes) y nombres con CHOOSE: no depende de DATEFIRST ni del idioma (03)", "731 días, 2024–2025"],
    ["T11", "OPENJSON lee pacienteId como texto y se convierte con CAST(TRIM(…) AS INT) (04)", "60 pacienteId en texto"],
    ["T12", "Tras T11: ROW_NUMBER por paciente ordenado por fechaActualizacion DESC (desempate MongoId) y se deja la fila 1 (04)", "5.215 → 5.040 perfiles (175 antiguos)"],
    ["T13", "Tabla stg.EquivalenciaLinea (16 variantes, intercalación sin mayúsculas ni tildes) → 6 líneas oficiales; si una variante no tiene equivalencia, el ETL se detiene (THROW) (04)", "1.119 perfiles con valores no oficiales; 0 sin equivalencia"],
    ["T14", "Sin programa → 'Sin programa' / 'No aplica'; nivelRiesgo → Alto/Medio/Bajo; adherencia '85%' o 0.85 → 85; consentimientos SI/NO/true → 1/0 (04)", "2.668 sin programa · 94 niveles · 147 adherencias · 81 consentimientos"],
    ["T15", "OPENJSON del arreglo encuestasSatisfaccion, TRY_CAST del puntaje, AVG por paciente y clasificación 9–10 / 7–8 / 0–6 (04)", "2.906 pacientes con encuesta: 892 promotores, 1.189 pasivos, 825 detractores"],
    ["T16", "Duplicados exactos: HASHBYTES('SHA2_256', Doc) + ROW_NUMBER, se deja una copia. Canal con CASE (e-mail, correo, WA, push…). campanaId con TRIM + UPPER (05)", "240 duplicados eliminados · 826 canales · 65 campanaId"],
    ["T17", "OPENJSON de eventos y pivote con MAX(CASE…) a banderas 0/1; Abierto = abierto o leído; HorasHastaApertura = minutos entre entregado y primera apertura / 60 (05)", "36.073 filas; 12.061 aperturas"],
    ["T18", "Fecha {$date} con CONVERT estilo 127; texto dd/mm/aaaa hh:mm con estilo 103 (UTC). TiempoKey = primer evento − 5 h (05)", "927 documentos con fechas en texto; 0 sin fecha"],
    ["T19", "pacienteId sin paciente → -1 (se guarda el id original). Sin consentimiento = canal no autorizado en el perfil vigente (app no requiere; sin perfil = sin autorización). Fuera de segmento = sexo distinto o edad al inicio de la campaña fuera de rango (05)", "210 interacciones (171 ids) en -1 · 1.096 sin consentimiento · 216 fuera de segmento"],
    ["T20", "presupuesto texto → número (quita $, puntos, espacios); responsable vacío → 'Sin asignar'; canales y líneas → STRING_AGG con T13; segmentoObjetivo → SexoObjetivo, EdadMin, EdadMax; fechas a hora Colombia (04)", "24 campañas · 3 presupuestos · 2 sin responsable"],
    ["T21", "Candidatos: clic del paciente en la campaña + atención realizada en los 15 días siguientes + al menos un servicio de una línea promocionada (stg.campana_linea). Empate: ROW_NUMBER por atención, clic más reciente (06)", "397 atenciones (665 líneas), $62.174.625 atribuidos; 0 violaciones de la regla"],
]
tabla(cat, [1.0, 10.3, 6.2], size=7.5)
h2("4.1 Transformaciones adicionales del grupo")
bullets([
    ("A1 · Control de carga: ", "stg.ControlCarga guarda los conteos de cada extracción para el cuadre origen–destino."),
    ("A2 · Trazabilidad: ", "PacienteIdOrigen en FACT_InteraccionCampana conserva el id de Mongo aunque la clave sea -1."),
    ("A3 · Embudo de app: ", "la app solo registra impresión (no 'enviado'); se cargó la bandera Impresion para que el embudo de ese canal empiece ahí."),
    ("A4 · Limpieza extendida: ", "fn_LimpiarTexto también se aplica a nombres de servicios, sedes y profesionales; códigos de campaña vacíos → 'Sin código' (4)."),
    ("A5 · Reportes persistentes: ", "dbo.ReporteCalidad y dbo.ReporteCumplimiento quedan como tablas del DW, recalculadas en cada carga."),
])

# ═════════════════════════ 5. VALIDACIÓN ═════════════════════════
h1("5. Validación de la carga (07_Validacion.sql)")
h2("5.1 Conteos origen → destino")
tabla([
    ["Paso", "Origen", "Descartados", "Destino", "Cuadra", "Explicación del descarte"],
    ["OLTP Pacientes → DIM_Paciente", "6.000", "0", "6.000", "OK", "Sin descartes"],
    ["OLTP Atenciones → FACT_Atenciones", "57.543", "6.951", "50.592", "OK", "T6: canceladas e inasistencias"],
    ["OLTP DetalleAtencion → filas del hecho", "93.740", "11.292", "82.448", "OK", "T6: líneas de esas atenciones"],
    ["Mongo interacciones → stg", "36.313", "0", "36.313", "OK", "Extracción completa"],
    ["stg interacciones → FACT_InteraccionCampana", "36.313", "240", "36.073", "OK", "T16: duplicados exactos"],
    ["Mongo perfiles → stg", "5.215", "0", "5.215", "OK", "Extracción completa"],
    ["stg perfiles → DIM_Paciente (con perfil)", "5.215", "175", "5.040", "OK", "T12: perfiles antiguos"],
    ["Mongo campañas → DIM_Campana", "24", "0", "24", "OK", "Sin descartes"],
], [5.0, 1.5, 1.8, 1.5, 1.3, 6.4], alinear_der=(1, 2, 3))
p("Cuadre de dinero. ", None).runs[0].bold = True
doc.paragraphs[-1].add_run(
    "Facturación neta de las atenciones realizadas en el OLTP = SUM(ValorNeto) en el DW = suma de sus pagos = "
    "$8.116.053.700. ValorPaciente ($1.492.064.300) + ValorAseguradora ($6.623.989.400) = ValorNeto, sin ninguna línea "
    "ni atención descuadrada.")
p("Uso del miembro -1. ", None).runs[0].bold = True
doc.paragraphs[-1].add_run(
    "Solo aparece donde una regla lo exige: Profesional y Diagnóstico en 11.655 líneas (T8, todas con orden externa; 0 casos "
    "sin orden externa); Campaña en 81.783 líneas no atribuidas (T21); Paciente en 210 interacciones (T19). Las otras nueve "
    "combinaciones hecho–dimensión tienen 0 filas en -1.")
h2("5.2 Cancelación e inasistencia por modalidad (T6, desde el OLTP)")
tabla([
    ["Modalidad", "Atenciones", "Realizadas", "Canceladas", "Inasistencias", "% Cancelación", "% Inasistencia"],
    ["Presencial", "38.686", "34.066", "2.368", "2.252", "6,12 %", "5,82 %"],
    ["Telemedicina", "11.155", "9.805", "669", "681", "6,00 %", "6,10 %"],
    ["Domiciliaria", "4.805", "4.216", "296", "293", "6,16 %", "6,10 %"],
    ["Extramural", "2.897", "2.505", "180", "212", "6,21 %", "7,32 %"],
    ["Total", "57.543", "50.592", "3.513", "3.438", "6,10 %", "5,97 %"],
], [3.2, 2.2, 2.2, 2.2, 2.3, 2.6, 2.6], alinear_der=(1, 2, 3, 4, 5, 6))

# ═════════════════════════ 6. REPORTES ═════════════════════════
h1("6. Reporte de calidad de datos y de cumplimiento")
p("dbo.ReporteCalidad (29 problemas, calculados en vivo en cada carga). Ningún registro se descarta sin una regla que lo explique.", size=9)
calidad = [
    ["ID", "Fuente", "Problema", "Registros", "Regla"],
    ["S01", "OLTP Pacientes", "Nombres o apellidos con espacios sobrantes", "253", "T1"],
    ["S02", "OLTP Pacientes", "Sexo NULL", "74", "T2"],
    ["S03", "OLTP Pacientes", "Email o teléfono vacío (no se usan en el modelo)", "1.086", "—"],
    ["S04", "OLTP Atenciones", "Atenciones canceladas o con inasistencia", "6.951", "T6"],
    ["S05", "OLTP Atenciones", "Realizadas con orden externa (sin profesional ni diagnóstico)", "6.240", "T8"],
    ["S06", "OLTP Atenciones", "Pagador distinto a la aseguradora actual del paciente", "988", "T9"],
    ["M01", "Mongo perfiles", "pacienteId guardado como texto", "60", "T11"],
    ["M02", "Mongo perfiles", "Perfiles sobrantes de pacientes con varios perfiles", "175", "T12"],
    ["M03", "Mongo perfiles", "lineasInteres no oficiales (mayúsculas, tildes, sinónimos)", "1.119", "T13"],
    ["M04", "Mongo perfiles", "Sin programaRiesgo", "2.668", "T14"],
    ["M05", "Mongo perfiles", "nivelRiesgo con mayúsculas inconsistentes", "94", "T14"],
    ["M06", "Mongo perfiles", "Adherencia como texto '85%' o fracción 0.85", "147", "T14"],
    ["M07", "Mongo perfiles", "Consentimientos como texto 'SI' / 'NO'", "81", "T14"],
    ["M08", "Mongo perfiles", "Sin encuestasSatisfaccion (TipoNPS 'Sin encuesta')", "2.211", "T15"],
    ["M09", "Mongo perfiles", "Puntajes de encuesta como texto", "130", "T15"],
    ["M10", "Mongo interacciones", "Documentos duplicados exactos (copias sobrantes)", "240", "T16"],
    ["M11", "Mongo interacciones", "canal fuera de email / sms / whatsapp / app", "826", "T16"],
    ["M12", "Mongo interacciones", "campanaId con espacios o minúsculas", "65", "T16"],
    ["M13", "Mongo interacciones", "Fechas de evento en texto dd/mm/aaaa hh:mm", "927", "T18"],
    ["M14", "Mongo interacciones", "pacienteId que no existe en el OLTP (documentos)", "211", "T19"],
    ["M15", "Mongo interacciones", "citaAgendada ausente (solo existe cuando hubo clic)", "32.276", "T17"],
    ["M16", "Mongo interacciones", "Canal app sin evento 'enviado' (solo impresión)", "5.970", "T17"],
    ["M17", "Mongo interacciones", "Apertura registrada como 'abierto' o como 'leido'", "12.061", "T17"],
    ["M18", "Mongo campañas", "presupuesto como texto", "3", "T20"],
    ["M19", "Mongo campañas", "responsable faltante o vacío", "2", "T20"],
    ["M20", "Mongo campañas", "lineasPromocionadas no estandarizadas", "1", "T20+T13"],
    ["M21", "Mongo campañas", "Sin segmentoObjetivo (abierta a todos → 'Todos')", "12", "T20"],
    ["M22", "Mongo campañas", "segmentoObjetivo sin sexo (solo edad)", "6", "T20"],
    ["M23", "Mongo campañas", "Sin codigoBeneficio ('Sin código')", "4", "T20"],
]
tabla(calidad, [1.1, 3.2, 9.6, 1.8, 1.8], size=7.5, alinear_der=(3,))
p("M14 cuenta documentos antes de quitar duplicados (211); en el hecho quedan 210 interacciones con paciente -1.", size=8.5, italic=True)
h2("6.1 Reporte de cumplimiento (T19 · dbo.ReporteCumplimiento)")
tabla([
    ["Hallazgo", "Motivo", "Registros", "% de interacciones"],
    ["Envío sin consentimiento (Ley 1581 de 2012)", "Canal no autorizado en el perfil vigente", "888", "2,46 %"],
    ["", "Paciente sin perfil (sin autorización registrada)", "208", "0,58 %"],
    ["", "Total", "1.096", "3,04 %"],
    ["Envío fuera del segmento objetivo", "Edad al inicio de la campaña fuera del rango", "133", "0,37 %"],
    ["", "Sexo distinto al objetivo", "79", "0,22 %"],
    ["", "Sexo sin dato (no verificable)", "4", "0,01 %"],
    ["", "Total", "216", "0,60 %"],
    ["Paciente inexistente en el OLTP", "pacienteId sin registro (171 ids distintos)", "210", "0,58 %"],
], [5.2, 6.8, 2.2, 3.3], alinear_der=(2, 3))
p("El reporte detallado (165 filas) abre cada hallazgo por campaña y canal. Las campañas con más envíos sin consentimiento "
  "son Semana de la salud 2025 (140) y 2024 (111); las de mayor porcentaje, Control de crónicos al día 2024 (4,27 %) y "
  "Salud masculina 2024 (4,19 %). Fuera de segmento se concentra en Octubre rosa (60), Corazón sano (38), Mes de la mujer "
  "(38) y Vacaciones con buena visión (37).")

# ═════════════════════════ 7. DASHBOARD ═════════════════════════
h1("7. Dashboard en Power BI (BI_Grupo1.pbix)")
bullets([
    ("Conexión: ", "solo a CLINICABI_DW_Grupo1 (importación). 13 relaciones N:1 de los hechos a las dimensiones, filtro en una sola dirección."),
    ("Tiempo: ", "DIM_Tiempo marcada como tabla de fechas (sin la fila -1), con jerarquía Año → Trimestre → Mes → Día y drill-down."),
    ("33 medidas DAX ", "(powerbi/medidas_dax.md) con CALCULATE, DIVIDE, SAMEPERIODLASTYEAR y DATEADD. Ej.: Crecimiento Facturación %, "
     "Tasa Apertura/Clic/Cita, Costo por Clic/Cita, Facturación Atribuida, ROI Campaña, NPS, % Sin Consentimiento."),
    ("Diseño: ", "paleta única, moneda en COP, títulos que enuncian el hallazgo, segmentadores de año, región, línea, modalidad y canal."),
])
figura(os.path.join(IMG, "pagina1.png"), 16.5, "Figura 3. Página 1 · Resumen ejecutivo (año 2025 seleccionado).")
figura(os.path.join(CAP, "07_pagina2.png"), 16.5, "Figura 4. Página 2 · Pacientes, servicios y territorio.")
figura(os.path.join(CAP, "08_pagina3.png"), 16.5, "Figura 5. Página 3 · Campañas y experiencia.")

# ═════════════════════════ 8. PREGUNTAS ═════════════════════════
h1("8. Respuestas a las preguntas de negocio")
preg = [
    ["#", "Respuesta (cifra)", "Visual que la sustenta"],
    ["P1", "La facturación neta creció 13,5 % ($3.801,2 M en 2024 → $4.314,8 M en 2025) y el margen 13,3 % ($1.379,8 M → $1.563,3 M). "
           "El margen % se mantiene (36,3 % → 36,2 %): el crecimiento viene de volumen (23.686 → 26.906 atenciones, +13,6 %).",
     "Pág. 1: tarjetas con crecimiento y línea de facturación mensual 2025 vs 2024"],
    ["P2", "Líneas: Consulta externa (23,5 %) y Cirugía ambulatoria (21,0 %) suman el 44,5 %. Especialidades: Bacteriología (15,9 %), "
           "Radiología (13,7 %) y Enfermería (9,7 %). Región Andina: 76,3 % (Caribe 12,2 %, Pacífica 11,5 %); sede líder Medellín Laureles.",
     "Pág. 2: barras por región → departamento → sede y por línea → especialidad (drill-down)"],
    ["P3", "Telemedicina es la que más crece: +73,4 % en atenciones (3.587 → 6.218) y +87,8 % en facturación. Siguen Domiciliaria "
           "(+31,4 %) y Extramural (+14,1 %); Presencial cae 0,9 % en atenciones aunque factura 6,1 % más.",
     "Pág. 1: atenciones por modalidad y año"],
    ["P4", "Medicina prepagada deja el mejor margen (47,6 %), seguida de Particular (45,6 %) y Póliza (45,0 %); Subsidiado el menor "
           "(25,4 %). De $6.624 M por cobrar, Salud Andina EPS (26,6 %) y Nueva Vida EPS (22,7 %) concentran el 49,3 %.",
     "Pág. 2: matriz tipo de afiliación → aseguradora con margen % y cartera"],
    ["P5", "WhatsApp: 8,40 % de los contactos terminan en cita (971 de 11.564), 2,6 veces más que email (3,20 %); SMS 2,53 % y app 2,36 %. "
           "WhatsApp también convierte mejor el clic (48,9 % de los clics agendan).",
     "Pág. 3: tasas de apertura, clic y cita por canal + embudo"],
    ["P6", "Sí. Los pacientes con programa de riesgo tienen 9,42 atenciones por paciente frente a 7,78 sin programa (+21 %). "
           "Crece con el nivel: Alto 11,52, Medio 9,40, Bajo 8,32.",
     "Pág. 2: Atenciones x Paciente por nivel de riesgo"],
    ["P7", "Semana de la salud 2025: $21.910.930 atribuidos (103 atenciones) con presupuesto de $22,5 M → ROI −2,6 %. "
           "Semana de la salud 2024: $8.383.925 (58 atenciones) con $18 M → ROI −53,4 %. 2025 multiplicó por 2,6 la facturación atribuida.",
     "Pág. 3: columnas de facturación atribuida y presupuesto con línea de ROI por campaña"],
    ["P8", "1.096 envíos sin consentimiento (3,0 %): 888 por canal no autorizado y 208 a pacientes sin perfil; más volumen en Semana de "
           "la salud 2025 (140) y 2024 (111). 216 fuera de segmento (0,6 %): Octubre rosa (60), Corazón sano (38) y Mes de la mujer (38).",
     "Pág. 3: tarjetas % y barras por campaña; detalle en dbo.ReporteCumplimiento"],
]
tabla(preg, [1.0, 11.2, 5.3], size=8)
h2("8.1 Recomendaciones al área de Experiencia del Paciente (P8)")
bullets([
    "Bloquear el envío en la plataforma de campañas cuando el canal no esté autorizado en el perfil vigente del paciente "
    "(Ley 1581 de 2012) y no enviar por email, SMS o WhatsApp a pacientes sin perfil hasta registrar su autorización.",
    "Filtrar la audiencia por el segmento objetivo calculando la edad a la fecha de inicio de la campaña y validando el sexo; "
    "completar el sexo de los pacientes 'Sin dato' antes de campañas segmentadas.",
    "Depurar los 171 pacienteId inexistentes en el OLTP antes de enviar y unificar la captura de canal y fechas (fuentes de M11 y M13).",
    "Priorizar WhatsApp (mayor conversión a cita) entre los pacientes que lo autorizaron, y concentrar presupuesto en campañas con "
    "mejor ROI como la Semana de la salud.",
])

# ═════════════════════════ 9. EJECUCIÓN ═════════════════════════
h1("9. Instrucciones de ejecución")
bullets([
    "Prerrequisitos: SQL Server con CLINICABI_OLTP cargada (scripts del docente), MongoDB con clinica_bi (LEEME_carga_MongoDB.txt), "
    "sqlcmd y Python 3 con: pip install -r mongo/requirements.txt.",
    "Ejecutar desde la carpeta del proyecto: .\\run_etl.ps1 (o .\\run_etl.ps1 -Servidor \"EQUIPO\\INSTANCIA\" -MongoUri \"mongodb://…\"). "
    "Borra y recrea el DW, extrae, transforma, atribuye y valida sin intervención; la salida completa queda en evidencias/salida_run_etl.txt.",
    "Abrir powerbi/BI_Grupo1.pbix y pulsar Actualizar (si cambia la instancia: Transformar datos → Configuración de origen de datos).",
])

doc.save(SALIDA)
print("Documento:", SALIDA)
