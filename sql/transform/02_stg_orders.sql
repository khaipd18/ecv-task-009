-- =====================================================================
-- RAW -> STAGING cho 4 bảng động, chạy MỖI LẦN Airflow trigger
-- Tham số :batch_id được truyền từ dòng lệnh psql -v batch_id=...
--
-- Nguyên tắc: dòng nào hỏng thì đẩy sang ops.rejected_rows kèm lý do,
-- KHÔNG để một dòng xấu làm fail cả batch.
-- =====================================================================

-- ---------------------------------------------------------------------
-- ORDERS
-- ---------------------------------------------------------------------

-- Bắt lỗi trước: ghi lại các dòng không parse được timestamp.
-- Phải làm TRƯỚC khi insert, vì sau khi insert thì dòng xấu đã bị loại rồi.
INSERT INTO ops.rejected_rows (batch_id, source_table, reject_reason, raw_payload)
SELECT
    :'batch_id',
    'raw.raw_orders',
    CASE
        WHEN order_id IS NULL OR TRIM(order_id) = '' THEN 'order_id rong'
        WHEN customer_id IS NULL OR TRIM(customer_id) = '' THEN 'customer_id rong'
        ELSE 'order_purchase_timestamp sai dinh dang'
    END,
    to_jsonb(r)
FROM raw.raw_orders r
WHERE batch_id = :'batch_id'
  AND (
      order_id IS NULL OR TRIM(order_id) = ''
      OR customer_id IS NULL OR TRIM(customer_id) = ''
      -- Chỉ chấp nhận đúng định dạng ISO. Dòng bị đổi sang MM/DD/YYYY sẽ rơi vào đây.
      OR order_purchase_timestamp !~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
  );

INSERT INTO staging.stg_orders (
    order_id, customer_id, order_status,
    order_purchase_timestamp, order_approved_at,
    order_delivered_carrier_date, order_delivered_customer_date,
    order_estimated_delivery_date, batch_id, ingested_at
)
SELECT DISTINCT ON (TRIM(order_id))
    TRIM(order_id),
    TRIM(customer_id),
    -- Chuẩn hoá status: dòng bị làm bẩn có dạng '  DELIVERED ' -> 'delivered'
    LOWER(TRIM(order_status)),
    order_purchase_timestamp::TIMESTAMP,
    -- 4 cột thời gian còn lại được phép NULL, sai định dạng thì để NULL
    CASE WHEN order_approved_at ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
         THEN order_approved_at::TIMESTAMP END,
    CASE WHEN order_delivered_carrier_date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
         THEN order_delivered_carrier_date::TIMESTAMP END,
    CASE WHEN order_delivered_customer_date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
         THEN order_delivered_customer_date::TIMESTAMP END,
    CASE WHEN order_estimated_delivery_date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
         THEN order_estimated_delivery_date::TIMESTAMP END,
    batch_id,
    ingested_at
FROM raw.raw_orders
WHERE batch_id = :'batch_id'
  AND order_id IS NOT NULL AND TRIM(order_id) <> ''
  AND customer_id IS NOT NULL AND TRIM(customer_id) <> ''
  AND order_purchase_timestamp ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
-- DISTINCT ON xử lý dòng trùng NGAY TRONG một batch (do generate_batch chèn vào).
-- Lấy bản ghi nạp sau cùng.
ORDER BY TRIM(order_id), ingested_at DESC
ON CONFLICT (order_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- ORDER ITEMS
-- ---------------------------------------------------------------------

INSERT INTO ops.rejected_rows (batch_id, source_table, reject_reason, raw_payload)
SELECT
    :'batch_id',
    'raw.raw_order_items',
    CASE
        WHEN price !~ '^-?\d+(\.\d+)?$' THEN 'price khong phai so'
        WHEN price::NUMERIC < 0 THEN 'price am'
        WHEN freight_value IS NULL OR TRIM(freight_value) = '' THEN 'freight_value rong'
        WHEN freight_value !~ '^-?\d+(\.\d+)?$' THEN 'freight_value khong phai so'
        WHEN freight_value::NUMERIC < 0 THEN 'freight_value am'
        ELSE 'khong tim thay don hang cha'
    END,
    to_jsonb(r)
FROM raw.raw_order_items r
WHERE batch_id = :'batch_id'
  AND (
      price IS NULL OR price !~ '^-?\d+(\.\d+)?$' OR price::NUMERIC < 0
      OR freight_value IS NULL OR TRIM(freight_value) = ''
      OR freight_value !~ '^-?\d+(\.\d+)?$' OR freight_value::NUMERIC < 0
      OR NOT EXISTS (SELECT 1 FROM staging.stg_orders o WHERE o.order_id = TRIM(r.order_id))
  );

INSERT INTO staging.stg_order_items (
    order_id, order_item_id, product_id, seller_id,
    shipping_limit_date, price, freight_value, batch_id, ingested_at
)
SELECT DISTINCT ON (TRIM(order_id), order_item_id::SMALLINT)
    TRIM(order_id),
    order_item_id::SMALLINT,
    TRIM(product_id),
    TRIM(seller_id),
    CASE WHEN shipping_limit_date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
         THEN shipping_limit_date::TIMESTAMP END,
    price::NUMERIC(12,2),
    freight_value::NUMERIC(12,2),
    batch_id,
    ingested_at
FROM raw.raw_order_items r
WHERE batch_id = :'batch_id'
  AND order_item_id ~ '^\d+$'
  AND price ~ '^\d+(\.\d+)?$'
  AND freight_value ~ '^\d+(\.\d+)?$'
  -- Chặn dòng con mồ côi: item phải có đơn cha đã vào staging
  AND EXISTS (SELECT 1 FROM staging.stg_orders o WHERE o.order_id = TRIM(r.order_id))
ORDER BY TRIM(order_id), order_item_id::SMALLINT, ingested_at DESC
ON CONFLICT (order_id, order_item_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- ORDER PAYMENTS
-- ---------------------------------------------------------------------

INSERT INTO ops.rejected_rows (batch_id, source_table, reject_reason, raw_payload)
SELECT
    :'batch_id',
    'raw.raw_order_payments',
    CASE
        WHEN payment_value !~ '^-?\d+(\.\d+)?$' THEN 'payment_value khong phai so'
        WHEN payment_value::NUMERIC < 0 THEN 'payment_value am'
        ELSE 'khong tim thay don hang cha'
    END,
    to_jsonb(r)
FROM raw.raw_order_payments r
WHERE batch_id = :'batch_id'
  AND (
      payment_value IS NULL OR payment_value !~ '^-?\d+(\.\d+)?$'
      OR payment_value::NUMERIC < 0
      OR NOT EXISTS (SELECT 1 FROM staging.stg_orders o WHERE o.order_id = TRIM(r.order_id))
  );

INSERT INTO staging.stg_order_payments (
    order_id, payment_sequential, payment_type,
    payment_installments, payment_value, batch_id, ingested_at
)
SELECT DISTINCT ON (TRIM(order_id), payment_sequential::SMALLINT)
    TRIM(order_id),
    payment_sequential::SMALLINT,
    -- Chuẩn hoá: 'CREDIT_CARD ' và 'credit_card' phải gộp thành một nhóm,
    -- nếu không chart cơ cấu thanh toán sẽ tách đôi
    LOWER(TRIM(payment_type)),
    CASE WHEN payment_installments ~ '^\d+$' THEN payment_installments::SMALLINT ELSE 0 END,
    payment_value::NUMERIC(12,2),
    batch_id,
    ingested_at
FROM raw.raw_order_payments r
WHERE batch_id = :'batch_id'
  AND payment_sequential ~ '^\d+$'
  AND payment_value ~ '^\d+(\.\d+)?$'
  AND EXISTS (SELECT 1 FROM staging.stg_orders o WHERE o.order_id = TRIM(r.order_id))
ORDER BY TRIM(order_id), payment_sequential::SMALLINT, ingested_at DESC
ON CONFLICT (order_id, payment_sequential) DO NOTHING;

-- ---------------------------------------------------------------------
-- ORDER REVIEWS
-- ---------------------------------------------------------------------

INSERT INTO ops.rejected_rows (batch_id, source_table, reject_reason, raw_payload)
SELECT
    :'batch_id',
    'raw.raw_order_reviews',
    CASE
        WHEN review_score !~ '^-?\d+$' THEN 'review_score khong phai so'
        WHEN review_score::INT NOT BETWEEN 1 AND 5 THEN 'review_score ngoai khoang 1-5'
        ELSE 'khong tim thay don hang cha'
    END,
    to_jsonb(r)
FROM raw.raw_order_reviews r
WHERE batch_id = :'batch_id'
  AND (
      review_score IS NULL OR review_score !~ '^-?\d+$'
      OR review_score::INT NOT BETWEEN 1 AND 5
      OR NOT EXISTS (SELECT 1 FROM staging.stg_orders o WHERE o.order_id = TRIM(r.order_id))
  );

INSERT INTO staging.stg_order_reviews (
    review_id, order_id, review_score,
    review_comment_title, review_comment_message,
    review_creation_date, review_answer_timestamp, batch_id, ingested_at
)
SELECT DISTINCT ON (TRIM(review_id), TRIM(order_id))
    TRIM(review_id),
    TRIM(order_id),
    review_score::SMALLINT,
    NULLIF(TRIM(review_comment_title), ''),
    NULLIF(TRIM(review_comment_message), ''),
    CASE WHEN review_creation_date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
         THEN review_creation_date::TIMESTAMP END,
    CASE WHEN review_answer_timestamp ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
         THEN review_answer_timestamp::TIMESTAMP END,
    batch_id,
    ingested_at
FROM raw.raw_order_reviews r
WHERE batch_id = :'batch_id'
  AND review_id IS NOT NULL AND TRIM(review_id) <> ''
  AND review_score ~ '^\d+$'
  AND review_score::INT BETWEEN 1 AND 5
  AND EXISTS (SELECT 1 FROM staging.stg_orders o WHERE o.order_id = TRIM(r.order_id))
ORDER BY TRIM(review_id), TRIM(order_id), ingested_at DESC
ON CONFLICT (review_id, order_id) DO NOTHING;
