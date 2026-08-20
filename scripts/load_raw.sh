#!/bin/bash
# =====================================================================
# load_raw.sh — nạp một thư mục batch vào tầng raw
# Cách dùng: ./scripts/load_raw.sh <đường dẫn trong container> <batch_id>
# Ví dụ:     ./scripts/load_raw.sh /data/batches/seed seed
# =====================================================================

set -e
THU_MUC=$1
BATCH_ID=$2

if [ -z "$THU_MUC" ] || [ -z "$BATCH_ID" ]; then
  echo "Thiếu tham số. Cú pháp: $0 <thư_mục> <batch_id>"
  exit 1
fi

PSQL="docker exec -i olist-dev psql -U postgres -d olist -v ON_ERROR_STOP=1 -q"

# Hàm nạp một file CSV vào một bảng raw.
# Kỹ thuật: tạm đặt DEFAULT cho cột batch_id trước khi copy,
# vì file CSV không có cột này. Copy xong thì gỡ default ra ngay
# để lần nạp sau không bị dính batch_id cũ.
nap() {
  local ten_file=$1
  local ten_bang=$2
  local danh_sach_cot=$3

  if [ ! -f "$(pwd)/data/${THU_MUC#/data/}/$ten_file" ]; then
    echo "  (bỏ qua $ten_file — không có trong batch này)"
    return
  fi

  echo "  -> $ten_bang"
  $PSQL <<SQL
ALTER TABLE $ten_bang ALTER COLUMN batch_id SET DEFAULT '$BATCH_ID';
\copy $ten_bang ($danh_sach_cot) FROM '$THU_MUC/$ten_file' WITH (FORMAT csv, HEADER true)
ALTER TABLE $ten_bang ALTER COLUMN batch_id DROP DEFAULT;
SQL
}

echo "Nạp batch: $BATCH_ID từ $THU_MUC"

# ---------- 4 bảng động, có trong mọi batch ----------
nap "orders.csv" "raw.raw_orders" \
  "order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at, order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date"

nap "order_items.csv" "raw.raw_order_items" \
  "order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value"

nap "order_payments.csv" "raw.raw_order_payments" \
  "order_id, payment_sequential, payment_type, payment_installments, payment_value"

nap "order_reviews.csv" "raw.raw_order_reviews" \
  "review_id, order_id, review_score, review_comment_title, review_comment_message, review_creation_date, review_answer_timestamp"

# ---------- 4 bảng tĩnh, chỉ có trong thư mục seed ----------
nap "products.csv" "raw.raw_products" \
  "product_id, product_category_name, product_name_lenght, product_description_lenght, product_photos_qty, product_weight_g, product_length_cm, product_height_cm, product_width_cm"

nap "customers.csv" "raw.raw_customers" \
  "customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state"

nap "sellers.csv" "raw.raw_sellers" \
  "seller_id, seller_zip_code_prefix, seller_city, seller_state"

nap "category_translation.csv" "raw.raw_category_translation" \
  "product_category_name, product_category_name_english"

echo "Xong batch $BATCH_ID"