# AdventureWorks — decisiones D2 y D7

Especificación funcional y técnica del subconjunto de Inteligencia de
Negocios para analizar ofertas de productos (D2) y existencias de materias
primas (D7).

## Contenido

- `aw-docs\proyecto.tex`: requerimientos, modelos de fuente y almacén,
  arquitectura, transformaciones y visualizaciones.
- `aw-docs\proyecto.pdf`: informe generado desde LaTeX.
- `aw-dwh\decision_d2.sql`: análisis de ventas, descuentos, margen bruto
  estimado y recompra observada.
- `aw-dwh\decision_d7.sql`: análisis de existencias, compras y proveedores.

## Generar el informe

Requiere `pdflatex`, disponible con una distribución LaTeX:

```powershell
pdflatex -interaction=nonstopmode -halt-on-error -output-directory aw-docs aw-docs\proyecto.tex
pdflatex -interaction=nonstopmode -halt-on-error -output-directory aw-docs aw-docs\proyecto.tex
```

La segunda compilación actualiza referencias y elementos del PDF.

## Consultas

Las consultas están destinadas a SQL Server y a la base `AdventureWorks2022`.
Ambos scripts son de lectura y pueden adaptarse al nombre de la base del
entorno. La consulta D2 inicia con las fechas 2011–2014 del historial de
AdventureWorks; sus variables de período y producto permiten acotar el análisis.
Los ejemplos del informe utilizan archivos de datos de AdventureWorks para
ofertas, ventas, productos, costos, inventario y compras.

## Modelo de datos y arquitectura

El informe especifica el grano de las tablas de hechos, dimensiones
compartidas, relaciones de fuentes, convenciones de integración y reglas ETL.
El flujo lógico utiliza SQL Server, MinIO, Spark/dbt, Dagster, PostgreSQL y
Trino.

Repositorio del proyecto: <https://github.com/DJSixHub/AdventureWorks>.