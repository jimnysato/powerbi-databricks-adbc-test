"""Builds three identical Power BI projects (PBIP) that import samples.tpch.orders from Databricks.

The only difference between them is the driver option in the Power Query source step:
  ODBC.pbip       Implementation = "1.0"                      (legacy Simba ODBC)
  ADBC.pbip       Implementation = "2.0"                      (Databricks ADBC, Thrift)
  ADBC-REST.pbip  Implementation = "2.0", Protocol = "rest"   (Databricks ADBC, Statement Execution API)

Usage:
  python build_pbip.py --host <workspace>.cloud.databricks.com --http-path /sql/1.0/warehouses/<id>
Both values are on the SQL warehouse page, "Connection details" tab.
"""
import argparse, json, shutil, uuid
from pathlib import Path

COLS = [
    ("o_orderkey", "int64", "0"),
    ("o_custkey", "int64", "0"),
    ("o_orderstatus", "string", None),
    ("o_totalprice", "decimal", "#,0.00"),
    ("o_orderdate", "dateTime", "dd/mm/yyyy"),
    ("o_orderpriority", "string", None),
    ("o_clerk", "string", None),
    ("o_shippriority", "int64", "0"),
    ("o_comment", "string", None),
]
VARIANTS = {"ODBC": 'Implementation = "1.0"', "ADBC": 'Implementation = "2.0"',
            "ADBC-REST": 'Implementation = "2.0", Protocol = "rest"'}


def table_tmdl(host, http_path, driver_opts):
    out = ["table orders", f"\tlineageTag: {uuid.uuid4()}", "",
           "\tmeasure Orders = COUNTROWS(orders)", "\t\tformatString: #,0", f"\t\tlineageTag: {uuid.uuid4()}", ""]
    for name, dtype, fmt in COLS:
        out += [f"\tcolumn {name}", f"\t\tdataType: {dtype}"]
        if fmt:
            out.append(f"\t\tformatString: {fmt}")
        out += [f"\t\tlineageTag: {uuid.uuid4()}", "\t\tsummarizeBy: none", f"\t\tsourceColumn: {name}", ""]
    out += [
        "\tpartition orders = m", "\t\tmode: import", "\t\tsource =", "\t\t\t\tlet",
        f'\t\t\t\t    Source = Databricks.Catalogs("{host}", "{http_path}", [Catalog = null, Database = null, EnableAutomaticProxyDiscovery = null, {driver_opts}]),',
        '\t\t\t\t    samples_Database = Source{[Name = "samples", Kind = "Database"]}[Data],',
        '\t\t\t\t    tpch_Schema = samples_Database{[Name = "tpch", Kind = "Schema"]}[Data],',
        '\t\t\t\t    orders_Table = tpch_Schema{[Name = "orders", Kind = "Table"]}[Data]',
        "\t\t\t\tin", "\t\t\t\t    orders_Table", "",
    ]
    return "\n".join(out)


def platform(kind, name):
    return json.dumps({
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json",
        "metadata": {"type": kind, "displayName": name},
        "config": {"version": "2.0", "logicalId": str(uuid.uuid4())},
    }, indent=2)


def build(base, template, name, host, http_path, driver_opts):
    d = base / f"{name}.SemanticModel" / "definition"
    (d / "tables").mkdir(parents=True, exist_ok=True)
    (d.parent / ".platform").write_text(platform("SemanticModel", name), encoding="utf-8")
    (d.parent / "definition.pbism").write_text(json.dumps({
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/semanticModel/definitionProperties/1.0.0/schema.json",
        "version": "4.2", "settings": {}}, indent=2), encoding="utf-8")
    (d / "database.tmdl").write_text("database\n\tcompatibilityLevel: 1600\n", encoding="utf-8")
    (d / "model.tmdl").write_text(
        "model Model\n\tculture: en-US\n\tdefaultPowerBIDataSourceVersion: powerBI_V3\n"
        "\tsourceQueryCulture: en-US\n\tdataAccessOptions\n\t\tlegacyRedirects\n\t\treturnErrorValuesAsNull\n\n"
        "ref table orders\n", encoding="utf-8")
    (d / "tables" / "orders.tmdl").write_text(table_tmdl(host, http_path, driver_opts), encoding="utf-8")

    rep = base / f"{name}.Report"
    if rep.exists():
        shutil.rmtree(rep)
    shutil.copytree(template, rep)
    (rep / ".platform").write_text(platform("Report", name), encoding="utf-8")
    (rep / "definition.pbir").write_text(json.dumps({
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json",
        "version": "4.0", "datasetReference": {"byPath": {"path": f"../{name}.SemanticModel"}}}, indent=2), encoding="utf-8")
    (base / f"{name}.pbip").write_text(json.dumps({
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/pbip/pbipProperties/1.0.0/schema.json",
        "version": "1.0", "artifacts": [{"report": {"path": f"{name}.Report"}}],
        "settings": {"enableAutoRecovery": True}}, indent=2), encoding="utf-8")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", required=True)
    ap.add_argument("--http-path", required=True)
    ap.add_argument("--out", default="pbip")
    a = ap.parse_args()
    here = Path(__file__).parent
    out = Path(a.out)
    for name, opts in VARIANTS.items():
        build(out, here / "report-template", name, a.host, a.http_path, opts)
    print(f"Built {', '.join(VARIANTS)} in {out.resolve()}")
