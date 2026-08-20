"""
olist_seed_static
=================
Nạp dữ liệu nền một lần duy nhất từ `data/batches/seed/` (8 file CSV: 4 bảng
động của batch đầu + 4 bảng tĩnh products/customers/sellers/category_translation).

    start -> load_seed_raw -> stg_static -> mart_upsert -> end

Vì sao tách khỏi pipeline chính:
  * Bảng tĩnh không có cột thời gian nên không cắt batch theo ngày được.
  * Nạp lại mỗi run là lãng phí và làm rối số liệu trong ops.load_audit.
  * Tách ra thì graph của DAG chính sạch, dễ giải thích khi demo.

Cách chạy: `make seed` hoặc trigger tay trên UI. schedule=None nên KHÔNG tự chạy.
Chạy MỘT LẦN trước khi bật olist_daily_pipeline.

Lưu ý: 03_mart_upsert.sql xử lý cả dimension lẫn fact. Ở bước seed, staging chưa
có order nào nên phần fact chỉ là no-op — chỉ dimension được nạp.
"""
from __future__ import annotations

from datetime import datetime, timedelta

import pendulum
from airflow import DAG
from airflow.operators.empty import EmptyOperator
from airflow.operators.bash import BashOperator
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator

LOCAL_TZ = pendulum.timezone("Asia/Ho_Chi_Minh")

CONN_ID = "olist_postgres"
SEED_DIR = "/opt/airflow/data/batches/seed"
SEED_BATCH_ID = "seed"
LOAD_SCRIPT = "/opt/airflow/scripts/load_raw.sh"

with DAG(
    dag_id="olist_seed_static",
    description="Nạp 1 lần: bảng tĩnh + batch nền",
    start_date=datetime(2026, 8, 1, tzinfo=LOCAL_TZ),
    schedule=None,                 # KHÔNG tự chạy, chỉ trigger tay
    catchup=False,
    max_active_runs=1,
    default_args={
        "owner": "khai",
        "retries": 1,
        "retry_delay": timedelta(minutes=1),
        "execution_timeout": timedelta(minutes=20),
    },
    template_searchpath="/opt/airflow/sql",
    tags=["olist", "seed", "one-off"],
    doc_md=__doc__,
) as dag:

    start = EmptyOperator(task_id="start")

    load_seed_raw = BashOperator(
        task_id="load_seed_raw",
        bash_command=f"bash {LOAD_SCRIPT} {SEED_DIR} {SEED_BATCH_ID}",
        env={
            "PGHOST": "postgres",
            "PGPORT": "5432",
            "PGDATABASE": "{{ var.value.get('olist_db', 'olist') }}",
            "PGUSER": "{{ var.value.get('olist_user', 'olist_user') }}",
            "PGPASSWORD": "{{ var.value.get('olist_password', '') }}",
        },
        append_env=True,
    )

    stg_static = SQLExecuteQueryOperator(
        task_id="stg_static",
        conn_id=CONN_ID,
        sql="transform/01_stg_static.sql",
        params={"batch_id": SEED_BATCH_ID},
    )

    # File này tạo cả dimension lẫn fact; ở bước seed chỉ dimension được nạp.
    seed_dimensions = SQLExecuteQueryOperator(
        task_id="seed_dimensions",
        conn_id=CONN_ID,
        sql="transform/03_mart_upsert.sql",
        params={"batch_id": SEED_BATCH_ID},
    )

    end = EmptyOperator(task_id="end")

    start >> load_seed_raw >> stg_static >> seed_dimensions >> end
