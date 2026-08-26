-- =====================================================================
-- RAW -> STAGING cho 4 bảng tĩnh (products, customers, sellers, translation)
-- Chỉ chạy MỘT LẦN sau bước seed, không nằm trong DAG chạy hằng ngày
-- =====================================================================

-- ---------- Bảng dịch category ----------
TRUNCATE staging.stg_category_translation;

INSERT INTO staging.stg_category_translation (product_category_name, product_category_name_english)
SELECT
    LOWER(TRIM(product_category_name)),
    LOWER(TRIM(product_category_name_english))
FROM raw.raw_category_translation
WHERE product_category_name IS NOT NULL
ON CONFLICT (product_category_name) DO NOTHING;

-- ---------- Sellers ----------
TRUNCATE staging.stg_sellers;

INSERT INTO staging.stg_sellers (
    seller_id, seller_zip_code_prefix, seller_city, seller_state, batch_id, ingested_at
)
SELECT
    TRIM(seller_id),
    TRIM(seller_zip_code_prefix),
    LOWER(TRIM(seller_city)),
    -- Ép về đúng 2 ký tự viết hoa, sai độ dài thì để NULL còn hơn để rác
    CASE WHEN LENGTH(TRIM(seller_state)) = 2 THEN UPPER(TRIM(seller_state)) END,
    batch_id,
    ingested_at
FROM raw.raw_sellers
WHERE seller_id IS NOT NULL AND TRIM(seller_id) <> ''
ON CONFLICT (seller_id) DO NOTHING;

-- ---------- Customers ----------
TRUNCATE staging.stg_customers;

INSERT INTO staging.stg_customers (
    customer_id, customer_unique_id, customer_zip_code_prefix,
    customer_city, customer_state, batch_id, ingested_at
)
SELECT
    TRIM(customer_id),
    TRIM(customer_unique_id),
    TRIM(customer_zip_code_prefix),
    LOWER(TRIM(customer_city)),
    CASE WHEN LENGTH(TRIM(customer_state)) = 2 THEN UPPER(TRIM(customer_state)) END,
    batch_id,
    ingested_at
FROM raw.raw_customers
WHERE customer_id IS NOT NULL AND TRIM(customer_id) <> ''
  AND customer_unique_id IS NOT NULL
ON CONFLICT (customer_id) DO NOTHING;

-- ---------- Products ----------
TRUNCATE staging.stg_products;

INSERT INTO staging.stg_products (
    product_id, product_category_name,
    product_name_lenght, product_description_lenght, product_photos_qty,
    product_weight_g, product_length_cm, product_height_cm, product_width_cm,
    batch_id, ingested_at
)
SELECT
    TRIM(product_id),
    -- Xử lý 2 vấn đề cùng lúc:
    --   1. category bị làm bẩn ở seed (thừa khoảng trắng, viết hoa) -> LOWER + TRIM
    --   2. 610 sản phẩm không có category -> gán 'sem_categoria' để vẫn lên chart
    COALESCE(NULLIF(LOWER(TRIM(product_category_name)), ''), 'sem_categoria'),
    -- Ép số an toàn: khớp regex trước, không khớp thì NULL thay vì làm fail cả batch
    CASE WHEN product_name_lenght        ~ '^\d+(\.\d+)?$' THEN product_name_lenght::NUMERIC::SMALLINT END,
    CASE WHEN product_description_lenght ~ '^\d+(\.\d+)?$' THEN product_description_lenght::NUMERIC::INTEGER END,
    CASE WHEN product_photos_qty         ~ '^\d+(\.\d+)?$' THEN product_photos_qty::NUMERIC::SMALLINT END,
    CASE WHEN product_weight_g           ~ '^\d+(\.\d+)?$' THEN product_weight_g::NUMERIC::INTEGER END,
    CASE WHEN product_length_cm          ~ '^\d+(\.\d+)?$' THEN product_length_cm::NUMERIC::SMALLINT END,
    CASE WHEN product_height_cm          ~ '^\d+(\.\d+)?$' THEN product_height_cm::NUMERIC::SMALLINT END,
    CASE WHEN product_width_cm           ~ '^\d+(\.\d+)?$' THEN product_width_cm::NUMERIC::SMALLINT END,
    batch_id,
    ingested_at
FROM raw.raw_products
WHERE product_id IS NOT NULL AND TRIM(product_id) <> ''
ON CONFLICT (product_id) DO NOTHING;
