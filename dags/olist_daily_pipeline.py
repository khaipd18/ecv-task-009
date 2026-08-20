"""
olist_daily_pipeline
====================
Orchestrate pipeline Olist. Batch đã được Noel sinh sẵn thành các thư mục
`data/batches/batch_YYYYMMDD/`, mỗi thư mục 4 file CSV của các bảng ĐỘNG.

    start
      -> check_seed        (chặn nếu chưa seed dimension)
      -> pick_batch        (tìm batch kế tiếp CHƯA nạp)
      -> load_raw          (gọi scripts/load_raw.sh của Noel)
      -> stg_orders        (transform/02_stg_orders.sql)
      -> mart_upsert       (transform/03_mart_upsert.sql)
      -> write_audit       (transform/04_write_audit.sql)
      -> dq_check
      -> end

KHÁC với thiết kế ban đầu — lý do ghi rõ để sau này đọc lại còn hiểu:

1. KHÔNG có task generate_batch. Batch đã sinh sẵn từ trước, DAG chỉ việc nạp
   dần từng thư mục. Task `pick_batch` tự tìm thư mục kế tiếp chưa nạp bằng cách
   đối chiếu với ops.load_audit.

2. KHÔNG có task refresh_matviews. Noel dùng CREATE OR REPLACE VIEW thường
   (18 view trong sql/marts/), không phải materialized view — view tính lại
   real-time mỗi lần Superset query nên không cần refresh.
   => Dashboard tự update phụ thuộc HOÀN TOÀN vào việc cache Superset đã tắt.
      Xem superset/superset_config.py, đừng bật lại cache.

3. Nạp raw bằng BashOperator gọi load_raw.sh của Noel, không dùng task Python
   riêng cho từng bảng. Script dùng COPY nên nhanh hơn insert_rows nhiều lần.

4. Dimension (dim_product/dim_customer/dim_seller) được tạo trong
   03_mart_upsert.sql, cùng file với fact. Chạy file này khi staging chưa có
   order nào thì phần fact chỉ đơn giản là no-op.
"""
from __future__ import annotations

import os
from datetime import datetime, timedelta

import pendulum
from airflow import DAG
from airflow.exceptions import AirflowFailException, AirflowSkipException
from airflow.operators.empty import EmptyOperator
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator
from airflow.providers.common.sql.operators.sql import (
    SQLExecuteQueryOperator,
    SQLColumnCheckOperator,
)
from airflow.providers.postgres.hooks.postgres import PostgresHook

LOCAL_TZ = pendulum.timezone("Asia/Ho_Chi_Minh")

CONN_ID = "olist_postgres"                       # ENV: AIRFLOW_CONN_OLIST_POSTGRES
BATCH_ROOT = "/opt/airflow/data/batches"         # ./data mount vào đây
LOAD_SCRIPT = "/opt/airflow/scripts/load_raw.sh"

default_args = {
    "owner": "khai",
    "retries": 2,
    "retry_delay": timedelta(minutes=2),
    # Timeout PHẢI nhỏ hơn schedule interval, tránh 2 run chồng nhau
    "execution_timeout": timedelta(minutes=10),
    "depends_on_past": False,
}


def _check_seed(**_):
    """Chặn pipeline nếu dimension chưa có dữ liệu.

    Thiếu dimension thì fact join ra NULL toàn bộ và dashboard hiện số vô nghĩa
    — rất khó phát hiện, nhất là khi Noel đang dựng chart ở đầu bên kia.
    """
    hook = PostgresHook(postgres_conn_id=CONN_ID)
    empty = []
    for tbl in ("mart.dim_product", "mart.dim_customer", "mart.dim_seller"):
        n = hook.get_first(f"SELECT COUNT(*) FROM {tbl}")[0]
        print(f"[check_seed] {tbl}: {n} dòng")
        if n == 0:
            empty.append(tbl)
    if empty:
        raise AirflowFailException(
            f"Chưa seed dimension: {', '.join(empty)}. "
            f"Chạy `make seed` (DAG olist_seed_static) trước."
        )


def _pick_batch(**context):
    """Tìm thư mục batch kế tiếp chưa được nạp.

    Batch đã sinh sẵn nên không dùng {{ ds }} của Airflow — logical_date của run
    không liên quan gì tới ngày trong dữ liệu (dữ liệu Olist là 2016-2018).
    Thay vào đó: liệt kê thư mục batch_*, bỏ những batch_id đã có trong
    ops.load_audit, lấy cái nhỏ nhất còn lại.

    Nhờ vậy pipeline idempotent: chạy lại không nạp trùng, và mỗi run tiến đúng
    một batch — khớp với kịch bản "mỗi ngày thêm dữ liệu mới" chị yêu cầu.
    """
    if not os.path.isdir(BATCH_ROOT):
        raise AirflowFailException(f"Không thấy thư mục {BATCH_ROOT}")

    available = sorted(
        d for d in os.listdir(BATCH_ROOT)
        if d.startswith("batch_") and os.path.isdir(os.path.join(BATCH_ROOT, d))
    )
    if not available:
        raise AirflowFailException(f"Không có thư mục batch_* nào trong {BATCH_ROOT}")

    hook = PostgresHook(postgres_conn_id=CONN_ID)
    rows = hook.get_records("SELECT DISTINCT batch_id FROM ops.load_audit")
    done = {r[0] for r in rows if r[0]}
    print(f"[pick_batch] có sẵn: {available}")
    print(f"[pick_batch] đã nạp: {sorted(done)}")

    remaining = [b for b in available if b not in done]
    if not remaining:
        raise AirflowSkipException(
            "Đã nạp hết batch có sẵn. Nhờ Noel sinh thêm, hoặc dừng ở đây."
        )

    batch_id = remaining[0]
    batch_dir = os.path.join(BATCH_ROOT, batch_id)
    print(f"[pick_batch] chọn: {batch_id} -> {batch_dir}")

    ti = context["ti"]
    ti.xcom_push(key="batch_id", value=batch_id)
    ti.xcom_push(key="batch_dir", value=batch_dir)
    return batch_id


with DAG(
    dag_id="olist_daily_pipeline",
    description="Olist: nạp batch kế tiếp -> clean -> dedup -> mart -> dashboard",
    start_date=datetime(2026, 8, 1, tzinfo=LOCAL_TZ),
    schedule="*/15 * * * *",
    # catchup=False BẮT BUỘC: để True sẽ backfill hàng trăm run khi bật DAG
    catchup=False,
    max_active_runs=1,
    default_args=default_args,
    template_searchpath="/opt/airflow/sql",
    tags=["olist", "demo", "mentor-task"],
    doc_md=__doc__,
) as dag:

    start = EmptyOperator(task_id="start")

    check_seed = PythonOperator(
        task_id="check_seed",
        python_callable=_check_seed,
    )

    pick_batch = PythonOperator(
        task_id="pick_batch",
        python_callable=_pick_batch,
    )

    # Gọi script của Noel: load_raw.sh <thư_mục_batch> <batch_id>
    load_raw = BashOperator(
        task_id="load_raw",
        bash_command=(
            f"bash {LOAD_SCRIPT} "
            "{{ ti.xcom_pull(task_ids='pick_batch', key='batch_dir') }} "
            "{{ ti.xcom_pull(task_ids='pick_batch', key='batch_id') }}"
        ),
        env={
            # Script của Noel cần biến kết nối Postgres. Giá trị lấy từ .env
            # thông qua environment của container Airflow.
            "PGHOST": "postgres",
            "PGPORT": "5432",
            "PGDATABASE": "{{ var.value.get('olist_db', 'olist') }}",
            "PGUSER": "{{ var.value.get('olist_user', 'olist_user') }}",
            "PGPASSWORD": "{{ var.value.get('olist_password', '') }}",
        },
        append_env=True,
    )

    stg_orders = SQLExecuteQueryOperator(
        task_id="stg_orders",
        conn_id=CONN_ID,
        sql="transform/02_stg_orders.sql",
        params={"batch_id": "{{ ti.xcom_pull(task_ids='pick_batch', key='batch_id') }}"},
    )

    mart_upsert = SQLExecuteQueryOperator(
        task_id="mart_upsert",
        conn_id=CONN_ID,
        sql="transform/03_mart_upsert.sql",
        params={"batch_id": "{{ ti.xcom_pull(task_ids='pick_batch', key='batch_id') }}"},
    )

    # Đặt SAU mart_upsert để rows_loaded phản ánh số dòng thực vào fact.
    # Noel đề xuất thứ tự stg -> audit -> mart; nếu 04_write_audit.sql chỉ đọc
    # từ staging thì đổi lại vị trí task này, báo Noel xác nhận.
    write_audit = SQLExecuteQueryOperator(
        task_id="write_audit",
        conn_id=CONN_ID,
        sql="transform/04_write_audit.sql",
        params={"batch_id": "{{ ti.xcom_pull(task_ids='pick_batch', key='batch_id') }}"},
        trigger_rule="all_done",   # ghi audit kể cả khi task trước fail
    )

    dq_check = SQLColumnCheckOperator(
        task_id="dq_check",
        conn_id=CONN_ID,
        table="mart.fct_order_items",
        column_mapping={
            "order_id": {"null_check": {"equal_to": 0}},
            "order_item_id": {"null_check": {"equal_to": 0}},
            "price": {"min": {"geq_to": 0}},
        },
    )

    end = EmptyOperator(task_id="end")

    (
        start
        >> check_seed
        >> pick_batch
        >> load_raw
        >> stg_orders
        >> mart_upsert
        >> write_audit
        >> dq_check
        >> end
    )
