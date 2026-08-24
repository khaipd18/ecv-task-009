-- =====================================================================
-- STAGING -> MART: ghép các bảng lại thành dạng sẵn sàng cho dashboard
-- Chạy TOÀN BỘ mỗi lần, không lọc theo batch.
-- Lý do: các chỉ số như "khách mua lại" hay "tổng chi tiêu" phụ thuộc
-- vào toàn bộ lịch sử, không tính riêng từng mẻ được.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 3 BẢNG CHIỀU
-- ---------------------------------------------------------------------

INSERT INTO mart.dim_product (
    product_id, category_pt, category_en,
    product_weight_g, product_volume_cm3, photos_qty
)
SELECT
    p.product_id,
    p.product_category_name,
    -- Nếu không có bản dịch tiếng Anh thì giữ nguyên tên tiếng Bồ,
    -- tránh để trống làm mất sản phẩm khỏi chart
    COALESCE(t.product_category_name_english, p.product_category_name),
    p.product_weight_g,
    p.product_length_cm::INTEGER * p.product_height_cm::INTEGER * p.product_width_cm::INTEGER,
    p.product_photos_qty
FROM staging.stg_products p
LEFT JOIN staging.stg_category_translation t
       ON t.product_category_name = p.product_category_name
ON CONFLICT (product_id) DO UPDATE SET
    category_pt = EXCLUDED.category_pt,
    category_en = EXCLUDED.category_en;

INSERT INTO mart.dim_seller (seller_id, seller_city, seller_state)
SELECT seller_id, seller_city, seller_state
FROM staging.stg_sellers
ON CONFLICT (seller_id) DO UPDATE SET
    seller_city  = EXCLUDED.seller_city,
    seller_state = EXCLUDED.seller_state;

-- Bảng khách hàng gộp theo customer_unique_id — ĐÂY mới là khách thật.
-- customer_id chỉ là mã sinh ra cho từng đơn, dùng nhầm là sai hết
-- mọi phân tích về khách hàng.
INSERT INTO mart.dim_customer (
    customer_unique_id, customer_city, customer_state,
    first_order_date, total_orders, total_spent
)
SELECT
    c.customer_unique_id,
    MIN(c.customer_city),
    MIN(c.customer_state),
    MIN(o.order_purchase_timestamp)::DATE,
    COUNT(DISTINCT o.order_id),
    COALESCE(SUM(i.price + i.freight_value), 0)
FROM staging.stg_customers c
JOIN staging.stg_orders o     ON o.customer_id = c.customer_id
LEFT JOIN staging.stg_order_items i ON i.order_id = o.order_id
GROUP BY c.customer_unique_id
ON CONFLICT (customer_unique_id) DO UPDATE SET
    first_order_date = EXCLUDED.first_order_date,
    total_orders     = EXCLUDED.total_orders,
    total_spent      = EXCLUDED.total_spent;

-- ---------------------------------------------------------------------
-- BẢNG FACT 1: mỗi dòng là MỘT SẢN PHẨM trong MỘT ĐƠN
-- Dùng cho phân tích doanh thu, sản phẩm, người bán
-- ---------------------------------------------------------------------

INSERT INTO mart.fct_order_items (
    order_id, order_item_id, product_id, seller_id,
    customer_id, customer_unique_id,
    order_purchase_timestamp, order_purchase_date,
    price, freight_value, item_revenue,
    order_status, category_pt, category_en,
    customer_state, customer_city, seller_state, seller_city,
    price_segment, is_cross_state, freight_ratio,
    batch_id
)
SELECT
    i.order_id,
    i.order_item_id,
    i.product_id,
    i.seller_id,
    o.customer_id,
    c.customer_unique_id,
    o.order_purchase_timestamp,
    o.order_purchase_timestamp::DATE,
    i.price,
    i.freight_value,
    i.price + i.freight_value,
    o.order_status,
    COALESCE(p.category_pt, 'sem_categoria'),
    COALESCE(p.category_en, 'no_category'),
    c.customer_state,
    c.customer_city,
    s.seller_state,
    s.seller_city,
    -- Phân khúc giá — cột dẫn xuất, không có trong dữ liệu gốc.
    -- Đây là thứ đáp ứng yêu cầu "filter theo phân khúc giá" của mentor.
    -- Mốc chia dựa trên phân bố giá thực tế của Olist.
    CASE
        WHEN i.price < 50  THEN 'Budget'
        WHEN i.price < 150 THEN 'Mid-range'
        ELSE 'Premium'
    END,
    -- Đơn liên bang hay nội bang — ảnh hưởng lớn tới thời gian giao
    (c.customer_state IS DISTINCT FROM s.seller_state),
    -- Tỷ trọng phí ship trên tổng giá trị. Chia cho 0 thì để NULL.
    CASE WHEN (i.price + i.freight_value) > 0
         THEN ROUND(i.freight_value / (i.price + i.freight_value), 4) END,
    i.batch_id
FROM staging.stg_order_items i
JOIN staging.stg_orders o    ON o.order_id = i.order_id
JOIN staging.stg_customers c ON c.customer_id = o.customer_id
LEFT JOIN mart.dim_product p ON p.product_id = i.product_id
LEFT JOIN mart.dim_seller s  ON s.seller_id  = i.seller_id
-- Loại đơn huỷ và đơn không khả dụng khỏi doanh thu.
-- Chốt một lần ở đây, không để người xem dashboard phải tự nhớ lọc.
WHERE o.order_status NOT IN ('canceled', 'unavailable')
ON CONFLICT (order_id, order_item_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- BẢNG FACT 2: mỗi dòng là MỘT ĐƠN HÀNG
-- Dùng cho phân tích thanh toán, review, giao hàng.
--
-- Vì sao phải tách khỏi bảng trên: một đơn có 3 sản phẩm và 2 lần
-- thanh toán. Ghép chung sẽ thành 6 dòng và doanh thu bị nhân đôi.
-- Gộp payments về 1 dòng trước rồi mới join là cách tránh.
-- ---------------------------------------------------------------------

WITH gop_thanh_toan AS (
    SELECT
        order_id,
        SUM(payment_value)        AS payment_value,
        MAX(payment_installments) AS max_installments,
        -- Lấy loại thanh toán có giá trị lớn nhất làm loại chính
        (ARRAY_AGG(payment_type ORDER BY payment_value DESC))[1] AS payment_type_main
    FROM staging.stg_order_payments
    GROUP BY order_id
),
gop_review AS (
    -- Một đơn có thể có nhiều review, lấy cái mới nhất
    SELECT DISTINCT ON (order_id)
        order_id, review_score
    FROM staging.stg_order_reviews
    ORDER BY order_id, review_creation_date DESC NULLS LAST
),
gop_item AS (
    SELECT
        order_id,
        COUNT(*)                        AS item_count,
        SUM(price + freight_value)      AS order_revenue
    FROM staging.stg_order_items
    GROUP BY order_id
)
INSERT INTO mart.fct_orders (
    order_id, customer_id, customer_unique_id, order_status,
    order_purchase_timestamp, order_purchase_date,
    order_delivered_customer_date, order_estimated_delivery_date,
    delivery_days, delay_days, is_late,
    item_count, order_revenue,
    payment_value, payment_type_main, max_installments,
    review_score, is_repeat_customer, batch_id
)
SELECT
    o.order_id,
    o.customer_id,
    c.customer_unique_id,
    o.order_status,
    o.order_purchase_timestamp,
    o.order_purchase_timestamp::DATE,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    -- 3 chỉ số giao hàng CHỈ tính cho đơn đã giao.
    -- Đơn đang trên đường thì chưa có ngày nhận, tính ra số vô nghĩa.
    CASE WHEN o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
         THEN (o.order_delivered_customer_date::DATE - o.order_purchase_timestamp::DATE) END,
    CASE WHEN o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
         THEN (o.order_delivered_customer_date::DATE - o.order_estimated_delivery_date::DATE) END,
    CASE WHEN o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
         THEN o.order_delivered_customer_date > o.order_estimated_delivery_date END,
    COALESCE(gi.item_count, 0),
    COALESCE(gi.order_revenue, 0),
    gt.payment_value,
    gt.payment_type_main,
    gt.max_installments,
    gr.review_score,
    -- Đánh dấu khách mua lại: đếm theo customer_unique_id.
    -- Chỉ khoảng 3% khách Olist mua từ 2 đơn trở lên.
    (dc.total_orders > 1),
    o.batch_id
FROM staging.stg_orders o
JOIN staging.stg_customers c  ON c.customer_id = o.customer_id
LEFT JOIN gop_item        gi  ON gi.order_id = o.order_id
LEFT JOIN gop_thanh_toan  gt  ON gt.order_id = o.order_id
LEFT JOIN gop_review      gr  ON gr.order_id = o.order_id
LEFT JOIN mart.dim_customer dc ON dc.customer_unique_id = c.customer_unique_id
WHERE o.order_status NOT IN ('canceled', 'unavailable')
ON CONFLICT (order_id) DO UPDATE SET
    -- Cập nhật lại vì trạng thái đơn và review có thể đổi ở batch sau
    order_status                  = EXCLUDED.order_status,
    order_delivered_customer_date = EXCLUDED.order_delivered_customer_date,
    delivery_days                 = EXCLUDED.delivery_days,
    delay_days                    = EXCLUDED.delay_days,
    is_late                       = EXCLUDED.is_late,
    review_score                  = EXCLUDED.review_score,
    is_repeat_customer            = EXCLUDED.is_repeat_customer;
