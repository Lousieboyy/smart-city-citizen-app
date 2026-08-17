import 'locale_manager.dart';

/// Translate a UI string by its semantic key.
///
/// Falls back to the English value (or the key itself, if even that's
/// missing) so a missed translation degrades gracefully instead of
/// crashing or showing a blank string.
String tr(String key) {
  final entry = _strings[key];
  if (entry == null) return key;
  return entry[LocaleManager.localeNotifier.value] ?? entry['en'] ?? key;
}

/// Translate a report status for DISPLAY only — never changes the
/// canonical value used for API calls or filter matching (see
/// app_config.dart's ReportStatus constants).
String trStatus(String canonicalStatus) => tr('status_$canonicalStatus');

/// Translate a report category for DISPLAY only — never changes the
/// canonical value used for submission or filter matching.
String trCategory(String canonicalCategory) => tr('category_$canonicalCategory');

/// Translate a count-based template, e.g. trCount('upvotes_count', 3) -> "3 Upvotes".
String trCount(String key, int count) => tr(key).replaceAll('{n}', count.toString());

const Map<String, Map<String, String>> _strings = {
  // ── Common ──────────────────────────────────────────────────────────────
  'common_cancel':  {'en': 'Cancel',  'bm': 'Batal'},
  'common_save':    {'en': 'Save',    'bm': 'Simpan'},
  'common_retry':   {'en': 'Retry',   'bm': 'Cuba Lagi'},
  'common_close':   {'en': 'Close',   'bm': 'Tutup'},
  'common_loading': {'en': 'Loading...', 'bm': 'Memuatkan...'},
  'common_ok':      {'en': 'OK',      'bm': 'OK'},
  'common_error':   {'en': 'Error',   'bm': 'Ralat'},
  'common_unknown': {'en': 'Unknown', 'bm': 'Tidak Diketahui'},
  'common_unknown_error':  {'en': 'Unknown error',  'bm': 'Ralat tidak diketahui'},
  'common_sign_up':        {'en': 'Sign Up',        'bm': 'Daftar'},
  'common_create_account': {'en': 'Create Account', 'bm': 'Cipta Akaun'},

  // ── Shared field labels ─────────────────────────────────────────────────
  'field_username_label':         {'en': 'Username',         'bm': 'Nama Pengguna'},
  'field_password_label':         {'en': 'Password',         'bm': 'Kata Laluan'},
  'field_confirm_password_label': {'en': 'Confirm Password', 'bm': 'Sahkan Kata Laluan'},
  'field_full_name_label':        {'en': 'Full Name',        'bm': 'Nama Penuh'},
  'field_ic_number_label':        {'en': 'IC Number',        'bm': 'Nombor Kad Pengenalan'},
  'field_phone_number_label':     {'en': 'Phone Number',     'bm': 'Nombor Telefon'},

  // ── Login screen ────────────────────────────────────────────────────────
  'login_tagline':               {'en': 'Citizen reporting made simple', 'bm': 'Laporan warga dipermudahkan'},
  'login_username_hint':         {'en': 'Enter username',                'bm': 'Masukkan nama pengguna'},
  'login_username_error':        {'en': 'Please enter username',         'bm': 'Sila masukkan nama pengguna'},
  'login_password_hint':         {'en': 'Enter password',                'bm': 'Masukkan kata laluan'},
  'login_password_error':        {'en': 'Password must be at least 4 characters', 'bm': 'Kata laluan mesti sekurang-kurangnya 4 aksara'},
  'login_forgot_password':       {'en': 'Forgot password?',              'bm': 'Lupa kata laluan?'},
  'login_forgot_password_snack': {'en': "Password reset isn't available yet — contact your city admin.", 'bm': 'Set semula kata laluan belum tersedia — hubungi pentadbir bandar anda.'},
  'login_button_enter':          {'en': 'Enter the City',                'bm': 'Masuk ke Bandar'},
  'login_signup_prompt':         {'en': "Don't have an account?",        'bm': 'Belum ada akaun?'},
  'login_failed_prefix':         {'en': 'Login failed: ',                'bm': 'Log masuk gagal: '},
  'login_connection_error':      {'en': 'Cannot connect to server. Check network connection.', 'bm': 'Tidak dapat menyambung ke pelayan. Sila semak sambungan rangkaian.'},

  // ── Signup screen ───────────────────────────────────────────────────────
  'signup_success':                    {'en': 'Registration successful! Please login.', 'bm': 'Pendaftaran berjaya! Sila log masuk.'},
  'signup_failed_prefix':              {'en': 'Signup failed: ',                        'bm': 'Pendaftaran gagal: '},
  'signup_title':                      {'en': 'Create Account',                         'bm': 'Cipta Akaun'},
  'signup_tagline':                    {'en': "Join your city's reporting network",     'bm': 'Sertai rangkaian laporan bandar anda'},
  'signup_username_hint':              {'en': 'Choose a username',                      'bm': 'Pilih nama pengguna'},
  'signup_username_error':             {'en': 'Username must be at least 2 characters', 'bm': 'Nama pengguna mesti sekurang-kurangnya 2 aksara'},
  'signup_full_name_hint':             {'en': 'As per MyKad / IC',                      'bm': 'Seperti pada MyKad / IC'},
  'signup_full_name_error':            {'en': 'Full name is required',                  'bm': 'Nama penuh diperlukan'},
  'signup_ic_hint':                    {'en': 'e.g. 900101041234',                      'bm': 'cth. 900101041234'},
  'signup_ic_required_error':          {'en': 'IC number is required',                  'bm': 'Nombor kad pengenalan diperlukan'},
  'signup_ic_length_error':            {'en': 'Must be exactly 12 digits',              'bm': 'Mesti tepat 12 digit'},
  'signup_phone_hint':                 {'en': 'e.g. 0123456789',                        'bm': 'cth. 0123456789'},
  'signup_phone_error':                {'en': 'Phone number is required',               'bm': 'Nombor telefon diperlukan'},
  'signup_password_hint':              {'en': 'At least 6 characters',                  'bm': 'Sekurang-kurangnya 6 aksara'},
  'signup_password_error':             {'en': 'At least 6 characters required',         'bm': 'Sekurang-kurangnya 6 aksara diperlukan'},
  'signup_confirm_password_hint':      {'en': 'Re-enter password',                      'bm': 'Masukkan semula kata laluan'},
  'signup_confirm_password_error':     {'en': 'Passwords do not match',                 'bm': 'Kata laluan tidak sepadan'},

  // ── More common ─────────────────────────────────────────────────────────
  'common_file_report':       {'en': 'File a Report',      'bm': 'Buat Laporan'},
  'common_location_unknown':  {'en': 'Location unknown',   'bm': 'Lokasi tidak diketahui'},
  'common_match':             {'en': 'match',               'bm': 'padanan'},
  'common_confirmed_count':   {'en': '{n} confirmed',      'bm': '{n} disahkan'},
  'common_minutes_ago':       {'en': '{n}m ago',           'bm': '{n}m lalu'},
  'common_hours_ago':         {'en': '{n}h ago',           'bm': '{n}j lalu'},
  'common_days_ago':          {'en': '{n}d ago',           'bm': '{n}h lalu'},

  // ── Roles (display only) ────────────────────────────────────────────────
  'role_citizen':   {'en': 'Citizen',   'bm': 'Warga'},
  'role_worker':    {'en': 'Worker',    'bm': 'Pekerja'},
  'role_admin':     {'en': 'Admin',     'bm': 'Pentadbir'},
  'role_authority': {'en': 'Authority', 'bm': 'Pihak Berkuasa'},

  // ── Report priority (display only) ──────────────────────────────────────
  'priority_High':     {'en': 'High',     'bm': 'Tinggi'},
  'priority_Medium':   {'en': 'Medium',   'bm': 'Sederhana'},
  'priority_Resolved': {'en': 'Resolved', 'bm': 'Selesai'},

  // ── Home screen ─────────────────────────────────────────────────────────
  'home_loading_reports':          {'en': 'Loading reports...', 'bm': 'Memuatkan laporan...'},
  'home_error_title':              {'en': "Couldn't load reports", 'bm': 'Gagal memuatkan laporan'},
  'home_error_body':               {'en': 'Check your connection and try again.', 'bm': 'Semak sambungan anda dan cuba lagi.'},
  'home_worker_tasks_todo':        {'en': 'My Tasks To-Do',     'bm': 'Tugasan Saya'},
  'home_worker_no_tasks':          {'en': "No pending tasks assigned. You're all caught up!", 'bm': 'Tiada tugasan belum selesai. Semuanya sudah selesai!'},
  'home_worker_submitted':         {'en': 'Submitted (Awaiting Review)', 'bm': 'Dihantar (Menunggu Semakan)'},
  'home_worker_team_pool':         {'en': 'Team Pool',          'bm': 'Kumpulan Pasukan'},
  'home_worker_team_pool_hint':    {'en': 'Open jobs for your team. The first worker to accept gets the job.',
                                    'bm': 'Tugasan terbuka untuk pasukan anda. Pekerja pertama yang menerima akan mendapatnya.'},
  'home_recent_reports':           {'en': 'Recent Reports',     'bm': 'Laporan Terkini'},
  'home_no_reports_title':         {'en': 'No reports yet.',    'bm': 'Belum ada laporan.'},
  'home_no_reports_body':          {'en': 'File your first report to help improve your neighborhood.', 'bm': 'Buat laporan pertama anda untuk membantu menambah baik kawasan kejiranan anda.'},
  'home_notif_banner_title':       {'en': 'Report Status Updated', 'bm': 'Status Laporan Dikemaskini'},
  'home_greeting_worker':          {'en': 'Worker Portal',      'bm': 'Portal Pekerja'},
  'home_greeting_citizen':         {'en': 'Welcome back',       'bm': 'Selamat kembali'},
  'home_open_profile':             {'en': 'Open profile',       'bm': 'Buka profil'},
  'home_stat_assigned':            {'en': 'Assigned',           'bm': 'Ditugaskan'},
  'home_stat_pool':                {'en': 'Team Pool',          'bm': 'Kumpulan Pasukan'},
  'home_stat_mine':                {'en': 'Mine',               'bm': 'Milik Saya'},
  'home_stat_total':               {'en': 'Total',              'bm': 'Jumlah'},
  'home_stat_in_maint':            {'en': 'In Maint.',          'bm': 'Penyelenggaraan'},
  'home_report_issue_title':       {'en': 'Report a City Issue', 'bm': 'Laporkan Isu Bandar'},
  'home_report_issue_body':        {'en': 'Report local infrastructure defects with AI diagnostics.', 'bm': 'Laporkan kerosakan infrastruktur tempatan dengan diagnostik AI.'},
  'home_worker_workspace_title':   {'en': 'Worker Workspace',   'bm': 'Ruang Kerja Pekerja'},
  'home_worker_workspace_active':  {'en': 'You have {n} active task(s) assigned. Tap to view details.', 'bm': 'Anda mempunyai {n} tugasan aktif. Ketik untuk lihat butiran.'},
  'home_worker_workspace_empty':   {'en': 'No active tasks assigned. Pull to refresh the queue.', 'bm': 'Tiada tugasan aktif. Tarik untuk muat semula.'},
  'home_no_data':                  {'en': 'No data available.', 'bm': 'Tiada data tersedia.'},
  'home_issue_overview':           {'en': 'City Issue Overview', 'bm': 'Gambaran Isu Bandar'},

  'common_refresh': {'en': 'Refresh', 'bm': 'Muat Semula'},

  // ── History screen ──────────────────────────────────────────────────────
  'history_title':                  {'en': 'My Reports',            'bm': 'Laporan Saya'},
  'history_load_error_prefix':      {'en': 'Error loading reports: ', 'bm': 'Ralat memuatkan laporan: '},
  'history_empty':                  {'en': 'No reports found.',     'bm': 'Tiada laporan dijumpai.'},
  'history_unknown_issue':          {'en': 'Unknown Issue',         'bm': 'Isu Tidak Diketahui'},
  'history_no_description':         {'en': 'No description provided', 'bm': 'Tiada penerangan diberikan'},
  'history_ai_match_prefix':        {'en': 'AI Match: ',            'bm': 'Padanan AI: '},
  'history_department_prefix':      {'en': 'Department: ',          'bm': 'Jabatan: '},
  'history_assigned_worker_prefix': {'en': 'Assigned Worker: ',     'bm': 'Pekerja Ditugaskan: '},
  'history_dispatch_thread':        {'en': 'Dispatch Thread',       'bm': 'Rangkaian Mesej'},
  'history_completion_proof':       {'en': 'Worker Completion Proof', 'bm': 'Bukti Siap Kerja'},

  'common_none': {'en': 'None', 'bm': 'Tiada'},

  // ── Report submission screen ────────────────────────────────────────────
  'report_title':                    {'en': 'Report an Issue',   'bm': 'Laporkan Isu'},
  'report_step_evidence':            {'en': 'Evidence',          'bm': 'Bukti'},
  'report_step_category':            {'en': 'Category Selection', 'bm': 'Pemilihan Kategori'},
  'report_step_description':         {'en': 'Description',       'bm': 'Penerangan'},
  'report_step_location':            {'en': 'Location',          'bm': 'Lokasi'},
  'report_tap_to_add_photo':         {'en': 'Tap to add evidence photo', 'bm': 'Ketik untuk tambah foto bukti'},
  'report_supports_camera_gallery':  {'en': 'Supports camera & gallery', 'bm': 'Menyokong kamera & galeri'},
  'report_choose_gallery':           {'en': 'Choose from Gallery', 'bm': 'Pilih dari Galeri'},
  'report_take_photo':               {'en': 'Take a Photo',       'bm': 'Ambil Gambar'},
  'report_ai_scanning':              {'en': 'AI Scanning',        'bm': 'Imbasan AI'},
  'report_ai_scanning_body':         {'en': 'Analyzing image features & infrastructure hazards...', 'bm': 'Menganalisis ciri imej & bahaya infrastruktur...'},
  'report_ai_vision_scan':           {'en': 'AI Computer Vision Scan', 'bm': 'Imbasan Penglihatan Komputer AI'},
  'report_detected_issue':           {'en': 'Detected Issue:  ', 'bm': 'Isu Dikesan:  '},
  'report_auto_selected_category':   {'en': 'Auto-selected Category:  ', 'bm': 'Kategori Dipilih Automatik:  '},
  'report_manual_selection':         {'en': 'Manual Selection',  'bm': 'Pemilihan Manual'},
  'report_ai_preselected_note':      {'en': 'Categories pre-selected based on AI confidence.', 'bm': 'Kategori dipilih terlebih dahulu berdasarkan keyakinan AI.'},
  'report_ai_enhance':               {'en': 'AI Enhance',        'bm': 'Peningkatan AI'},
  'report_description_hint':         {'en': 'Describe the issue in detail (e.g. size, exact spot, hazard level)…', 'bm': 'Terangkan isu secara terperinci (cth. saiz, lokasi tepat, tahap bahaya)…'},
  'report_description_error':        {'en': 'Please add a brief description of the issue.', 'bm': 'Sila tambah penerangan ringkas mengenai isu ini.'},
  'report_submit_button':            {'en': 'Submit Report',     'bm': 'Hantar Laporan'},

  'report_fetching_location':            {'en': 'Fetching location…',       'bm': 'Mendapatkan lokasi…'},
  'report_location_permission_denied':   {'en': 'Location permission denied', 'bm': 'Kebenaran lokasi ditolak'},
  'report_location_unavailable':         {'en': 'Location unavailable',     'bm': 'Lokasi tidak tersedia'},
  'report_fetching_address':             {'en': 'Fetching address…',        'bm': 'Mendapatkan alamat…'},
  'report_address_unknown':              {'en': 'Unknown location',         'bm': 'Lokasi tidak diketahui'},
  'report_lat_label':                    {'en': 'Lat',                      'bm': 'Lat'},
  'report_lon_label':                    {'en': 'Lon',                      'bm': 'Long'},

  'report_session_expired':      {'en': 'Your session has expired. Please log out and log back in.', 'bm': 'Sesi anda telah tamat. Sila log keluar dan log masuk semula.'},
  'report_ai_scan_failed':       {'en': 'AI scan failed ({code}). You can still pick a category manually.', 'bm': 'Imbasan AI gagal ({code}). Anda masih boleh pilih kategori secara manual.'},
  'report_ai_unreachable':       {'en': 'Could not reach the AI service. You can still pick a category manually.', 'bm': 'Tidak dapat menghubungi perkhidmatan AI. Anda masih boleh pilih kategori secara manual.'},
  'report_error_no_image':       {'en': 'Please select an image first.', 'bm': 'Sila pilih imej terlebih dahulu.'},
  'report_error_analyzing':      {'en': 'Please wait for AI analysis to finish.', 'bm': 'Sila tunggu analisis AI selesai.'},
  'report_error_no_category':    {'en': 'Please select at least one category.', 'bm': 'Sila pilih sekurang-kurangnya satu kategori.'},
  'report_nearby_location':      {'en': 'Nearby location', 'bm': 'Lokasi berdekatan'},
  'report_submit_success':       {'en': 'Report submitted successfully!', 'bm': 'Laporan berjaya dihantar!'},
  'report_submit_failed':        {'en': 'Failed to submit report.', 'bm': 'Gagal menghantar laporan.'},
  'report_error_prefix':         {'en': 'Error: ', 'bm': 'Ralat: '},

  'report_enhance_needs_scan':    {'en': 'Please upload an image and run AI scan first.', 'bm': 'Sila muat naik imej dan jalankan imbasan AI dahulu.'},
  'report_enhance_pothole':       {'en': 'A pothole has been detected in the road. The asphalt has eroded, creating a deep depression that presents a hazard to passing traffic and local drivers.', 'bm': 'Lubang jalan telah dikesan. Turapan telah terhakis, mewujudkan lekukan dalam yang membahayakan trafik dan pemandu tempatan.'},
  'report_enhance_street_light':  {'en': 'A street light malfunction has been identified. The area is dark at night, causing safety concerns for pedestrians and reducing visibility for drivers.', 'bm': 'Kerosakan lampu jalan telah dikenal pasti. Kawasan ini gelap pada waktu malam, menyebabkan kebimbangan keselamatan bagi pejalan kaki dan mengurangkan penglihatan pemandu.'},
  'report_enhance_waste':         {'en': 'Illegal dumping/waste accumulation has been spotted. There is piled garbage that requires urgent removal to prevent sanitation issues and blockages.', 'bm': 'Pembuangan sampah haram/pengumpulan sisa telah dikesan. Terdapat sampah bertimbun yang memerlukan pembuangan segera untuk mengelakkan masalah sanitasi dan penyumbatan.'},
  'report_enhance_drainage':      {'en': 'A drainage block or overflow has been detected. Water is pooling, which could lead to flooding and local road hazards.', 'bm': 'Penyumbatan atau limpahan perparitan telah dikesan. Air bertakung, yang boleh menyebabkan banjir dan bahaya jalan tempatan.'},
  'report_enhance_construction':  {'en': 'Road construction or maintenance work is blocking traffic flow without proper warning signs or safety indicators.', 'bm': 'Kerja pembinaan atau penyelenggaraan jalan menghalang aliran trafik tanpa tanda amaran atau penunjuk keselamatan yang sepatutnya.'},
  'report_enhance_vegetation':    {'en': 'Overgrown vegetation or a fallen branch is obstructing the road/sidewalk path, making it difficult for vehicles and pedestrians to pass.', 'bm': 'Tumbuhan yang tumbuh liar atau dahan yang tumbang menghalang laluan jalan/kaki lima, menyukarkan kenderaan dan pejalan kaki untuk lalu.'},
  'report_enhance_generic':       {'en': 'An issue regarding {issue} has been detected at this location. Needs municipal attention for maintenance and restoration.', 'bm': 'Isu berkaitan {issue} telah dikesan di lokasi ini. Memerlukan perhatian pihak berkuasa tempatan untuk penyelenggaraan dan pemulihan.'},
  'report_enhance_success':       {'en': 'AI description generated!', 'bm': 'Penerangan AI dijana!'},

  'report_duplicate_title':                {'en': 'Similar Report Nearby', 'bm': 'Laporan Serupa Berdekatan'},
  'report_duplicate_body':                 {'en': "This looks like the same issue as a report already on file, just {distance}m away. Confirming it helps the city prioritize — filing a duplicate doesn't.", 'bm': 'Ini kelihatan seperti isu yang sama dengan laporan yang telah sedia ada, hanya {distance}m jauhnya. Mengesahkannya membantu bandar mengutamakan — membuat laporan pendua tidak membantu.'},
  'report_duplicate_existing_prefix':      {'en': 'Existing report: ', 'bm': 'Laporan sedia ada: '},
  'report_duplicate_distance':             {'en': '{distance} meters from your location', 'bm': '{distance} meter dari lokasi anda'},
  'report_duplicate_separately':           {'en': 'Report Separately', 'bm': 'Laporkan Berasingan'},
  'report_duplicate_confirmed':            {'en': 'Confirmed! Thanks for helping keep reports accurate.', 'bm': 'Disahkan! Terima kasih kerana membantu memastikan laporan tepat.'},
  'report_duplicate_confirm_failed':       {'en': 'Failed to confirm report.', 'bm': 'Gagal mengesahkan laporan.'},
  'report_duplicate_confirm_error_prefix': {'en': 'Error confirming report: ', 'bm': 'Ralat mengesahkan laporan: '},
  'report_duplicate_confirm_button':       {'en': 'Confirm This Issue (+1)', 'bm': 'Sahkan Isu Ini (+1)'},

  // ── Report detail screen ────────────────────────────────────────────────
  'detail_title':                {'en': 'Report Details', 'bm': 'Butiran Laporan'},
  'detail_uncategorized':        {'en': 'Uncategorized', 'bm': 'Tidak Berkategori'},
  'detail_reported_at_prefix':   {'en': 'Reported at: ', 'bm': 'Dilaporkan pada: '},
  'detail_location_details':     {'en': 'Location Details', 'bm': 'Butiran Lokasi'},
  'detail_workflow_timeline':    {'en': 'Workflow Timeline', 'bm': 'Garis Masa Aliran Kerja'},
  'detail_communication_thread': {'en': 'Communication Thread', 'bm': 'Rangkaian Komunikasi'},
  'detail_completion_proof':     {'en': 'Completion Proof', 'bm': 'Bukti Siap'},

  'detail_maintenance_started':      {'en': 'Maintenance started successfully!', 'bm': 'Penyelenggaraan berjaya dimulakan!'},
  'detail_update_failed':            {'en': 'Failed to update', 'bm': 'Gagal mengemaskini'},
  'detail_connection_failed':        {'en': 'Connection failed. Please check network.', 'bm': 'Sambungan gagal. Sila semak rangkaian.'},
  'detail_completion_proof_required':{'en': 'Please select or capture a completion proof photo.', 'bm': 'Sila pilih atau ambil foto bukti siap.'},
  'detail_completion_proof_submitted':{'en': 'Completion proof submitted successfully!', 'bm': 'Bukti siap berjaya dihantar!'},
  'detail_submit_proof_failed':      {'en': 'Failed to submit proof', 'bm': 'Gagal menghantar bukti'},

  'detail_upvote_recorded':          {'en': 'Upvote recorded! Thanks for supporting this report.', 'bm': 'Undian direkodkan! Terima kasih kerana menyokong laporan ini.'},
  'detail_upvote_failed':            {'en': 'Failed to upvote report.', 'bm': 'Gagal mengundi laporan.'},
  'detail_connection_error_prefix':  {'en': 'Connection error: ', 'bm': 'Ralat sambungan: '},
  'detail_upvotes_count':            {'en': '{n} Upvotes', 'bm': '{n} Undian'},
  'detail_upvote':                   {'en': 'Upvote', 'bm': 'Undi'},

  'detail_tap_to_view_photo':          {'en': 'Tap to View Photo', 'bm': 'Ketik untuk Lihat Foto'},
  'detail_ai_scanned':                 {'en': 'AI Scanned', 'bm': 'Diimbas AI'},
  'detail_no_media':                   {'en': 'No visual media attached', 'bm': 'Tiada media visual dilampirkan'},
  'detail_ai_assisted_diagnostics':    {'en': 'AI Assisted Diagnostics', 'bm': 'Diagnostik Bantuan AI'},
  'detail_match_suffix':               {'en': 'Match', 'bm': 'Padanan'},
  'detail_task_location':              {'en': 'Task Location', 'bm': 'Lokasi Tugasan'},
  'detail_directions':                 {'en': 'Directions', 'bm': 'Arah'},
  'detail_gps_label':                  {'en': 'GPS', 'bm': 'GPS'},
  'detail_no_description':             {'en': 'No description provided.', 'bm': 'Tiada penerangan diberikan.'},

  'detail_timeline_submitted':               {'en': 'Report Submitted', 'bm': 'Laporan Dihantar'},
  'detail_timeline_rejected':                {'en': 'Rejected by Admin', 'bm': 'Ditolak oleh Pentadbir'},
  'detail_timeline_approved':                {'en': 'Approved & Forwarded to Dept', 'bm': 'Diluluskan & Dihantar ke Jabatan'},
  'detail_timeline_awaiting_review':         {'en': 'Awaiting Admin Review', 'bm': 'Menunggu Semakan Pentadbir'},
  'detail_timeline_assigned_citizen':        {'en': 'Task Assigned to Worker', 'bm': 'Tugasan Diberikan kepada Pekerja'},
  'detail_timeline_assigned_worker_prefix':  {'en': 'Assigned to Worker: ', 'bm': 'Ditugaskan kepada Pekerja: '},
  'detail_timeline_awaiting_assignment':     {'en': 'Awaiting Worker Assignment', 'bm': 'Menunggu Penugasan Pekerja'},
  'detail_timeline_maintenance_completed':   {'en': 'Maintenance Completed', 'bm': 'Penyelenggaraan Selesai'},
  'detail_timeline_maintenance_in_progress': {'en': 'Maintenance In Progress', 'bm': 'Penyelenggaraan Sedang Berjalan'},
  'detail_timeline_awaiting_maintenance':    {'en': 'Awaiting Maintenance', 'bm': 'Menunggu Penyelenggaraan'},
  'detail_timeline_resolved':                {'en': 'Resolved & Verified', 'bm': 'Selesai & Disahkan'},
  'detail_timeline_awaiting_verification':   {'en': 'Awaiting Verification', 'bm': 'Menunggu Pengesahan'},
  'detail_active_stage':                     {'en': 'Active Stage', 'bm': 'Peringkat Aktif'},

  'detail_sender_system':      {'en': 'System',       'bm': 'Sistem'},
  'detail_sender_authority':   {'en': 'Authority Dept', 'bm': 'Jabatan Berkuasa'},
  'detail_sender_admin':       {'en': 'City Admin',    'bm': 'Pentadbir Bandar'},
  'detail_sender_system_log':  {'en': 'System Log',    'bm': 'Log Sistem'},

  'detail_view_full':                     {'en': 'View Full', 'bm': 'Lihat Penuh'},
  'detail_change':                        {'en': 'Change', 'bm': 'Tukar'},
  'detail_ai_verification_prediction':    {'en': 'AI Verification Prediction', 'bm': 'Ramalan Pengesahan AI'},
  'detail_worker_notes':                  {'en': 'Worker Notes:', 'bm': 'Nota Pekerja:'},
  'detail_no_completion_notes':           {'en': 'No completion notes provided.', 'bm': 'Tiada nota siap diberikan.'},
  'detail_submitted_prefix':              {'en': 'Submitted: ', 'bm': 'Dihantar: '},

  // ── Team pool: claim / release / transfer ───────────────────────────────
  'worker_accept_task':              {'en': 'Accept Task', 'bm': 'Terima Tugasan'},
  'worker_claiming':                 {'en': 'Accepting...', 'bm': 'Menerima...'},
  'worker_claim_success':            {'en': 'Task accepted. It is yours now.', 'bm': 'Tugasan diterima. Ia milik anda sekarang.'},
  'worker_claim_taken':              {'en': 'Another worker accepted this first.', 'bm': 'Pekerja lain telah menerimanya dahulu.'},
  'worker_claim_failed':             {'en': 'Could not accept this task.', 'bm': 'Tidak dapat menerima tugasan ini.'},
  'worker_pool_released':            {'en': 'Released back {n}x', 'bm': 'Dilepaskan semula {n}x'},
  'worker_pool_title':               {'en': 'Open job in your team pool', 'bm': 'Tugasan terbuka dalam kumpulan pasukan anda'},
  'worker_pool_body':                {'en': 'Nobody has taken this yet. Accept it to claim it.', 'bm': 'Belum ada sesiapa mengambilnya. Terima untuk menuntutnya.'},
  'worker_release_task':             {'en': 'Release to Pool', 'bm': 'Lepaskan ke Kumpulan'},
  'worker_release_title':            {'en': 'Release this task?', 'bm': 'Lepaskan tugasan ini?'},
  'worker_release_body':             {'en': 'It goes back to your team pool so another worker can take it.', 'bm': 'Ia akan kembali ke kumpulan pasukan anda supaya pekerja lain boleh mengambilnya.'},
  'worker_release_reason':           {'en': 'Reason (optional)', 'bm': 'Sebab (pilihan)'},
  'worker_release_success':          {'en': 'Task released back to the team pool.', 'bm': 'Tugasan dilepaskan semula ke kumpulan pasukan.'},
  'worker_release_failed':           {'en': 'Could not release this task.', 'bm': 'Tidak dapat melepaskan tugasan ini.'},
  'worker_transfer_task':            {'en': 'Request Another Team', 'bm': 'Minta Pasukan Lain'},
  'worker_transfer_title':           {'en': 'Request a team transfer', 'bm': 'Minta pemindahan pasukan'},
  'worker_transfer_body':            {'en': 'An authority will review this and may hand the job to another team.', 'bm': 'Pihak berkuasa akan menyemaknya dan mungkin menyerahkan tugasan kepada pasukan lain.'},
  'worker_transfer_success':         {'en': 'Request sent to the authority.', 'bm': 'Permintaan dihantar kepada pihak berkuasa.'},
  'worker_transfer_failed':          {'en': 'Could not send the request.', 'bm': 'Tidak dapat menghantar permintaan.'},
  'common_submit':                   {'en': 'Submit', 'bm': 'Hantar'},

  'detail_accept_start_maintenance': {'en': 'Accept & Start Maintenance', 'bm': 'Terima & Mula Penyelenggaraan'},
  'detail_accept_start_body':        {'en': 'Let the authority know that you have arrived and are starting work on this task.', 'bm': 'Maklumkan pihak berkuasa bahawa anda telah tiba dan memulakan kerja untuk tugasan ini.'},
  'detail_accept_start_button':      {'en': 'Accept & Start Work', 'bm': 'Terima & Mula Kerja'},
  'detail_submit_completion_proof':  {'en': 'Submit Completion Proof', 'bm': 'Hantar Bukti Siap'},
  'detail_tap_to_attach_photo':      {'en': 'Tap to attach completion photo', 'bm': 'Ketik untuk lampirkan foto siap'},
  'detail_photo_format_hint':        {'en': 'JPG or PNG format, up to 10MB', 'bm': 'Format JPG atau PNG, sehingga 10MB'},
  'detail_completion_notes':         {'en': 'Completion Notes', 'bm': 'Nota Siap'},
  'detail_completion_notes_hint':    {'en': 'Describe the maintenance work completed (e.g. patched potholes, replaced lightbulb)...', 'bm': 'Terangkan kerja penyelenggaraan yang selesai (cth. tampal lubang jalan, ganti mentol lampu)...'},
  'detail_completion_notes_error':   {'en': 'Please enter completion notes', 'bm': 'Sila masukkan nota siap'},
  'detail_mins_suffix':              {'en': 'mins', 'bm': 'minit'},

  // ── Map screen ───────────────────────────────────────────────────────────
  'map_proximity_alert':       {'en': 'Proximity Alert', 'bm': 'Amaran Kedekatan'},
  'map_proximity_alert_body':  {'en': "You are {distance}m away from an active '{issue}' issue.", 'bm': 'Anda berada {distance}m dari isu \'{issue}\' yang aktif.'},
  'map_nearby':                {'en': 'nearby', 'bm': 'berdekatan'},
  'map_issue_detected':        {'en': '{issue} Detected', 'bm': '{issue} Dikesan'},
  'map_view':                  {'en': 'View', 'bm': 'Lihat'},

  'map_step_submitted':   {'en': 'Submitted',   'bm': 'Dihantar'},
  'map_step_reviewed':    {'en': 'Reviewed',    'bm': 'Disemak'},
  'map_step_assigned':    {'en': 'Assigned',    'bm': 'Ditugaskan'},
  'map_step_maintenance': {'en': 'Maintenance', 'bm': 'Penyelenggaraan'},
  'map_step_resolved':    {'en': 'Resolved',    'bm': 'Selesai'},
  'map_report_progress':  {'en': 'Report Progress', 'bm': 'Kemajuan Laporan'},

  'map_before':               {'en': 'Before', 'bm': 'Sebelum'},
  'map_after':                {'en': 'After',  'bm': 'Selepas'},
  'map_ai_match_prefix':      {'en': 'AI MATCH: ', 'bm': 'PADANAN AI: '},
  'map_resolved_on_prefix':   {'en': 'Resolved on ', 'bm': 'Diselesaikan pada '},
  'map_view_full_details':    {'en': 'View Full Details', 'bm': 'Lihat Butiran Penuh'},
  'map_priority_suffix':      {'en': 'Priority', 'bm': 'Keutamaan'},

  'map_location_error_prefix': {'en': 'Could not get location:', 'bm': 'Tidak dapat mendapatkan lokasi:'},
  'map_getting_location':      {'en': 'Getting your location…', 'bm': 'Mendapatkan lokasi anda…'},
  'map_monitor_title':         {'en': 'Smart City Map Monitor', 'bm': 'Pemantau Peta Bandar Pintar'},

  'map_filters':              {'en': 'Filters', 'bm': 'Penapis'},
  'map_filters_title':        {'en': 'Map Filters', 'bm': 'Penapis Peta'},
  'map_category_label':       {'en': 'Category', 'bm': 'Kategori'},
  'map_report_status_label':  {'en': 'Report Status', 'bm': 'Status Laporan'},
  'map_style_label':          {'en': 'Map Style', 'bm': 'Gaya Peta'},
  'mapstyle_Muted Light':     {'en': 'Muted Light', 'bm': 'Cerah Lembut'},
  'mapstyle_Dark Mode':       {'en': 'Dark Mode',   'bm': 'Mod Gelap'},
  'mapstyle_Standard':        {'en': 'Standard',    'bm': 'Standard'},
  'map_visual_options':       {'en': 'Visual Options', 'bm': 'Pilihan Visual'},
  'map_show_heatmap':          {'en': 'Show Heatmap', 'bm': 'Tunjuk Peta Haba'},
  'map_show_heatmap_subtitle': {'en': 'Highlight issue density hotspots', 'bm': 'Serlahkan kawasan tumpuan isu'},
  'map_resolved_only':          {'en': 'Resolved Only', 'bm': 'Hanya Selesai'},
  'map_resolved_only_subtitle': {'en': 'Show only completed maintenance tasks', 'bm': 'Tunjuk hanya tugasan penyelenggaraan selesai'},
  'map_reset': {'en': 'Reset', 'bm': 'Set Semula'},
  'map_apply': {'en': 'Apply', 'bm': 'Guna'},

  'map_legend_title':             {'en': 'Map Legend', 'bm': 'Legenda Peta'},
  'map_issues_shown':             {'en': '{n} issue(s) shown', 'bm': '{n} isu dipaparkan'},
  'map_citizen_report_marker':    {'en': 'Citizen Report Marker', 'bm': 'Penanda Laporan Warga'},
  'map_legend_pending_alert':     {'en': 'Pending Alert', 'bm': 'Amaran Menunggu'},
  'map_legend_in_progress':       {'en': 'In Progress', 'bm': 'Dalam Proses'},
  'map_category_colors':          {'en': 'Category Colors', 'bm': 'Warna Kategori'},
  'map_legend_road_damage':       {'en': 'Road/Damage', 'bm': 'Jalan/Kerosakan'},
  'map_legend_lighting':          {'en': 'Lighting', 'bm': 'Lampu'},
  'map_legend_waste':             {'en': 'Waste', 'bm': 'Sisa'},
  'map_legend_noise':             {'en': 'Noise', 'bm': 'Bunyi Bising'},
  'map_show_legend':              {'en': 'Show Legend', 'bm': 'Tunjuk Legenda'},

  // ── Common (more) ───────────────────────────────────────────────────────
  'common_save_changes':  {'en': 'Save Changes', 'bm': 'Simpan Perubahan'},
  'common_not_available': {'en': 'N/A', 'bm': 'T/B'},

  // ── Profile screen ──────────────────────────────────────────────────────
  'profile_signout_title':       {'en': 'Sign Out?', 'bm': 'Log Keluar?'},
  'profile_signout_body':        {'en': 'You will be returned to the login screen.', 'bm': 'Anda akan dikembalikan ke skrin log masuk.'},
  'profile_signout_confirm':     {'en': 'Yes, Sign Out', 'bm': 'Ya, Log Keluar'},
  'profile_photo_updated':       {'en': 'Custom profile photo updated!', 'bm': 'Foto profil tersuai dikemaskini!'},
  'profile_upload_own_photo':    {'en': 'Upload My Own Photo', 'bm': 'Muat Naik Foto Sendiri'},
  'profile_choose_preset_avatar':{'en': 'Choose Preset Avatar', 'bm': 'Pilih Avatar Pratetap'},
  'profile_remove_custom_photo': {'en': 'Remove Custom Photo', 'bm': 'Buang Foto Tersuai'},
  'profile_avatar_updated':      {'en': 'Avatar updated successfully!', 'bm': 'Avatar berjaya dikemaskini!'},
  'profile_edit_details_title':  {'en': 'Edit Profile Details', 'bm': 'Edit Butiran Profil'},
  'profile_edit_profile':        {'en': 'Edit Profile', 'bm': 'Edit Profil'},
  'profile_active_tasks':        {'en': 'Active Tasks', 'bm': 'Tugasan Aktif'},
  'profile_total_reports':       {'en': 'Total Reports', 'bm': 'Jumlah Laporan'},
  'profile_completed':           {'en': 'Completed', 'bm': 'Selesai'},
  'profile_information_section': {'en': 'Profile Information', 'bm': 'Maklumat Profil'},
  'profile_preferences_section': {'en': 'Preferences', 'bm': 'Keutamaan'},
  'profile_update_saved':        {'en': 'Profile updated',
                                  'bm': 'Profil dikemas kini'},
  'profile_update_failed':       {'en': 'Could not update profile',
                                  'bm': 'Gagal mengemas kini profil'},
  'profile_update_offline':      {'en': 'No connection — profile not saved',
                                  'bm': 'Tiada sambungan — profil tidak disimpan'},
  'profile_username_taken':      {'en': 'That username is already taken',
                                  'bm': 'Nama pengguna itu telah digunakan'},
  'profile_language':            {'en': 'Language', 'bm': 'Bahasa'},
  'profile_language_bm':         {'en': 'Bahasa Malaysia', 'bm': 'Bahasa Malaysia'},
  'profile_language_en':         {'en': 'English', 'bm': 'English'},
  // Short forms for the compact EN/BM switch in the home header. Not translated
  // per locale on purpose: a language switch has to be readable in the language
  // you are trying to get to, not the one you are currently in.
  'lang_short_en':               {'en': 'EN', 'bm': 'EN'},
  'lang_short_bm':               {'en': 'BM', 'bm': 'BM'},
  'profile_notifications':       {'en': 'Notifications', 'bm': 'Pemberitahuan'},
  'profile_about_section':       {'en': 'About', 'bm': 'Tentang'},
  'profile_privacy_policy':      {'en': 'Privacy Policy', 'bm': 'Dasar Privasi'},
  'profile_privacy_policy_body': {'en': 'Privacy Policy details will be updated shortly.', 'bm': 'Butiran Dasar Privasi akan dikemaskini tidak lama lagi.'},
  'profile_about_app':           {'en': 'About App', 'bm': 'Tentang Aplikasi'},
  'profile_log_out':             {'en': 'Log Out', 'bm': 'Log Keluar'},

  // ── Bottom nav ──────────────────────────────────────────────────────────
  'nav_home':    {'en': 'Home',    'bm': 'Utama'},
  'nav_map':     {'en': 'Map',     'bm': 'Peta'},
  'nav_history': {'en': 'History', 'bm': 'Sejarah'},
  'nav_profile': {'en': 'Profile', 'bm': 'Profil'},

  // ── Report status (canonical → display) ────────────────────────────────
  'status_Pending':       {'en': 'Pending',        'bm': 'Menunggu'},
  'status_In Review':     {'en': 'In Review',      'bm': 'Dalam Semakan'},
  'status_In Process':    {'en': 'In Process',     'bm': 'Dalam Proses'},
  'status_In Maintenance':{'en': 'In Maintenance', 'bm': 'Dalam Penyelenggaraan'},
  'status_Resolved':      {'en': 'Resolved',       'bm': 'Selesai'},
  'status_Rejected':      {'en': 'Rejected',       'bm': 'Ditolak'},

  // ── Report categories (canonical → display) ────────────────────────────
  'category_All':              {'en': 'All',              'bm': 'Semua'},
  'category_Road':             {'en': 'Road',             'bm': 'Jalan'},
  'category_Road Damage':      {'en': 'Road Damage',      'bm': 'Kerosakan Jalan'},
  'category_Lighting':         {'en': 'Lighting',         'bm': 'Lampu'},
  'category_Street Lighting':  {'en': 'Street Lighting',  'bm': 'Lampu Jalan'},
  'category_Waste':            {'en': 'Waste',            'bm': 'Sisa'},
  'category_Waste Management': {'en': 'Waste Management', 'bm': 'Pengurusan Sisa'},
  'category_Drainage':         {'en': 'Drainage',         'bm': 'Perparitan'},
  'category_Normal':           {'en': 'Normal',           'bm': 'Normal'},
  'category_Other':            {'en': 'Other',            'bm': 'Lain-lain'},
};
