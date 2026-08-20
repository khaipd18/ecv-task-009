# ============================================================================
# superset_config.py
#
# ***** ĐÂY LÀ FILE QUAN TRỌNG NHẤT CỦA CẢ BÀI *****
# Yêu cầu của chị Mentor là "dashboard tự động update dữ liệu mới".
# Mặc định Superset CACHE kết quả query. Nếu không tắt, Airflow chạy xong
# dữ liệu đã vào Postgres nhưng dashboard vẫn hiện số cũ -> demo hỏng đúng
# vào điểm chị quan tâm nhất.
# ============================================================================
import os

# ---------------------------------------------------------------------------
# Metadata database: dùng Postgres thay vì SQLite mặc định.
# SQLite nằm trong container, container chết là mất sạch chart/dashboard.
# ---------------------------------------------------------------------------
SQLALCHEMY_DATABASE_URI = os.environ["SUPERSET_DB_URI"]

SECRET_KEY = os.environ["SUPERSET_SECRET_KEY"]

# ---------------------------------------------------------------------------
# TẮT TOÀN BỘ CACHE
# Khi demo xong, nếu muốn thấy dashboard nhanh hơn có thể đổi sang
# SimpleCache với CACHE_DEFAULT_TIMEOUT = 10 (giây). Nhưng khi quay evidence
# thì để NullCache cho chắc.
# ---------------------------------------------------------------------------
_NO_CACHE = {"CACHE_TYPE": "NullCache"}

CACHE_CONFIG = _NO_CACHE                    # cache chung
DATA_CACHE_CONFIG = _NO_CACHE               # cache kết quả query của chart
FILTER_STATE_CACHE_CONFIG = _NO_CACHE       # cache trạng thái filter
EXPLORE_FORM_DATA_CACHE_CONFIG = _NO_CACHE  # cache form Explore

# Cache metadata bảng/cột — để 60s cho Superset nhận cột mới nhanh
SQLLAB_TIMEOUT = 300
SUPERSET_WEBSERVER_TIMEOUT = 300

# ---------------------------------------------------------------------------
# Cho phép dashboard tự refresh ở tần suất ngắn.
# Mặc định Superset chặn refresh nhanh hơn ngưỡng này và hiện cảnh báo.
# ---------------------------------------------------------------------------
SUPERSET_DASHBOARD_PERIODICAL_REFRESH_LIMIT = 10          # giây
SUPERSET_DASHBOARD_PERIODICAL_REFRESH_WARNING_MESSAGE = None

FEATURE_FLAGS = {
    "DASHBOARD_NATIVE_FILTERS": True,
    "DASHBOARD_CROSS_FILTERS": True,
    "ENABLE_TEMPLATE_PROCESSING": True,
}

# Số dòng tối đa trả về, để chart không kéo cả triệu dòng làm treo máy
ROW_LIMIT = 50000
SAMPLES_ROW_LIMIT = 1000

# Múi giờ hiển thị
import os as _os
_os.environ.setdefault("TZ", "Asia/Ho_Chi_Minh")
