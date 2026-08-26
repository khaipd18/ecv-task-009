import pandas as pd
import glob
import os

# Thư mục chứa 9 file CSV — mặc định là thư mục đang đứng
DATA_DIR = "."

# Bắt file theo pattern thay vì gõ cứng tên,
# vì tên file tải từ Kaggle đôi khi khác nhau chút
def tim_file(tu_khoa):
    ket_qua = glob.glob(os.path.join(DATA_DIR, f"*{tu_khoa}*.csv"))
    return ket_qua[0] if ket_qua else None

# Đọc từng file, file nào không thấy thì bỏ qua chứ không cho crash
def doc(tu_khoa):
    duong_dan = tim_file(tu_khoa)
    if duong_dan is None:
        print(f"  [!] Không tìm thấy file chứa '{tu_khoa}'")
        return None
    return pd.read_csv(duong_dan)

print("=" * 70)
print("PHẦN 0 — DANH SÁCH FILE VÀ KÍCH THƯỚC")
print("=" * 70)

# Liệt kê mọi file csv kèm số dòng, số cột để đối chiếu với tài liệu Kaggle
for f in sorted(glob.glob(os.path.join(DATA_DIR, "*.csv"))):
    df_tam = pd.read_csv(f)
    print(f"{os.path.basename(f):50s} {df_tam.shape[0]:>8,} dòng  {df_tam.shape[1]:>3} cột")

# Nạp các bảng chính, dùng lại cho toàn bộ phần dưới
orders = doc("orders_dataset")
items = doc("order_items")
customers = doc("customers")
products = doc("products_dataset")
translation = doc("category_name_translation")

print()
print("=" * 70)
print("PHẦN 1 — DANH SÁCH CỘT VÀ KIỂU DỮ LIỆU (để viết DDL)")
print("=" * 70)

# In dtype + số ô rỗng + 1 giá trị mẫu cho từng cột của từng bảng.
# Đây chính là nguyên liệu để viết file dataset.md nộp cho chị.
bang_can_xem = {
    "orders": orders,
    "order_items": items,
    "customers": customers,
    "products": products,
}

for ten_bang, df in bang_can_xem.items():
    if df is None:
        continue
    print(f"\n--- {ten_bang} ({len(df):,} dòng) ---")
    for cot in df.columns:
        so_null = df[cot].isna().sum()
        ty_le_null = so_null / len(df) * 100
        # Lấy 1 giá trị không rỗng làm ví dụ, cắt ngắn cho dễ nhìn
        mau = df[cot].dropna()
        vi_du = str(mau.iloc[0])[:35] if len(mau) > 0 else "(toàn rỗng)"
        print(f"  {cot:35s} {str(df[cot].dtype):10s} null={ty_le_null:5.1f}%  vd: {vi_du}")

print()
print("=" * 70)
print("PHẦN 2 — 5 CON SỐ QUYẾT ĐỊNH THIẾT KẾ")
print("=" * 70)

# --- Con số 1: tỷ lệ khách mua lại ---
# Quan trọng: phải đếm theo customer_unique_id, KHÔNG phải customer_id,
# vì Olist sinh customer_id mới cho mỗi đơn hàng
if customers is not None and orders is not None:
    ghep = orders.merge(customers[["customer_id", "customer_unique_id"]], on="customer_id", how="left")
    so_don_moi_khach = ghep.groupby("customer_unique_id")["order_id"].nunique()
    tong_khach = len(so_don_moi_khach)
    khach_mua_lai = (so_don_moi_khach > 1).sum()
    print(f"\n1. KHÁCH MUA LẠI")
    print(f"   Tổng khách thật (customer_unique_id): {tong_khach:,}")
    print(f"   Tổng customer_id (đếm sai nếu dùng cái này): {customers['customer_id'].nunique():,}")
    print(f"   Khách mua từ 2 đơn trở lên: {khach_mua_lai:,} ({khach_mua_lai/tong_khach*100:.2f}%)")
    print(f"   -> Nếu dưới 5% thì Tab 5 (RFM/retention) nên thu nhỏ lại")

# --- Con số 2: tỷ lệ đơn bị huỷ / không khả dụng ---
# Dùng để quyết định điều kiện lọc trong view mart
if orders is not None:
    print(f"\n2. TRẠNG THÁI ĐƠN")
    phan_bo = orders["order_status"].value_counts()
    for trang_thai, so_luong in phan_bo.items():
        print(f"   {trang_thai:20s} {so_luong:>8,}  ({so_luong/len(orders)*100:5.2f}%)")

# --- Con số 3: category thiếu bản dịch tiếng Anh ---
if products is not None and translation is not None:
    cat_trong_products = set(products["product_category_name"].dropna().unique())
    cat_co_dich = set(translation["product_category_name"].unique())
    thieu_dich = cat_trong_products - cat_co_dich
    print(f"\n3. CATEGORY")
    print(f"   Số category trong products: {len(cat_trong_products)}")
    print(f"   Số category có bản dịch: {len(cat_co_dich)}")
    print(f"   Thiếu bản dịch: {len(thieu_dich)} -> {sorted(thieu_dich) if thieu_dich else 'không thiếu'}")
    print(f"   Sản phẩm không có category: {products['product_category_name'].isna().sum():,}")

# --- Con số 4: mật độ đơn theo ngày ---
# Đây là con số quyết định 1 batch nên gộp mấy ngày
if orders is not None:
    orders["ngay_mua"] = pd.to_datetime(orders["order_purchase_timestamp"], errors="coerce")
    theo_ngay = orders.groupby(orders["ngay_mua"].dt.date).size()
    print(f"\n4. MẬT ĐỘ ĐƠN THEO NGÀY")
    print(f"   Khoảng thời gian: {orders['ngay_mua'].min()} -> {orders['ngay_mua'].max()}")
    print(f"   Tổng số ngày có đơn: {len(theo_ngay):,}")
    print(f"   Đơn/ngày — trung bình: {theo_ngay.mean():.0f}, trung vị: {theo_ngay.median():.0f}")
    print(f"   Đơn/ngày — thấp nhất: {theo_ngay.min()}, cao nhất: {theo_ngay.max()}")
    # Xem 10 ngày cuối để biết giai đoạn nào dữ liệu dày, dùng làm vùng cắt batch
    print(f"   Số ngày có dưới 50 đơn: {(theo_ngay < 50).sum()}")
    print(f"   -> Nếu trung vị dưới 100 đơn/ngày thì nên gộp 3-7 ngày thành 1 batch")

# --- Con số 5: kiểm tra khoá và độ trùng ---
# Xác nhận (order_id, order_item_id) đúng là khoá duy nhất của bảng fact
if items is not None and orders is not None:
    trung_khoa = items.duplicated(subset=["order_id", "order_item_id"]).sum()
    print(f"\n5. KHOÁ VÀ QUAN HỆ")
    print(f"   order_items: {len(items):,} dòng")
    print(f"   Số dòng trùng khoá (order_id, order_item_id): {trung_khoa}")
    print(f"   -> Phải bằng 0 thì UNIQUE constraint mới đặt được")
    # Kiểm tra có order_item nào mồ côi không (không tìm thấy order cha)
    mo_coi = ~items["order_id"].isin(orders["order_id"])
    print(f"   order_items không có order cha: {mo_coi.sum():,}")
    print(f"   Số item trung bình mỗi đơn: {len(items)/items['order_id'].nunique():.2f}")

print()
print("=" * 70)
print("XONG — copy toàn bộ output này gửi lại")
print("=" * 70)
# Đếm số đơn theo từng tháng để chọn mốc cắt seed/incremental

print("\n=== SỐ ĐƠN THEO THÁNG ===")
theo_thang = orders.groupby(orders["ngay_mua"].dt.to_period("M")).size()
for thang, so_don in theo_thang.items():
    print(f"   {thang}  {so_don:>7,}")