#!/bin/bash
# ============================================================================
# Thu thập evidence sau mỗi run của Airflow.
# Chạy: ./scripts/capture_evidence.sh
# Kết quả: docs/evidence/<timestamp>/
#
# Tự động hoá phần này để (1) không quên chụp, (2) số liệu giữa các run nhất
# quán, không bị gõ query khác nhau mỗi lần.
# ============================================================================
set -e
cd "$(dirname "$0")/.."
set -a; source .env; set +a

TS=$(date +%Y%m%d_%H%M%S)
OUT="docs/evidence/${TS}"
mkdir -p "$OUT"

PSQL="docker compose exec -T postgres psql -U ${APP_DB_USER} -d ${APP_DB}"

echo "=== [1/5] Trạng thái container ==="
docker compose ps | tee "$OUT/01_docker_ps.txt"

echo ""
echo "=== [2/5] Bảng ops.load_audit (BẰNG CHỨNG CHÍNH) ==="
$PSQL -c "SELECT batch_id, run_time, rows_in, rows_dup, rows_rejected, rows_loaded
          FROM ops.load_audit ORDER BY run_time;" | tee "$OUT/02_load_audit.txt"

echo ""
echo "=== [3/5] Số dòng từng tầng bảng ==="
$PSQL -c "SELECT 'raw.orders'      AS bang, COUNT(*) FROM raw.raw_orders
          UNION ALL SELECT 'raw.order_items',  COUNT(*) FROM raw.raw_order_items
          UNION ALL SELECT 'stg.orders',       COUNT(*) FROM staging.stg_orders
          UNION ALL SELECT 'stg.order_items',  COUNT(*) FROM staging.stg_order_items
          UNION ALL SELECT 'mart.fct_order_items', COUNT(*) FROM mart.fct_order_items
          UNION ALL SELECT 'mart.dim_product',  COUNT(*) FROM mart.dim_product
          UNION ALL SELECT 'mart.dim_customer', COUNT(*) FROM mart.dim_customer
          UNION ALL SELECT 'mart.dim_seller',   COUNT(*) FROM mart.dim_seller
          UNION ALL SELECT 'ops.rejected',      COUNT(*) FROM ops.rejected_rows;" \
     | tee "$OUT/03_row_counts.txt"

echo ""
echo "=== [4/5] Kiểm tra KHÔNG còn duplicate trong mart ==="
$PSQL -c "SELECT order_id, order_item_id, COUNT(*) AS n
          FROM mart.fct_order_items GROUP BY 1,2 HAVING COUNT(*) > 1 LIMIT 10;" \
     | tee "$OUT/04_dup_check.txt"

echo ""
echo "=== [5/5] Kiem tra KHONG co dong con mo coi (order_item khong co order cha) ==="
$PSQL -c "SELECT COUNT(*) AS orphan_items
          FROM mart.fct_order_items f
          LEFT JOIN staging.stg_orders o USING (order_id)
          WHERE o.order_id IS NULL;" | tee "$OUT/05_orphan_check.txt"

# Xuất load_audit ra CSV để dán thẳng vào slide
$PSQL -c "\copy (SELECT * FROM ops.load_audit ORDER BY run_time) TO STDOUT WITH CSV HEADER" \
     > "$OUT/load_audit.csv"

echo ""
echo "-------------------------------------------------------------"
echo "Đã lưu vào: $OUT"
echo "CÒN PHẢI CHỤP TAY 3 ẢNH:"
echo "  1. Airflow Grid + Graph view (http://localhost:${AIRFLOW_HOST_PORT})"
echo "  2. Dashboard Superset        (http://localhost:${SUPERSET_HOST_PORT})"
echo "  3. Đồng hồ/timestamp trên màn hình để chứng minh thời điểm"
echo "Bỏ ảnh vào: $OUT"
echo "-------------------------------------------------------------"
