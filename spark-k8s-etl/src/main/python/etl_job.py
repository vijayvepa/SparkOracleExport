import json
import os
from typing import List, Dict

from pyspark.sql import SparkSession, DataFrame
from pyspark.sql.functions import col, lpad, rpad, concat_ws


def load_layout(path: str) -> List[Dict]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def apply_fixed_width(df: DataFrame, layout: List[Dict]) -> DataFrame:
    cols = []
    for field in layout:
        name = field["name"]
        length = int(field["length"])
        ftype = field["type"]

        if ftype == "num":
            padded = lpad(col(name).cast("string"), length, "0")
        else:
            padded = rpad(col(name).cast("string"), length, " ")
        cols.append(padded)

    # Concatenate with no delimiter to form fixed-width record
    return df.select(concat_ws("", *cols).alias("record"))


def main():
    # JDBC connection details (MySQL)
    jdbc_url = os.environ.get(
        "JDBC_URL",
        "jdbc:mysql://mysql:3306/etldb?allowPublicKeyRetrieval=TRUE&useSSL=false&serverTimezone=UTC",
    )
    jdbc_user = os.environ.get("JDBC_USER", "root")
    jdbc_password = os.environ.get("JDBC_PASSWORD", "rootpassword")
    jdbc_driver = os.environ.get("JDBC_DRIVER", "com.mysql.cj.jdbc.Driver")

    layout_path = os.environ.get("LAYOUT_PATH", "/opt/spark-app/config/layout.json")
    output_path = os.environ.get("OUTPUT_PATH", "/output/fixedwidth.txt")
    table = os.environ.get("SOURCE_TABLE", "CUSTOMERS")

    layout = load_layout(layout_path)

    spark = (
        SparkSession.builder.appName("mysql-fixedwidth-etl")
        .config("spark.sql.shuffle.partitions", "4")
        .getOrCreate()
    )

    df = (
        spark.read.format("jdbc")
        .option("url", jdbc_url)
        .option("driver", jdbc_driver)
        .option("user", jdbc_user)
        .option("password", jdbc_password)
        .option("dbtable", table)
        .load()
    )

    fw_df = apply_fixed_width(df, layout).coalesce(1)

    fw_df.write.mode("overwrite").text(output_path)

    spark.stop()


if __name__ == "__main__":
    main()

