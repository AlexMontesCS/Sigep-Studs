import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

const String GOOGLE_SCRIPT_URL =
    'https://script.google.com/macros/s/AKfycbwC5D80-De9EoJXBDRkX3u25mYX9ptFWmWfM468JC71hrvUq0ojGOUzewRqKFrgyEr67g/exec';
Future<Map<String, dynamic>> postToAppsScript(
  Map<String, dynamic> payload,
) async {
  final response = await http.post(
    Uri.parse(GOOGLE_SCRIPT_URL),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(payload),
  );

  if (response.statusCode != 200) {
    throw Exception('Apps Script HTTP ${response.statusCode}');
  }

  final data = jsonDecode(response.body);
  if (data is! Map<String, dynamic>) {
    throw Exception('Invalid Apps Script response');
  }

  if (data['status'] != 'success') {
    throw Exception(data['message'] ?? 'Apps Script error');
  }

  return data;
}

Future<void> saveUserToSheets({
  required String email,
  required String firstName,
  required String lastName,
  required String phone,
}) async {
  await postToAppsScript({
    'action': 'save_user',
    'user_email': email,
    'first_name': firstName,
    'last_name': lastName,
    'phone': phone,
  });
}

Future<String?> uploadPhotoToDrive(XFile imageFile) async {
  try {
    final bytes = await imageFile.readAsBytes();
    final base64Image = base64Encode(bytes);

    final data = await postToAppsScript({
      'action': 'upload_photo',
      'image_base64': base64Image,
      'file_name': 'study_${DateTime.now().millisecondsSinceEpoch}.jpg',
    });

    return data['photo_url']?.toString();
  } catch (e) {
    debugPrint('Upload error: $e');
    return null;
  }
}

Future<Map<String, String>> fetchPartners(String email) async {
  final data = await postToAppsScript({
    'action': 'get_partners',
    'user_email': email,
  });

  return {
    'partner_1': data['partner_1']?.toString() ?? '',
    'partner_2': data['partner_2']?.toString() ?? '',
  };
}
void main() {
  runApp(const SigEpStudsApp());
}

/* ================= APP ROOT ================= */

class SigEpStudsApp extends StatelessWidget {
  const SigEpStudsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SigEp Studs',
      theme: ThemeData(primarySwatch: Colors.deepPurple),
      home: const EntryGate(),
    );
  }
}

/* ================= ENTRY GATE ================= */

class EntryGate extends StatefulWidget {
  const EntryGate({super.key});

  @override
  State<EntryGate> createState() => _EntryGateState();
}

class _EntryGateState extends State<EntryGate> {
  bool loading = true;
  bool loggedIn = false;

  @override
  void initState() {
    super.initState();
    checkLogin();
  }

  Future<void> checkLogin() async {
    final prefs = await SharedPreferences.getInstance();
    loggedIn = prefs.containsKey('user_email');
    setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return loggedIn ? const HomeScreen() : const LoginScreen();
  }
}

/* ================= LOGIN SCREEN ================= */

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final firstCtrl = TextEditingController();
  final lastCtrl = TextEditingController();
  final emailCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  bool isLoading = false;

  Future<void> saveUser() async {
    final first = firstCtrl.text.trim();
    final last = lastCtrl.text.trim();
    final email = emailCtrl.text.trim();
    final phone = phoneCtrl.text.trim();

    // Validate inputs
    if (first.isEmpty || last.isEmpty || email.isEmpty || phone.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields')),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      await saveUserToSheets(
        email: email,
        firstName: first,
        lastName: last,
        phone: phone,
      );

      // Fetch partners from Google Sheets
      final partners = await fetchPartners(email);

      final prefs = await SharedPreferences.getInstance();

      // Save user info locally
      await prefs.setString('first_name', first);
      await prefs.setString('last_name', last);
      await prefs.setString('user_email', email);
      await prefs.setString('email', email); // For backwards compatibility
      await prefs.setString('phone', phone);

      await prefs.setString('partner_1', partners['partner_1'] ?? '');
      await prefs.setString('partner_2', partners['partner_2'] ?? '');

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } catch (e) {
      setState(() => isLoading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
      debugPrint('Save user error: $e');
    }
  }

  @override
  void dispose() {
    firstCtrl.dispose();
    lastCtrl.dispose();
    emailCtrl.dispose();
    phoneCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: firstCtrl,
              decoration: const InputDecoration(labelText: 'First Name'),
            ),
            TextField(
              controller: lastCtrl,
              decoration: const InputDecoration(labelText: 'Last Name'),
            ),
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            TextField(
              controller: phoneCtrl,
              decoration: const InputDecoration(labelText: 'Phone Number'),
            ),
            const SizedBox(height: 24),
            isLoading
                ? const SizedBox(
                    height: 48,
                    child: Center(child: CircularProgressIndicator()),
                  )
                : ElevatedButton(
                    onPressed: saveUser,
                    child: const Text('Continue'),
                  ),
          ],
        ),
      ),
    );
  }
}

/* ================= HOME SCREEN ================= */

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            RichText(
              text: const TextSpan(children: [
                TextSpan(
                  text: 'Σ',
                  style: TextStyle(
                    fontSize: 96,
                    fontWeight: FontWeight.bold,
                    color: Colors.deepPurple,
                  ),
                ),
                TextSpan(
                  text: 'Φ',
                  style: TextStyle(
                    fontSize: 96,
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                ),
                TextSpan(
                  text: 'Ε',
                  style: TextStyle(
                    fontSize: 96,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFFD700),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            const Text(
              'Balanced men hold each other accountable',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const PreSessionScreen(),
                  ),
                );
              },
              child: const Text('Start Session'),
            ),
          ],
        ),
      ),
    );
  }
}

/* ================= CAMERA HELPER ================= */

Future<bool> requestCameraPermission(BuildContext context) async {
  final status = await Permission.camera.request();
  
  if (!status.isGranted) {
    if (context.mounted) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Camera Permission Required'),
          content: const Text(
            'Please enable camera access to take a study proof photo.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
    return false;
  }
  return true;
}

Future<File?> takePhotoWithDialog(BuildContext context) async {
  final picker = ImagePicker();

  final pickedFile = await picker.pickImage(
    source: ImageSource.camera,
    imageQuality: 85,
  );

  if (pickedFile == null) return null;

  return File(pickedFile.path);
}
/* ================= PRE-SESSION SCREEN ================= */

class PreSessionScreen extends StatefulWidget {
  const PreSessionScreen({super.key});

  @override
  State<PreSessionScreen> createState() => _PreSessionScreenState();
}

class _PreSessionScreenState extends State<PreSessionScreen> {
  int hours = 0;
  int minutes = 0;
  String? beforePhoto; // Google Drive URL
  bool uploadingBefore = false;

  bool get canStart =>
      beforePhoto != null && (hours > 0 || minutes > 0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Study Time')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                DropdownButton<int>(
                  value: hours,
                  items: List.generate(
                    7,
                    (i) => DropdownMenuItem(
                      value: i,
                      child: Text('$i h'),
                    ),
                  ),
                  onChanged: (v) => setState(() => hours = v!),
                ),
                const SizedBox(width: 24),
                DropdownButton<int>(
                  value: minutes,
                  items: List.generate(
                    60,
                    (i) => DropdownMenuItem(
                      value: i,
                      child: Text('$i m'),
                    ),
                  ),
                  onChanged: (v) => setState(() => minutes = v!),
                ),
              ],
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: uploadingBefore ? null : () async {
  if (!kIsWeb) {
    final hasPermission = await requestCameraPermission(context);
    if (!hasPermission) return;
  }

  final picker = ImagePicker();
  final pickedFile = await picker.pickImage(
    source: kIsWeb ? ImageSource.gallery : ImageSource.camera,
    preferredCameraDevice: CameraDevice.rear,
    imageQuality: 85,
  );

  if (pickedFile == null) return;

  setState(() => uploadingBefore = true);
  final uploadedUrl = await uploadPhotoToDrive(pickedFile);
  setState(() {
    uploadingBefore = false;
    if (uploadedUrl != null) beforePhoto = uploadedUrl;
  });
},
              child: uploadingBefore
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      beforePhoto == null
                          ? 'Take Before Photo'
                          : 'Before Photo Taken ✓',
                    ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: canStart
                  ? () {
                      final totalSeconds =
                          (hours * 3600) + (minutes * 60);
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ActiveSessionScreen(
                            totalSeconds: totalSeconds,
                            beforePhoto: beforePhoto!,
                          ),
                        ),
                      );
                    }
                  : null,
              child: const Text('Start Session'),
            ),
          ],
        ),
      ),
    );
  }
}

/* ================= ACTIVE SESSION SCREEN ================= */

class ActiveSessionScreen extends StatefulWidget {
  final int totalSeconds;
  final String beforePhoto;

  const ActiveSessionScreen({
    super.key,
    required this.totalSeconds,
    required this.beforePhoto,
  });

  @override
  State<ActiveSessionScreen> createState() => _ActiveSessionScreenState();
}

class _ActiveSessionScreenState extends State<ActiveSessionScreen>
    with WidgetsBindingObserver {
  late int remaining;
  Timer? timer;
  bool paused = false;
  bool burnout = false;
  String? afterPhoto;
  bool backgrounded = false;
  bool uploadingAfter = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    remaining = widget.totalSeconds;
    startTimer();
  }

  void startTimer() {
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!paused && remaining > 0) {
        setState(() => remaining--);
      }
      if (remaining == 0) {
        timer?.cancel();
        setState(() => burnout = true);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      backgrounded = true;
      paused = true;
    }
  }

  String format(int s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${sec.toString().padLeft(2, '0')}';
  }

  Future<void> submitSession() async {
    final elapsed = widget.totalSeconds - remaining;
    int minutesElapsed = elapsed ~/ 60;
    if (elapsed % 60 >= 35) minutesElapsed++;

    final prefs = await SharedPreferences.getInstance();
    final email =
        prefs.getString('user_email') ?? prefs.getString('email') ?? '';
    final partner1 = prefs.getString('partner_1') ?? '';
    final partner2 = prefs.getString('partner_2') ?? '';

    await postToAppsScript({
      'action': 'log_session',
      'user_email': email,
      'session_id': DateTime.now().millisecondsSinceEpoch.toString(),
      'partner_1': partner1,
      'partner_2': partner2,
      'total_minute': minutesElapsed,
      'before_photo_url': widget.beforePhoto,
      'after_photo_url': afterPhoto ?? '',
      'location': '',
      'device_backgrounded': backgrounded,
    });

    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Study Session')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              format(remaining),
              style: const TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: () => setState(() => paused = !paused),
                  child: Text(paused ? 'Resume' : 'Pause'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: () {
                    paused = true;
                    burnout = true;
                    setState(() {});
                  },
                  style:
                      ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text('Burnout'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: (burnout && !uploadingAfter)
    ? () async {
        if (!kIsWeb) {
          final hasPermission = await requestCameraPermission(context);
          if (!hasPermission) return;
        }

        final picker = ImagePicker();
        final pickedFile = await picker.pickImage(
          source: kIsWeb ? ImageSource.gallery : ImageSource.camera,
          preferredCameraDevice: CameraDevice.rear,
          imageQuality: 85,
        );

        if (pickedFile == null) return;

        setState(() => uploadingAfter = true);
        final uploadedUrl = await uploadPhotoToDrive(pickedFile);
        setState(() {
          uploadingAfter = false;
          if (uploadedUrl != null) afterPhoto = uploadedUrl;
        });
      }
    : null,
              child: uploadingAfter
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Take After Photo'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed:
                  (burnout && afterPhoto != null) ? submitSession : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
              ),
              child: const Text('Register Session'),
            ),
          ],
        ),
      ),
    );
  }
}
