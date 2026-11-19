import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:reown_appkit/reown_appkit.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:sqflite/sqflite.dart' hide Transaction;
import 'package:path/path.dart' as p;
import 'package:open_filex/open_filex.dart';

// ============================================================
// REOWN DEEP LINK HANDLER (required for Android wallet callbacks)
// Uses the same channel names as MainActivity.kt.
// ============================================================
class DeepLinkHandler {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.walletconnect.flutterdapp/methods',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.walletconnect.flutterdapp/events',
  );

  // AppKit modal belum tentu selesai dibuat ketika Android mengirim
  // callback deep link. Simpan dulu link tersebut agar tidak hilang.
  static IReownAppKitModal? _appKitModal;
  static final List<String> _pendingLinks = <String>[];
  static bool _listening = false;

  static void initListener() {
    if (_listening) return;
    _listening = true;
    _eventChannel.receiveBroadcastStream().listen(
      _onLink,
      onError: (Object error) {
        debugPrint('[ReownDeepLink] stream error: $error');
      },
    );
  }

  static Future<void> init(IReownAppKitModal modal) async {
    _appKitModal = modal;

    // Proses callback yang datang sebelum AppKit selesai diinisialisasi.
    if (_pendingLinks.isNotEmpty) {
      final pending = List<String>.from(_pendingLinks);
      _pendingLinks.clear();

      for (final link in pending) {
        await _dispatchLink(modal, link);
      }
    }
  }

  static Future<void> checkInitialLink() async {
    try {
      await _methodChannel.invokeMethod<void>('initialLink');
    } catch (error) {
      debugPrint('[ReownDeepLink] initialLink error: $error');
    }
  }

  static Future<void> _onLink(dynamic link) async {
    if (link == null) return;

    final linkString = link.toString();
    final modal = _appKitModal;

    if (modal == null) {
      debugPrint(
        '[ReownDeepLink] AppKit belum siap; callback disimpan sementara.',
      );
      _pendingLinks.add(linkString);
      return;
    }

    await _dispatchLink(modal, linkString);
  }

  static Future<void> _dispatchLink(
    IReownAppKitModal modal,
    String link,
  ) async {
    try {
      debugPrint('[ReownDeepLink] received: $link');
      final handled = await modal.dispatchEnvelope(link);
      debugPrint('[ReownDeepLink] dispatchEnvelope handled=$handled');

      if (!handled) {
        debugPrint('[ReownDeepLink] callback tidak ditangani AppKit.');
      }
    } catch (error, stackTrace) {
      debugPrint('[ReownDeepLink] dispatch error: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }
}

// DATABASE LOKAL DAN LOGIN DUA ROLE
class LocalDatabase {
  LocalDatabase._();
  static final LocalDatabase instance = LocalDatabase._();
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, 'sertifikat_kelompok3.db'),
      version: 2,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE users ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT,'
          'username TEXT NOT NULL UNIQUE,'
          'nim TEXT, full_name TEXT NOT NULL,'
          'password_hash TEXT NOT NULL, password_salt TEXT NOT NULL,'
          'role TEXT NOT NULL, created_at TEXT NOT NULL)',
        );
        await _createCertificatesTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createCertificatesTable(db);
        }
      },
    );
    return _db!;
  }

  Future<void> _createCertificatesTable(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS certificates ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'nim TEXT NOT NULL,'
      'activity_name TEXT NOT NULL,'
      'issuer_name TEXT NOT NULL,'
      'certificate_hash TEXT NOT NULL,'
      'file_name TEXT NOT NULL,'
      'file_bytes BLOB NOT NULL,'
      'wallet_address TEXT NOT NULL,'
      'transaction_hash TEXT,'
      'created_at TEXT NOT NULL,'
      'is_verified INTEGER NOT NULL DEFAULT 0,'
      'status TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_certificates_nim ON certificates(nim)',
    );
  }

  Future<bool> studentExists(String nim) async {
    final rows = await (await database).query(
      'users',
      columns: ['id'],
      where: 'role = ? AND nim = ?',
      whereArgs: ['student', nim.trim()],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> saveCertificate({
    required String nim,
    required String activityName,
    required String issuerName,
    required String certificateHash,
    required String fileName,
    required Uint8List fileBytes,
    required String walletAddress,
    String? transactionHash,
    required bool isVerified,
    required String status,
  }) async {
    await (await database).insert('certificates', {
      'nim': nim.trim(),
      'activity_name': activityName,
      'issuer_name': issuerName,
      'certificate_hash': certificateHash,
      'file_name': fileName,
      'file_bytes': fileBytes,
      'wallet_address': walletAddress,
      'transaction_hash': transactionHash,
      'created_at': DateTime.now().toIso8601String(),
      'is_verified': isVerified ? 1 : 0,
      'status': status,
    });
  }

  Future<List<Map<String, Object?>>> certificatesForNim(String nim) async {
    return (await database).query(
      'certificates',
      where: 'nim = ?',
      whereArgs: [nim.trim()],
      orderBy: 'created_at DESC, id DESC',
    );
  }

  Future<void> deleteCertificate(int id) async {
    await (await database).delete(
      'certificates',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  String _salt() {
    final r = Random.secure();
    return List<int>.generate(
      16,
      (_) => r.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String _digest(String password, String salt) =>
      sha256.convert(utf8.encode('$salt:$password')).toString();

  Future<bool> hasAdmin() async {
    final rows = await (await database).query(
      'users',
      where: 'role = ?',
      whereArgs: ['admin'],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> createAdmin(String password) async {
    final salt = _salt();
    await (await database).insert('users', {
      'username': 'admin',
      'nim': null,
      'full_name': 'Administrator',
      'password_hash': _digest(password, salt),
      'password_salt': salt,
      'role': 'admin',
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<Map<String, Object?>?> login(String username, String password) async {
    final rows = await (await database).query(
      'users',
      where: 'username = ?',
      whereArgs: [username.trim()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    if (_digest(password, row['password_salt'] as String) !=
        row['password_hash']) {
      return null;
    }
    return row;
  }

  Future<void> addStudent(String nim, String name, String password) async {
    final salt = _salt();
    await (await database).insert('users', {
      'username': nim.trim(),
      'nim': nim.trim(),
      'full_name': name.trim(),
      'password_hash': _digest(password, salt),
      'password_salt': salt,
      'role': 'student',
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> students() async => (await database).query(
    'users',
    where: 'role = ?',
    whereArgs: ['student'],
    orderBy: 'full_name COLLATE NOCASE',
  );

  Future<void> deleteStudent(int id) async => (await database).delete(
    'users',
    where: 'id = ? AND role = ?',
    whereArgs: [id, 'student'],
  );
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool checking = true;
  bool adminExists = false;
  Map<String, Object?>? user;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final exists = await LocalDatabase.instance.hasAdmin();
      if (!mounted) return;
      setState(() {
        adminExists = exists;
        checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => checking = false);
      _message('Database lokal gagal dibuka: $e');
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    if (checking)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!adminExists)
      return SetupAdminPage(
        onCreated: () => setState(() => adminExists = true),
      );
    if (user == null)
      return LoginPage(onLogin: (u) => setState(() => user = u));
    if (user!['role'] == 'admin')
      return HomePage(onLogout: () => setState(() => user = null));
    return StudentDashboard(
      user: user!,
      onLogout: () => setState(() => user = null),
    );
  }
}

class SetupAdminPage extends StatefulWidget {
  final VoidCallback onCreated;
  const SetupAdminPage({super.key, required this.onCreated});
  @override
  State<SetupAdminPage> createState() => _SetupAdminPageState();
}

class _SetupAdminPageState extends State<SetupAdminPage> {
  final password = TextEditingController();
  final confirm = TextEditingController();
  bool saving = false;
  @override
  void dispose() {
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  void message(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> create() async {
    if (password.text.length < 8)
      return message('Password minimal 8 karakter.');
    if (password.text != confirm.text)
      return message('Konfirmasi password tidak sama.');
    setState(() => saving = true);
    try {
      await LocalDatabase.instance.createAdmin(password.text);
      widget.onCreated();
    } catch (e) {
      message('Gagal membuat admin: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.admin_panel_settings,
                    size: 58,
                    color: Color(0xFF3F51B5),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Pengaturan Admin Pertama',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    'Username admin sudah ditetapkan: admin. Buat password minimal 8 karakter.',
                  ),
                  const SizedBox(height: 20),
                  const TextField(
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: 'Username',
                      hintText: 'admin',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Buat password admin',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirm,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Ulangi password',
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: saving ? null : create,
                      child: Text(saving ? 'Menyimpan...' : 'Buat Akun Admin'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class LoginPage extends StatefulWidget {
  final ValueChanged<Map<String, Object?>> onLogin;
  const LoginPage({super.key, required this.onLogin});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final username = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> login() async {
    if (username.text.trim().isEmpty || password.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Isi username/NIM dan password.')),
      );
      return;
    }
    setState(() => busy = true);
    try {
      final result = await LocalDatabase.instance.login(
        username.text,
        password.text,
      );
      if (!mounted) return;
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Username/NIM atau password salah.')),
        );
      } else {
        widget.onLogin(result);
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Login gagal: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.verified_user,
                    size: 62,
                    color: Color(0xFF3F51B5),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Sertifikat Kelompok 3',
                    style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
                  ),
                  const Text('Login Admin dan Mahasiswa'),
                  const SizedBox(height: 24),
                  TextField(
                    controller: username,
                    decoration: const InputDecoration(
                      labelText: 'Username Admin / NIM Mahasiswa',
                      prefixIcon: Icon(Icons.person),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: password,
                    obscureText: true,
                    onSubmitted: (_) => login(),
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      prefixIcon: Icon(Icons.lock),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: busy ? null : login,
                      child: Text(busy ? 'Memeriksa...' : 'Masuk'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Admin menggunakan username admin. Mahasiswa menggunakan NIM.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class StudentManagementPage extends StatefulWidget {
  const StudentManagementPage({super.key});
  @override
  State<StudentManagementPage> createState() => _StudentManagementPageState();
}

class _StudentManagementPageState extends State<StudentManagementPage> {
  List<Map<String, Object?>> rows = [];
  bool loading = true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final data = await LocalDatabase.instance.students();
    if (mounted)
      setState(() {
        rows = data;
        loading = false;
      });
  }

  Future<void> addStudent() async {
    final name = TextEditingController();
    final nim = TextEditingController();
    final pass = TextEditingController();
    final key = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Daftarkan Mahasiswa'),
        content: Form(
          key: key,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Nama lengkap'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Nama wajib diisi' : null,
                ),
                TextFormField(
                  controller: nim,
                  decoration: const InputDecoration(labelText: 'NIM'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'NIM wajib diisi' : null,
                ),
                TextFormField(
                  controller: pass,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password awal (min. 8 karakter)',
                  ),
                  validator: (v) =>
                      v == null || v.length < 8 ? 'Minimal 8 karakter' : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              if (key.currentState!.validate()) Navigator.pop(ctx, true);
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await LocalDatabase.instance.addStudent(nim.text, name.text, pass.text);
        await load();
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Akun mahasiswa berhasil dibuat.')),
          );
      } on DatabaseException catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                e.isUniqueConstraintError()
                    ? 'NIM sudah terdaftar.'
                    : 'Gagal menyimpan: $e',
              ),
            ),
          );
      }
    }
    name.dispose();
    nim.dispose();
    pass.dispose();
  }

  Future<void> remove(Map<String, Object?> row) async {
    await LocalDatabase.instance.deleteStudent(row['id'] as int);
    await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Data Mahasiswa')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: addStudent,
      icon: const Icon(Icons.person_add),
      label: const Text('Tambah Mahasiswa'),
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : rows.isEmpty
        ? const Center(child: Text('Belum ada akun mahasiswa.'))
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, i) {
              final row = rows[i];
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.school)),
                title: Text(row['full_name'].toString()),
                subtitle: Text('NIM: ${row['nim']}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => remove(row),
                ),
              );
            },
          ),
  );
}

class StudentDashboard extends StatefulWidget {
  final Map<String, Object?> user;
  final VoidCallback onLogout;
  const StudentDashboard({
    super.key,
    required this.user,
    required this.onLogout,
  });

  @override
  State<StudentDashboard> createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<StudentDashboard> {
  bool loading = true;
  List<Map<String, Object?>> certificates = [];

  String get nim => (widget.user['nim'] ?? '').toString().trim();

  @override
  void initState() {
    super.initState();
    loadCertificates();
  }

  Future<void> loadCertificates() async {
    setState(() => loading = true);
    try {
      final rows = await LocalDatabase.instance.certificatesForNim(nim);
      if (!mounted) return;
      setState(() {
        certificates = rows;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Gagal mengambil sertifikat: $e')));
    }
  }

  Future<void> openCertificate(Map<String, Object?> row) async {
    try {
      final bytes = List<int>.from(row['file_bytes'] as List);
      final directory = Directory(
        p.join(await getDatabasesPath(), 'certificate_files'),
      );
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final id = row['id'];
      final originalName = (row['file_name'] ?? 'sertifikat.pdf').toString();
      final safeName = originalName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final fileExtension = p.extension(safeName).isEmpty
          ? '.pdf'
          : p.extension(safeName);
      final file = File(p.join(directory.path, 'sertifikat_$id$fileExtension'));
      await file.writeAsBytes(bytes, flush: true);
      final result = await OpenFilex.open(file.path);
      if (!mounted) return;
      if (result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Tidak dapat membuka file: ${result.message}'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Gagal membuka sertifikat: $e')));
    }
  }

  Future<void> verifySelectedFile(Map<String, Object?> row) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
        withData: true,
      );
      if (result == null || result.files.single.bytes == null) return;
      final bytes = result.files.single.bytes!;
      final uploadedHash = '0x${sha256.convert(bytes)}';
      final savedHash = row['certificate_hash'].toString().toLowerCase();
      final valid = uploadedHash.toLowerCase() == savedHash;
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: Icon(
            valid ? Icons.verified : Icons.gpp_bad,
            color: valid ? Colors.green : Colors.red,
            size: 48,
          ),
          title: Text(valid ? 'Sertifikat cocok' : 'Sertifikat tidak cocok'),
          content: Text(
            valid
                ? 'Hash file sama persis dengan hash sertifikat yang ditautkan oleh admin.'
                : 'Hash file berbeda. File ini bukan salinan yang sama dengan sertifikat yang disimpan admin.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Tutup'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Verifikasi file gagal: $e')));
    }
  }

  String _dateLabel(Object? value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return '-';
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Dashboard Mahasiswa'),
      actions: [
        IconButton(
          tooltip: 'Refresh sertifikat',
          onPressed: loading ? null : loadCertificates,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Logout',
          onPressed: widget.onLogout,
          icon: const Icon(Icons.logout),
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: loadCertificates,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.account_circle,
                    size: 48,
                    color: Color(0xFF3F51B5),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Selamat datang, ${widget.user['full_name']}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text('NIM: $nim'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Sertifikat Saya',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Text('${certificates.length}'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (loading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (certificates.isEmpty)
                    const Text(
                      'Belum ada sertifikat untuk NIM ini. Jika admin baru menerbitkan sertifikat, tekan tombol refresh atau pastikan admin mengisi NIM yang sama saat menerbitkan sertifikat.',
                    )
                  else
                    ...certificates.map((row) {
                      final verified = row['is_verified'] == 1;
                      final txHash = (row['transaction_hash'] ?? '').toString();
                      return Card(
                        margin: const EdgeInsets.only(top: 10),
                        color: Colors.grey.shade50,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                row['activity_name'].toString(),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text('Penerbit: ${row['issuer_name']}'),
                              Text('Tanggal: ${_dateLabel(row['created_at'])}'),
                              Text(
                                'Status: ${verified ? 'Hash sudah diverifikasi di blockchain' : row['status']}',
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Hash SHA-256:',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              SelectableText(
                                row['certificate_hash'].toString(),
                                style: const TextStyle(fontSize: 11),
                              ),
                              if (txHash.isNotEmpty) ...[
                                const SizedBox(height: 5),
                                SelectableText(
                                  'Tx: $txHash',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ],
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  FilledButton.icon(
                                    onPressed: () => openCertificate(row),
                                    icon: const Icon(Icons.picture_as_pdf),
                                    label: const Text('Buka PDF/File'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () => verifySelectedFile(row),
                                    icon: const Icon(Icons.verified_user),
                                    label: const Text('Verifikasi File'),
                                  ),
                                  if (txHash.isNotEmpty)
                                    TextButton.icon(
                                      onPressed: () => launchUrl(
                                        Uri.parse(
                                          'https://sepolia.etherscan.io/tx/$txHash',
                                        ),
                                        mode: LaunchMode.externalApplication,
                                      ),
                                      icon: const Icon(Icons.open_in_new),
                                      label: const Text('Etherscan'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Reown sample: start listening BEFORE runApp so cold-start links are not lost.
  DeepLinkHandler.initListener();
  runApp(const SertifikatApp());
}

// ============================================================
// APLIKASI
// ============================================================

class SertifikatApp extends StatelessWidget {
  const SertifikatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sertifikat Kegiatan Kelompok 3',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3F51B5)),
        scaffoldBackgroundColor: const Color(0xFFF8F7FC),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.grey.shade400),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF3F51B5), width: 2),
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

// ============================================================
// MODEL DATA
// ============================================================

class CertificateRecord {
  final String hash;
  final String activityName;
  final String issuerName;
  final String walletAddress;
  final int timestamp;
  final String transactionHash;

  CertificateRecord({
    required this.hash,
    required this.activityName,
    required this.issuerName,
    required this.walletAddress,
    required this.timestamp,
    required this.transactionHash,
  });
}

// ============================================================
// HOME PAGE
// ============================================================

class HomePage extends StatefulWidget {
  final VoidCallback onLogout;
  const HomePage({super.key, required this.onLogout});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // ==========================================================
  // KONFIGURASI REOWN
  // ==========================================================

  static const String reownProjectId = 'e418da1610c423e9cdf422d01697dccb';

  static const String contractAddress =
      '0xEF9187598b2D6165F07fBa345bfEa70dBdBBD4dc';

  static const String chainId = 'eip155:11155111';

  static const String rpcUrl = 'https://ethereum-sepolia-rpc.publicnode.com';

  static const String etherscanBase = 'https://sepolia.etherscan.io';

  // ==========================================================
  // REOWN
  // ==========================================================

  late ReownAppKitModal appKitModal;

  // true hanya setelah objek ReownAppKitModal berhasil dibuat.
  // Dipakai agar build() tidak membaca variabel late terlalu awal.
  bool modalCreated = false;
  bool initialized = false;
  bool loading = false;

  String status = 'Menyiapkan koneksi...';
  String? errorMessage;

  String? walletAddress;

  // ==========================================================
  // FORM
  // ==========================================================

  final TextEditingController activityController = TextEditingController();

  final TextEditingController issuerController = TextEditingController();
  final TextEditingController studentNimController = TextEditingController();

  Uint8List? selectedFileBytes;

  String? selectedFileName;
  String? selectedHash;

  // ==========================================================
  // DATA BLOCKCHAIN
  // ==========================================================

  List<CertificateRecord> certificates = [];

  String? lastTransactionHash;

  // ==========================================================
  // ABI
  // ==========================================================

  String? abiJson;

  DeployedContract? deployedContract;

  // ==========================================================
  // INIT
  // ==========================================================

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeApp();
    });
  }

  Future<void> _initializeApp() async {
    try {
      appKitModal = ReownAppKitModal(
        context: context,
        projectId: reownProjectId,

        metadata: const PairingMetadata(
          name: 'Sertifikat Kegiatan Kelompok 3',
          description: 'Aplikasi pencatatan dan verifikasi sertifikat berbasis blockchain',
          url: 'https://reown.com/',
          icons: ['https://reown.com/favicon.ico'],
          redirect: Redirect(
            native: 'sertifikatkelompok3://',
            universal: 'https://reown.com/sertifikatkelompok3',
          ),
        ),

        optionalNamespaces: {
          'eip155': RequiredNamespace(
            chains: ['eip155:11155111'],
            methods: [
              'eth_sendTransaction',
              'personal_sign',
              'eth_sign',
              'eth_signTransaction',
              'eth_signTypedData',
              'eth_signTypedData_v4',
              'wallet_switchEthereumChain',
              'wallet_addEthereumChain',
            ],
            events: ['accountsChanged', 'chainChanged'],
          ),
        },
      );

      // Objek modal sudah dibuat dan aman untuk diakses.
      modalCreated = true;

      // Listener koneksi
      appKitModal.onModalConnect.subscribe((event) {
        if (!mounted) return;

        _updateWalletInfo();

        setState(() {
          initialized = true;
          status = 'Wallet terhubung';
          errorMessage = null;
        });
      });

      // Listener disconnect
      appKitModal.onModalDisconnect.subscribe((event) {
        if (!mounted) return;

        setState(() {
          walletAddress = null;
          status = 'Wallet terputus';
        });
      });

      // Listener error
      appKitModal.onModalError.subscribe((event) {
        if (!mounted) return;

        setState(() {
          errorMessage = event.toString();
          status = 'Terjadi kesalahan koneksi';
        });
      });

      await appKitModal.init();

      // IMPORTANT: connect Android deep-link callbacks to this AppKit instance.
      await DeepLinkHandler.init(appKitModal);
      await DeepLinkHandler.checkInitialLink();

      await _loadAbi();

      if (!mounted) return;

      setState(() {
        initialized = true;

        if (appKitModal.isConnected) {
          status = 'Wallet terhubung';
        } else {
          status = 'Belum terhubung';
        }
      });

      if (appKitModal.isConnected) {
        _updateWalletInfo();
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        initialized = true;
        status = 'Gagal menyiapkan aplikasi';
        errorMessage = e.toString();
      });
    }
  }

  // ==========================================================
  // LOAD ABI
  // ==========================================================

  Future<void> _loadAbi() async {
    final jsonString = await rootBundle.loadString(
      'assets/CertificateRegistrySecure.json',
    );

    final decoded = jsonDecode(jsonString);

    dynamic abiData;

    if (decoded is Map<String, dynamic> && decoded.containsKey('abi')) {
      abiData = decoded['abi'];
    } else {
      abiData = decoded;
    }

    abiJson = jsonEncode(abiData);

    final abi = ContractAbi.fromJson(abiJson!, 'CertificateRegistrySecure');

    deployedContract = DeployedContract(
      abi,
      EthereumAddress.fromHex(contractAddress),
    );
  }

  // ==========================================================
  // WALLET ADDRESS
  // ==========================================================

  void _updateWalletInfo() {
    try {
      final session = appKitModal.session;

      if (session == null) {
        return;
      }

      final address = session.getAddress('eip155');

      if (address == null || address.isEmpty) {
        return;
      }

      if (!mounted) return;

      setState(() {
        walletAddress = address;
      });
    } catch (e) {
      debugPrint('Gagal mengambil address: $e');
    }
  }

  // ==========================================================
  // CONNECT WALLET
  // ==========================================================

  Future<void> connectWallet() async {
    try {
      if (!initialized) {
        _showMessage('Aplikasi masih menyiapkan Reown...');
        return;
      }

      setState(() {
        status = 'Membuka koneksi wallet...';
        errorMessage = null;
      });

      // PENTING:
      // Jangan gunakan launchConnectedWallet()
      //
      // openModalView() adalah alur untuk MEMULAI koneksi.
      await appKitModal.openModalView();

      await Future.delayed(const Duration(milliseconds: 500));

      _updateWalletInfo();

      if (!mounted) return;

      setState(() {
        if (appKitModal.isConnected) {
          status = 'Wallet terhubung';
        } else {
          status = 'Menunggu persetujuan MetaMask...';
        }
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        status = 'Koneksi gagal';
        errorMessage = e.toString();
      });

      _showMessage('Gagal membuka koneksi MetaMask:\n$e');
    }
  }

  // ==========================================================
  // DISCONNECT
  // ==========================================================

  Future<void> disconnectWallet() async {
    try {
      await appKitModal.disconnect();

      if (!mounted) return;

      setState(() {
        walletAddress = null;
        status = 'Belum terhubung';
        errorMessage = null;
      });
    } catch (e) {
      _showMessage('Gagal memutus wallet: $e');
    }
  }

  // ==========================================================
  // PILIH FILE
  // ==========================================================

  Future<void> pickCertificate() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
        withData: true,
      );

      if (result == null) {
        return;
      }

      final file = result.files.single;

      if (file.bytes == null) {
        _showMessage('File tidak dapat dibaca.');
        return;
      }

      final bytes = file.bytes!;

      final digest = sha256.convert(bytes);

      final hash = '0x${digest.toString()}';

      if (!mounted) return;

      setState(() {
        selectedFileBytes = bytes;
        selectedFileName = file.name;
        selectedHash = hash;
      });

      _showMessage('File berhasil dipilih dan hash SHA-256 berhasil dibuat.');
    } catch (e) {
      _showMessage('Gagal memilih file:\n$e');
    }
  }

  // ==========================================================
  // COPY HASH
  // ==========================================================

  Future<void> copyHash() async {
    if (selectedHash == null) return;

    await Clipboard.setData(ClipboardData(text: selectedHash!));

    _showMessage('Hash berhasil disalin.');
  }

  // ==========================================================
  // VALIDASI
  // ==========================================================

  bool _validateForm() {
    if (!modalCreated || !appKitModal.isConnected) {
      _showMessage('Hubungkan MetaMask terlebih dahulu.');
      return false;
    }

    if (walletAddress == null) {
      _updateWalletInfo();
    }

    if (walletAddress == null) {
      _showMessage('Alamat wallet belum ditemukan.');
      return false;
    }

    if (activityController.text.trim().isEmpty) {
      _showMessage('Nama kegiatan belum diisi.');
      return false;
    }

    if (issuerController.text.trim().isEmpty) {
      _showMessage('Nama penerbit belum diisi.');
      return false;
    }

    if (studentNimController.text.trim().isEmpty) {
      _showMessage('NIM mahasiswa penerima sertifikat belum diisi.');
      return false;
    }

    if (selectedFileBytes == null || selectedHash == null) {
      _showMessage('Pilih sertifikat terlebih dahulu.');
      return false;
    }

    if (deployedContract == null) {
      _showMessage('Smart contract belum siap.');
      return false;
    }

    return true;
  }

  // ==========================================================
  // SIMPAN SERTIFIKAT
  // ==========================================================

  Future<void> addCertificate() async {
    if (!_validateForm()) {
      return;
    }

    if (loading) {
      return;
    }

    final nim = studentNimController.text.trim();
    final studentFound = await LocalDatabase.instance.studentExists(nim);
    if (!studentFound) {
      _showMessage(
        'NIM $nim belum terdaftar. Buat akun mahasiswa terlebih dahulu di menu Data Mahasiswa.',
      );
      return;
    }

    setState(() {
      loading = true;
      status = 'Menyiapkan transaksi...';
      errorMessage = null;
      lastTransactionHash = null;
    });

    try {
      final session = appKitModal.session;

      if (session == null) {
        throw Exception('Session MetaMask tidak ditemukan.');
      }

      final topic = session.topic;

      if (topic == null || topic.isEmpty) {
        throw Exception('Topic WalletConnect tidak ditemukan.');
      }

      final address = session.getAddress('eip155');

      if (address == null || address.isEmpty) {
        throw Exception('Alamat wallet tidak ditemukan.');
      }

      walletAddress = address;

      final hashBytes = _hashToBytes(selectedHash!);

      final contract = deployedContract!;

      final function = contract.function('addCertificate');

      // ======================================================
      // TRANSAKSI
      //
      // TIDAK MEMAKAI GAS LIMIT RENDAH.
      //
      // MetaMask/Reown akan melakukan estimasi gas.
      // Menurunkan gas limit secara paksa justru bisa
      // menyebabkan transaksi gagal.
      // ======================================================

      final transaction = Transaction.callContract(
        contract: contract,
        function: function,
        parameters: [
          hashBytes,
          activityController.text.trim(),
          issuerController.text.trim(),
        ],
        from: EthereumAddress.fromHex(address),
      );

      setState(() {
        status = 'Meminta persetujuan transaksi...';
      });

      final result = await appKitModal.requestWriteContract(
        topic: topic,
        chainId: chainId,
        deployedContract: contract,
        functionName: 'addCertificate',
        transaction: transaction,
        parameters: [
          hashBytes,
          activityController.text.trim(),
          issuerController.text.trim(),
        ],
        method: 'eth_sendTransaction',
      );

      final txHash = _extractTransactionHash(result);

      if (txHash == null) {
        throw Exception(
          'MetaMask tidak mengembalikan transaction hash.\n'
          'Response: $result',
        );
      }

      if (!mounted) return;

      setState(() {
        lastTransactionHash = txHash;
        status = 'Transaksi berhasil dikirim';
      });

      // Simpan metadata dan byte file di SQLite agar akun mahasiswa
      // pada perangkat yang sama dapat melihat sertifikat berdasarkan NIM.
      try {
        await LocalDatabase.instance.saveCertificate(
          nim: nim,
          activityName: activityController.text.trim(),
          issuerName: issuerController.text.trim(),
          certificateHash: selectedHash!,
          fileName: selectedFileName ?? 'sertifikat',
          fileBytes: selectedFileBytes!,
          walletAddress: address,
          transactionHash: txHash,
          isVerified: false,
          status: 'Transaksi dikirim; menunggu konfirmasi blockchain',
        );
      } catch (dbError) {
        // Transaksi sudah memperoleh hash. Jangan melaporkan transaksi
        // blockchain sebagai gagal hanya karena SQLite gagal menyimpan.
        _showMessage(
          'Transaksi terkirim ($txHash), tetapi penyimpanan lokal gagal: $dbError',
        );
      }

      certificates.insert(
        0,
        CertificateRecord(
          hash: selectedHash!,
          activityName: activityController.text.trim(),
          issuerName: issuerController.text.trim(),
          walletAddress: address,
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          transactionHash: txHash,
        ),
      );

      _showTransactionDialog(txHash);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        status = 'Transaksi gagal';
        errorMessage = e.toString();
      });

      _showMessage(_friendlyTransactionError(e));
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  // ==========================================================
  // TAUTKAN SERTIFIKAT YANG SUDAH ADA DI BLOCKCHAIN KE NIM
  // Digunakan untuk PDF yang sudah pernah didaftarkan sebelum
  // fitur pengaitan NIM dan SQLite ditambahkan.
  // ==========================================================
  Future<void> linkExistingCertificateToStudent() async {
    if (loading) return;
    if (!modalCreated || !appKitModal.isConnected) {
      _showMessage('Hubungkan MetaMask terlebih dahulu.');
      return;
    }
    if (selectedFileBytes == null || selectedHash == null) {
      _showMessage('Pilih ulang file sertifikat yang sudah terdaftar.');
      return;
    }
    final nim = studentNimController.text.trim();
    if (nim.isEmpty) {
      _showMessage('Isi NIM mahasiswa penerima.');
      return;
    }
    if (!await LocalDatabase.instance.studentExists(nim)) {
      _showMessage('NIM $nim belum terdaftar di menu Data Mahasiswa.');
      return;
    }
    if (deployedContract == null) {
      _showMessage('Smart contract belum siap.');
      return;
    }

    setState(() {
      loading = true;
      status = 'Memeriksa hash pada blockchain...';
      errorMessage = null;
    });

    try {
      final session = appKitModal.session;
      final topic = session?.topic;
      if (topic == null || topic.isEmpty) {
        throw Exception('Sesi MetaMask tidak ditemukan.');
      }
      final address = session?.getAddress('eip155');
      if (address == null || address.isEmpty) {
        throw Exception('Alamat wallet tidak ditemukan.');
      }

      final result = await appKitModal.requestReadContract(
        topic: topic,
        chainId: chainId,
        deployedContract: deployedContract!,
        functionName: 'verifyCertificate',
        parameters: [_hashToBytes(selectedHash!)],
      );

      final exists = result.isNotEmpty && result[0] == true;
      if (!exists) {
        throw Exception('Hash file ini belum terdaftar pada smart contract.');
      }

      final onChainActivity = result.length > 1
          ? result[1].toString()
          : activityController.text.trim();
      final onChainIssuer = result.length > 2
          ? result[2].toString()
          : issuerController.text.trim();

      await LocalDatabase.instance.saveCertificate(
        nim: nim,
        activityName: onChainActivity.isNotEmpty
            ? onChainActivity
            : activityController.text.trim(),
        issuerName: onChainIssuer.isNotEmpty
            ? onChainIssuer
            : issuerController.text.trim(),
        certificateHash: selectedHash!,
        fileName: selectedFileName ?? 'sertifikat',
        fileBytes: selectedFileBytes!,
        walletAddress: address,
        transactionHash: null,
        isVerified: true,
        status: 'Hash terverifikasi pada blockchain',
      );

      if (!mounted) return;
      setState(() => status = 'Sertifikat berhasil ditautkan ke NIM $nim');
      _showMessage(
        'Sertifikat lama berhasil ditautkan ke akun mahasiswa NIM $nim.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        status = 'Gagal menautkan sertifikat';
        errorMessage = e.toString();
      });
      _showMessage('Gagal menautkan sertifikat: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // ==========================================================
  // EXTRACT TX HASH
  // ==========================================================

  String? _extractTransactionHash(dynamic result) {
    if (result == null) {
      return null;
    }

    if (result is String) {
      if (result.startsWith('0x') && result.length >= 10) {
        return result;
      }

      return null;
    }

    if (result is Map) {
      for (final key in ['transactionHash', 'txHash', 'hash', 'result']) {
        final value = result[key];

        if (value is String && value.startsWith('0x')) {
          return value;
        }
      }
    }

    return null;
  }

  // ==========================================================
  // HASH -> BYTES32
  // ==========================================================

  Uint8List _hashToBytes(String hash) {
    var clean = hash.trim();

    if (clean.startsWith('0x')) {
      clean = clean.substring(2);
    }

    if (clean.length != 64) {
      throw Exception('Hash SHA-256 harus 32 byte / 64 karakter hex.');
    }

    final bytes = <int>[];

    for (int i = 0; i < clean.length; i += 2) {
      bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }

    return Uint8List.fromList(bytes);
  }

  // ==========================================================
  // VERIFY CERTIFICATE
  // ==========================================================

  Future<void> verifyCertificate() async {
    if (selectedHash == null) {
      _showMessage('Pilih file sertifikat terlebih dahulu.');
      return;
    }

    if (!appKitModal.isConnected) {
      _showMessage('Hubungkan MetaMask terlebih dahulu.');
      return;
    }

    if (deployedContract == null) {
      _showMessage('Smart contract belum siap.');
      return;
    }

    try {
      setState(() {
        loading = true;
        status = 'Memverifikasi sertifikat...';
      });

      final session = appKitModal.session;

      final topic = session?.topic;

      final result = await appKitModal.requestReadContract(
        topic: topic,
        chainId: chainId,
        deployedContract: deployedContract!,
        functionName: 'verifyCertificate',
        parameters: [_hashToBytes(selectedHash!)],
      );

      bool exists = false;
      BigInt timestamp = BigInt.zero;

      if (result.isNotEmpty) {
        exists = result[0] == true;

        // verifyCertificate mengembalikan:
        // (exists, activityName, issuer, timestamp).
        if (result.length > 3) {
          final value = result[3];
          if (value is BigInt) {
            timestamp = value;
          } else if (value is int) {
            timestamp = BigInt.from(value);
          } else {
            timestamp = BigInt.tryParse(value.toString()) ?? BigInt.zero;
          }
        }
      }

      if (!mounted) return;

      setState(() {
        status = exists ? 'Sertifikat valid' : 'Sertifikat tidak ditemukan';
      });

      _showVerificationDialog(exists: exists, timestamp: timestamp);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        status = 'Verifikasi gagal';
        errorMessage = e.toString();
      });

      _showMessage('Verifikasi gagal:\n$e');
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  // ==========================================================
  // REFRESH DATA BLOCKCHAIN
  // ==========================================================

  Future<void> refreshBlockchain() async {
    if (loading) {
      return;
    }

    try {
      setState(() {
        loading = true;
        status = 'Mengambil data blockchain...';
      });

      final logs = await _getCertificateLogs();

      final List<CertificateRecord> newRecords = [];

      for (final log in logs) {
        final topics = (log['topics'] as List?) ?? [];
        if (topics.length < 2) continue;

        final indexedHash = topics[1].toString();
        final eventData = log['data']?.toString() ?? '0x';
        final activityName = _decodeEventString(eventData, 0);
        final issuerName = _decodeEventString(eventData, 1);

        final txHash = log['transactionHash']?.toString() ?? '';
        final tx = await _getTransactionByHash(txHash);
        final from = tx?['from']?.toString() ?? '';

        final blockNumber = log['blockNumber']?.toString() ?? '0x0';
        final block = await _rpc('eth_getBlockByNumber', [blockNumber, false]);
        final timestamp = block is Map
            ? _decodeUint256(block['timestamp']?.toString() ?? '0x0')
            : 0;

        newRecords.add(
          CertificateRecord(
            hash: indexedHash,
            activityName: activityName.isEmpty
                ? 'Sertifikat Blockchain'
                : activityName,
            issuerName: issuerName.isEmpty
                ? 'Tercatat di Blockchain'
                : issuerName,
            walletAddress: from,
            timestamp: timestamp,
            transactionHash: txHash,
          ),
        );
      }

      if (!mounted) return;

      setState(() {
        certificates = newRecords;
        status = 'Data blockchain diperbarui';
      });

      _showMessage('${newRecords.length} sertifikat ditemukan.');
    } catch (e) {
      if (!mounted) return;

      setState(() {
        status = 'Refresh gagal';
        errorMessage = e.toString();
      });

      _showMessage('Gagal mengambil data blockchain:\n$e');
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  // ==========================================================
  // GET EVENT LOG
  // ==========================================================

  Future<List<dynamic>> _getCertificateLogs() async {
    // Signature harus sama persis dengan event Solidity:
    // CertificateAdded(bytes32,string,string)
    final eventSignature = bytesToHex(
      keccak256(
        Uint8List.fromList(
          utf8.encode('CertificateAdded(bytes32,string,string)'),
        ),
      ),
    );

    // Kontrak baru dideploy pada block 12160450.
    // RPC Sepolia membatasi eth_getLogs maksimal 50.000 blok per request.
    const int deploymentBlock = 12160450;
    const int maxBlockSpan =
        49999; // selisih blok; aman untuk batas 50.000 blok

    final latestHex = await _rpc('eth_blockNumber', []);
    final latestBlock = _decodeUint256(latestHex.toString());

    if (latestBlock < deploymentBlock) return <dynamic>[];

    final allLogs = <dynamic>[];
    var fromBlock = deploymentBlock;

    while (fromBlock <= latestBlock) {
      final toBlock = (fromBlock + maxBlockSpan < latestBlock)
          ? fromBlock + maxBlockSpan
          : latestBlock;

      final result = await _rpc('eth_getLogs', [
        {
          'address': contractAddress,
          'fromBlock': '0x${fromBlock.toRadixString(16)}',
          'toBlock': '0x${toBlock.toRadixString(16)}',
          'topics': [
            eventSignature.startsWith('0x')
                ? eventSignature
                : '0x$eventSignature',
          ],
        },
      ]);

      if (result is List) {
        allLogs.addAll(result);
      }

      fromBlock = toBlock + 1;
    }

    return allLogs;
  }

  // Decode string pada data event Solidity (dua parameter non-indexed).
  String _decodeEventString(String data, int argumentIndex) {
    try {
      var clean = data.startsWith('0x') ? data.substring(2) : data;
      if (clean.isEmpty) return '';

      final offsetWordStart = argumentIndex * 64;
      final offsetWordEnd = offsetWordStart + 64;
      if (clean.length < offsetWordEnd) return '';

      final offsetBytes = int.parse(
        clean.substring(offsetWordStart, offsetWordEnd),
        radix: 16,
      );
      final lengthWordStart = offsetBytes * 2;
      final lengthWordEnd = lengthWordStart + 64;
      if (clean.length < lengthWordEnd) return '';

      final byteLength = int.parse(
        clean.substring(lengthWordStart, lengthWordEnd),
        radix: 16,
      );
      final valueStart = lengthWordEnd;
      final valueEnd = valueStart + byteLength * 2;
      if (byteLength < 0 || clean.length < valueEnd) return '';

      final bytes = <int>[];
      for (var i = valueStart; i < valueEnd; i += 2) {
        bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
      }
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  // ==========================================================
  // GET TRANSACTION
  // ==========================================================

  Future<Map<String, dynamic>?> _getTransactionByHash(String txHash) async {
    if (txHash.isEmpty) {
      return null;
    }

    final result = await _rpc('eth_getTransactionByHash', [txHash]);

    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }

    return null;
  }

  // ==========================================================
  // RPC
  // ==========================================================

  Future<dynamic> _rpc(String method, List<dynamic> params) async {
    final response = await http.post(
      Uri.parse(rpcUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'jsonrpc': '2.0',
        'id': DateTime.now().millisecondsSinceEpoch,
        'method': method,
        'params': params,
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('RPC HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);

    if (decoded['error'] != null) {
      throw Exception(decoded['error'].toString());
    }

    return decoded['result'];
  }

  // ==========================================================
  // DECODE UINT256
  // ==========================================================

  int _decodeUint256(String value) {
    var clean = value;

    if (clean.startsWith('0x')) {
      clean = clean.substring(2);
    }

    if (clean.isEmpty) {
      return 0;
    }

    final big = BigInt.tryParse(clean, radix: 16) ?? BigInt.zero;

    return big.toInt();
  }

  // ==========================================================
  // OPEN EXPLORER
  // ==========================================================

  Future<void> openTransaction(String txHash) async {
    final uri = Uri.parse('$etherscanBase/tx/$txHash');

    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      _showMessage('Tidak dapat membuka Etherscan:\n$e');
    }
  }

  // ==========================================================
  // TRANSACTION DIALOG
  // ==========================================================

  void _showTransactionDialog(String txHash) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 10),
              Expanded(child: Text('Transaksi Berhasil')),
            ],
          ),
          content: SelectableText('Transaction Hash:\n\n$txHash'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('Tutup'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                openTransaction(txHash);
              },
              child: const Text('Lihat Etherscan'),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // VERIFICATION DIALOG
  // ==========================================================

  void _showVerificationDialog({
    required bool exists,
    required BigInt timestamp,
  }) {
    final date = timestamp > BigInt.zero
        ? DateTime.fromMillisecondsSinceEpoch(timestamp.toInt() * 1000)
        : null;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                exists ? Icons.verified : Icons.cancel,
                color: exists ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  exists ? 'Sertifikat Valid' : 'Sertifikat Tidak Ditemukan',
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                exists
                    ? 'Hash sertifikat ditemukan di blockchain.'
                    : 'Hash sertifikat tidak ditemukan di blockchain.',
              ),
              if (date != null) ...[
                const SizedBox(height: 15),
                Text(
                  'Waktu pencatatan:\n'
                  '${_formatDate(date)}',
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('Tutup'),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // DETAIL SERTIFIKAT
  // ==========================================================

  void _showCertificateDetail(CertificateRecord record) {
    final date = DateTime.fromMillisecondsSinceEpoch(record.timestamp * 1000);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Detail Sertifikat',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),

                const SizedBox(height: 20),

                _detailRow('Nama kegiatan', record.activityName),

                _detailRow('Penerbit', record.issuerName),

                _detailRow('Hash', record.hash),

                _detailRow('Wallet', record.walletAddress),

                _detailRow('Waktu pencatatan', _formatDate(date)),

                _detailRow('Transaction Hash', record.transactionHash),

                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      openTransaction(record.transactionHash);
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Lihat Transaksi di Etherscan'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==========================================================
  // FORMAT DATE
  // ==========================================================

  String _formatDate(DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');

    return '${two(date.day)}/'
        '${two(date.month)}/'
        '${date.year} '
        '${two(date.hour)}:'
        '${two(date.minute)}:'
        '${two(date.second)}';
  }

  // ==========================================================
  // DETAIL ROW
  // ==========================================================

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          SelectableText(
            value.isEmpty ? '-' : value,
            style: const TextStyle(fontSize: 15),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // FRIENDLY TRANSACTION ERROR
  // ==========================================================

  String _friendlyTransactionError(dynamic error) {
    final text = error.toString();

    final lower = text.toLowerCase();

    if (lower.contains('user rejected') ||
        lower.contains('rejected') ||
        lower.contains('user denied')) {
      return 'Transaksi dibatalkan di MetaMask.';
    }

    if (lower.contains('insufficient funds')) {
      return 'Saldo Sepolia ETH tidak cukup untuk biaya gas.';
    }

    if (lower.contains('underpriced')) {
      return 'Gas price terlalu rendah. Biarkan MetaMask menentukan gas secara otomatis.';
    }

    if (lower.contains('gas')) {
      return 'Transaksi gagal pada gas. Jangan menurunkan gas limit secara paksa. Coba lagi dan biarkan MetaMask melakukan estimasi gas.';
    }

    return 'Transaksi gagal:\n$text';
  }

  // ==========================================================
  // SNACKBAR
  // ==========================================================

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
      );
  }

  // ==========================================================
  // CONNECT BUTTON
  // ==========================================================

  Widget _buildWalletSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Koneksi Wallet Admin',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 15),

            // =================================================
            // INI WIDGET RESMI REOWN
            // =================================================
            if (initialized)
              SizedBox(
                width: double.infinity,
                child: AppKitModalConnectButton(
                  appKit: appKitModal,
                  context: context,
                ),
              )
            else
              const Center(child: CircularProgressIndicator()),

            const SizedBox(height: 12),

            if (modalCreated && appKitModal.isConnected)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.check_circle, color: Colors.green),
                            SizedBox(width: 8),
                            Text(
                              'Wallet terhubung',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.green,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          walletAddress ?? 'Mengambil alamat...',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 10),

                  OutlinedButton.icon(
                    onPressed: disconnectWallet,
                    icon: const Icon(Icons.link_off),
                    label: const Text('Putuskan Wallet'),
                  ),
                ],
              )
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Tekan tombol Connect di atas. '
                  'Kemudian pilih MetaMask pada layar Reown '
                  'dan setujui koneksi di MetaMask.',
                ),
              ),

            const SizedBox(height: 12),

            Text(
              'Status: $status',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),

            if (errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                errorMessage!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // FORM SERTIFIKAT
  // ==========================================================

  Widget _buildCertificateForm() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Penerbitan Sertifikat Kegiatan',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 20),

            TextField(
              controller: activityController,
              decoration: const InputDecoration(
                labelText: 'Nama Kegiatan',
                prefixIcon: Icon(Icons.event),
              ),
            ),

            const SizedBox(height: 15),

            TextField(
              controller: issuerController,
              decoration: const InputDecoration(
                labelText: 'Nama Penerbit',
                prefixIcon: Icon(Icons.person),
              ),
            ),

            const SizedBox(height: 15),

            TextField(
              controller: studentNimController,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                labelText: 'NIM Mahasiswa Penerima',
                hintText: 'Masukkan NIM yang sudah didaftarkan admin',
                prefixIcon: Icon(Icons.school),
              ),
            ),

            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: loading ? null : pickCertificate,
                icon: const Icon(Icons.upload_file),
                label: const Text('Pilih Sertifikat PDF/JPG/PNG'),
              ),
            ),

            if (selectedFileName != null) ...[
              const SizedBox(height: 15),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'File:\n$selectedFileName',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],

            if (selectedHash != null) ...[
              const SizedBox(height: 15),

              const Text(
                'Hash SHA-256:',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),

              const SizedBox(height: 7),

              SelectableText(
                selectedHash!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),

              const SizedBox(height: 8),

              TextButton.icon(
                onPressed: copyHash,
                icon: const Icon(Icons.copy),
                label: const Text('Salin Hash'),
              ),
            ],

            const SizedBox(height: 15),

            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: loading ? null : addCertificate,
                icon: loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified),
                label: Text(loading ? 'Memproses...' : 'Daftarkan Sertifikat'),
              ),
            ),

            const SizedBox(height: 10),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: loading ? null : verifyCertificate,
                icon: const Icon(Icons.search),
                label: const Text('Verifikasi Sertifikat'),
              ),
            ),

            const SizedBox(height: 10),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: loading ? null : linkExistingCertificateToStudent,
                icon: const Icon(Icons.link),
                label: const Text('Tautkan Sertifikat Lama ke NIM'),
              ),
            ),

            const SizedBox(height: 10),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: loading ? null : refreshBlockchain,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh Data Blockchain'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // TRANSACTION TERAKHIR
  // ==========================================================

  Widget _buildLastTransaction() {
    if (lastTransactionHash == null) {
      return const SizedBox.shrink();
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Transaksi Terakhir',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 10),

            SelectableText(
              lastTransactionHash!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),

            const SizedBox(height: 10),

            FilledButton.icon(
              onPressed: () {
                openTransaction(lastTransactionHash!);
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('Lihat di Etherscan'),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // LIST SERTIFIKAT
  // ==========================================================

  Widget _buildCertificateList() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Daftar Sertifikat',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ),

                IconButton(
                  onPressed: refreshBlockchain,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),

            const SizedBox(height: 10),

            if (certificates.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    'Belum ada data sertifikat.\n'
                    'Tekan Refresh Data Blockchain.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: certificates.length,
                separatorBuilder: (_, __) => const Divider(),
                itemBuilder: (context, index) {
                  final item = certificates[index];

                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(child: Icon(Icons.verified)),
                    title: Text(
                      item.activityName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 5),
                        Text(
                          'Penerbit: '
                          '${item.issuerName}',
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Hash: '
                          '${_shortHash(item.hash)}',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        const SizedBox(height: 3),
                        const Text(
                          'Status: Terverifikasi',
                          style: TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      _showCertificateDetail(item);
                    },
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // SHORT HASH
  // ==========================================================

  String _shortHash(String hash) {
    if (hash.length <= 18) {
      return hash;
    }

    return '${hash.substring(0, 10)}...'
        '${hash.substring(hash.length - 8)}';
  }

  // ==========================================================
  // FOOTER
  // ==========================================================

  Widget _buildFooter() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 25),
      child: Column(
        children: [
          Divider(),
          SizedBox(height: 15),
          Text(
            'Kelompok 3 - Pemrograman Mobile 2',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text('Ethereum Sepolia Testnet'),
          SizedBox(height: 5),
          Text(
            'Certificate Registry Blockchain',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF3F51B5),
        foregroundColor: Colors.white,
        title: const Text('Admin Sertifikat Kelompok 3'),
        actions: [
          IconButton(
            tooltip: 'Kelola Mahasiswa',
            icon: const Icon(Icons.groups),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StudentManagementPage()),
            ),
          ),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: widget.onLogout,
          ),
        ],
      ),

      body: RefreshIndicator(
        onRefresh: refreshBlockchain,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildWalletSection(),

            const SizedBox(height: 16),

            _buildCertificateForm(),

            const SizedBox(height: 16),

            _buildLastTransaction(),

            const SizedBox(height: 16),

            _buildCertificateList(),

            _buildFooter(),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // DISPOSE
  // ==========================================================

  @override
  void dispose() {
    activityController.dispose();
    issuerController.dispose();
    studentNimController.dispose();

    if (modalCreated) {
      appKitModal.dispose();
    }

    super.dispose();
  }
}
