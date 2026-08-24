#!/bin/bash
# ============================================================================
# demo_batch.sh — Nạp batch kế tiếp + SO SÁNH số liệu trước/sau (cho demo auto-update)
#
# Dùng khi demo "dashboard tự cập nhật sau mỗi run":
#   1) chụp số TRƯỚC
#   2) trigger 1 run daily (pick_batch tự cuốn batch kế tiếp)
#   3) đợi run xanh
#   4) chụp số SAU + in bảng so sánh có delta
#
# Cách chạy:  ./scripts/demo_batch.sh          (nạp + so sánh)
#             ./scripts/demo_batch.sh --snap    (chỉ chụp số hiện tại, KHÔNG nạp)
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

PSQL="docker compose exec -T postgres psql -U ${APP_DB_USER} -d ${APP_DB} -tAc"
ASCHED="docker compose exec -T airflow-scheduler"
DAG="olist_daily_pipeline"

# --- chụp 4 số cốt lõi, phân tách bằng | ---
snapshot() {
  $PSQL "SELECT
      (SELECT COUNT(DISTINCT batch_id) FROM ops.load_audit WHERE batch_id LIKE 'batch_%'),
      (SELECT COUNT(*) FROM mart.fct_order_items),
      (SELECT COALESCE(ROUND(SUM(item_revenue)),0)::bigint FROM mart.fct_order_items),
      (SELECT COUNT(*) FROM ops.rejected_rows),
      (SELECT COALESCE(MAX(batch_id),'(chua co)') FROM ops.load_audit WHERE batch_id LIKE 'batch_%');"
}

# --- thêm dấu phẩy ngăn nghìn ---
commafy() { echo "$1" | sed -E ':a;s/([0-9])([0-9]{3})($|[^0-9])/\1,\2\3/;ta'; }

# --- in 1 dòng so sánh: nhãn | trước | sau ---
row() {
  local label="$1" before="$2" after="$3" delta
  delta=$(( after - before ))
  local sign="+"; [ "$delta" -lt 0 ] && sign=""
  printf "  %-22s | %14s | %14s | %s%s\n" \
    "$label" "$(commafy "$before")" "$(commafy "$after")" "$sign" "$(commafy "$delta")"
}

# ---------------------------------------------------------------------------
# Chế độ chỉ chụp
# ---------------------------------------------------------------------------
IFS='|' read -r b_batches b_fct b_rev b_rej b_max <<< "$(snapshot)"

if [ "${1:-}" = "--snap" ]; then
  echo "===== SNAPSHOT (không nạp gì) ====="
  echo "  Batch đã nạp     : $b_batches   (mới nhất: $b_max)"
  echo "  fct_order_items  : $(commafy "$b_fct")"
  echo "  Doanh thu        : $(commafy "$b_rev")"
  echo "  Dòng lỗi reject  : $(commafy "$b_rej")"
  exit 0
fi

echo "===== [1/3] SỐ TRƯỚC KHI NẠP ====="
echo "  Batch đã nạp: $b_batches (mới nhất: $b_max) | fct: $(commafy "$b_fct") | revenue: $(commafy "$b_rev") | reject: $(commafy "$b_rej")"

# ---------------------------------------------------------------------------
# Chạy ĐÚNG 1 run
#
# QUAN TRỌNG: KHÔNG dùng `dags unpause` + `dags trigger`. Unpause bật lịch */15
# nên scheduler tự đẻ thêm run `scheduled__...` -> một lần gọi ăn NHIỀU batch.
# Thay vào đó `dags test` chạy đúng 1 DagRun đồng bộ, kệ lịch, chạy được cả khi
# DAG đang paused. Ta còn chủ động `pause` để chắc chắn scheduler không xen vào.
# ---------------------------------------------------------------------------
echo ""
echo "===== [2/3] CHẠY 1 RUN (nạp batch kế tiếp) ====="
$ASCHED airflow dags pause "$DAG" >/dev/null 2>&1     # chặn scheduler đẻ run scheduled__
LOGICAL=$(date -u +%Y-%m-%dT%H:%M:%S)
echo "  đang chạy 1 run (logical_date=$LOGICAL) — chờ các task xong, ~1-2 phút..."
LOG=$(mktemp 2>/dev/null || echo "/tmp/demo_batch_$$.log")
if $ASCHED airflow dags test "$DAG" "$LOGICAL" >"$LOG" 2>&1; then
  echo "  -> RUN XONG (xanh)"
else
  echo "  -> RUN LỖI. 20 dòng log cuối:"; tail -20 "$LOG"; rm -f "$LOG"; exit 1
fi
rm -f "$LOG"

# ---------------------------------------------------------------------------
# So sánh
# ---------------------------------------------------------------------------
IFS='|' read -r a_batches a_fct a_rev a_rej a_max <<< "$(snapshot)"

echo ""
echo "===== [3/3] SO SÁNH TRƯỚC / SAU ====="
if [ "$a_batches" = "$b_batches" ]; then
  echo "  (Không có batch mới được nạp — có thể đã hết batch. pick_batch skip.)"
fi
echo "  Vừa nạp: $a_max"
echo ""
printf "  %-22s | %14s | %14s | %s\n" "CHỈ SỐ" "TRƯỚC" "SAU" "Δ"
echo "  -----------------------+----------------+----------------+-----------"
row "Batch đã nạp"        "$b_batches" "$a_batches"
row "fct_order_items"     "$b_fct"     "$a_fct"
row "Doanh thu (revenue)" "$b_rev"     "$a_rev"
row "Dòng lỗi (reject)"   "$b_rej"     "$a_rej"
echo ""
echo "  >> Mở Superset refresh dashboard: số phải nhảy đúng cột SAU."
echo "  >> Lưu evidence đợt này:  make evidence"
