# Bắt buộc chọn thư mục tải xuống — thiết kế ngắn

## Mục đích

Người dùng phải tự chọn nơi chứa file tải về trước khi tải được bất cứ thứ gì.
App không còn tự lưu vào `<app support>/downloads` mà không hỏi.

## Mục tiêu / ngoài phạm vi

- Chọn **một lần**; lưu trên thiết bị; đổi được trong Cài đặt › Tải xuống.
- Chưa chọn thì không tải: bấm Tải xuống (một mục, "Tải tất cả", chọn nhiều)
  sẽ mở hộp chọn trước; huỷ hộp chọn = không tải gì.
- Ngoài phạm vi: thư mục riêng cho từng lượt tải; thư mục tuỳ ý trên Android
  (SAF `content://`); giới hạn dung lượng.

## Các hướng đã cân nhắc

1. **Một thư mục gốc, chọn một lần (đã chọn).** `DownloadStore` vẫn có một
   `root`; chỉ đổi nơi `root` trỏ tới. Engine, resume bằng `Range`, phát
   offline bằng `file://` giữ nguyên.
2. Hỏi mỗi lần tải: mỗi bản ghi phải nhớ đường dẫn riêng, "Tải tất cả" hỏi
   lặp lại. Người dùng đã loại.
3. SAF trên Android: phải viết lại phần ghi file và phần phát qua Kotlin.
   Quá lớn so với nhu cầu.

## Thiết kế

- **Cài đặt**: `DownloadSettings.folder` (`String?`, khoá
  `downloads_folder_v1`, `shared_preferences`). `null` = chưa chọn.
- **Nơi lưu**: `downloadStoreProvider` dùng `folder` nếu có; nếu chưa có thì
  vẫn mở thư mục cũ trong app support để các bản đã tải trước đây còn phát
  được, nhưng không tải thêm được vào đó.
- **Hộp chọn** (`downloadFolderPickerProvider`, thay được trong test):
  - Windows / Linux: hộp chọn thư mục của hệ điều hành (thêm lại
    `file_selector`). File nằm trong thư mục con `Kumo` của thư mục được chọn,
    để `index.json` và các thư mục GUID không lẫn vào file của người dùng.
  - Android và các nền tảng khác: hộp thoại liệt kê các ổ app ghi được —
    bộ nhớ trong và từng thẻ SD (`getExternalStorageDirectories`), kèm dung
    lượng trống nếu đọc được. Vẫn là đường dẫn file thật.
- **Cổng chặn**: một hàm `ensureDownloadFolder(context, ref)` gọi ở hai chỗ
  `enqueue` trong `item_actions.dart`. Trả `false` thì dừng.
- **Đổi thư mục / lần chọn đầu khi đã có bản tải**: dừng hàng đợi, chuyển cả
  cây thư mục sang chỗ mới (đổi tên nếu cùng ổ, không thì chép rồi xoá, có
  hộp tiến trình), rồi mở lại store. Chuyển lỗi thì giữ nguyên thư mục cũ và
  báo bằng một câu.
- **Cài đặt › Tải xuống**: thêm hàng "Thư mục tải xuống" ở đầu trang, hiện
  đường dẫn hoặc "Chưa chọn"; chạm để chọn / đổi.
- **Chuỗi**: thêm vào cả `app_en.arb` và `app_vi.arb`.

## Kiểm thử

- Đơn vị: lưu/đọc `folder`; store mở đúng gốc; chuyển cây thư mục (cùng ổ,
  đích đã có file, lỗi giữa chừng giữ nguyên nguồn).
- Widget: bấm Tải xuống khi chưa chọn → mở hộp chọn; huỷ → không có bản ghi;
  chọn → có bản ghi. Trang cài đặt hiện đường dẫn.
- `flutter analyze` sạch, `flutter test` qua hết, `screens_test` không tràn.

## Để người làm tự quyết

Tên chuỗi l10n, hình thức hộp tiến trình, cách đọc dung lượng trống.

## Chưa kiểm được ở đây

Thẻ SD trên máy Android thật; thư mục đã chọn biến mất (rút USB/thẻ) — khi đó
danh sách trống và lượt tải báo lỗi bằng một câu, không tự quay về thư mục cũ.
