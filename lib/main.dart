import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'camera_web.dart' if (dart.library.io) 'camera_stub.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

const String GOOGLE_SCRIPT_URL =
    'https://script.google.com/macros/s/AKfycbzviuT2H4YDhKKImq2PrtIWSMFHJXyMVab3fxwsKQ5BTUWbOkRlf16JMyCCow2fooG6/exec';

/// Posts to Apps Script. Uses GET with query params to avoid
/// redirect issues on iOS (Apps Script 302 converts POST→GET).
Future<Map<String, dynamic>> postToAppsScript(
  Map<String, dynamic> payload,
) async {
  // Encode the payload as a query parameter to use GET instead of POST.
  // This avoids the 302 redirect issue where POST gets converted to GET
  // and the body is lost.
  final uri = Uri.parse(GOOGLE_SCRIPT_URL).replace(
    queryParameters: {'payload': jsonEncode(payload)},
  );

  final response = await http.get(uri);

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
  String partner1 = '',
  String partner2 = '',
}) async {
  await postToAppsScript({
    'action': 'save_user',
    'user_email': email,
    'first_name': firstName,
    'last_name': lastName,
    'phone': phone,
    'partner_1': partner1,
    'partner_2': partner2,
  });
}

Future<String?> uploadPhotoToDrive(XFile imageFile) async {
  try {
    final bytes = await imageFile.readAsBytes();
    final base64Image = base64Encode(bytes);

    // Photo uploads are too large for GET query params, use POST directly.
    // doPost in Apps Script still handles this action.
    final client = http.Client();
    try {
      final request = http.Request('POST', Uri.parse(GOOGLE_SCRIPT_URL));
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode({
        'action': 'upload_photo',
        'image_base64': base64Image,
        'file_name': 'study_${DateTime.now().millisecondsSinceEpoch}.jpg',
      });
      request.followRedirects = false;

      final streamed = await client.send(request);
      http.Response response;

      if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
        final location = streamed.headers['location'];
        if (location == null) throw Exception('Missing redirect location');
        response = await client.get(Uri.parse(location));
      } else {
        response = await http.Response.fromStream(streamed);
      }

      if (response.statusCode != 200) {
        throw Exception('Upload HTTP ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic> || data['status'] != 'success') {
        throw Exception(data['message'] ?? 'Upload failed');
      }

      return data['photo_url']?.toString();
    } finally {
      client.close();
    }
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

Future<Map<String, dynamic>> fetchUser(String email) async {
  return await postToAppsScript({
    'action': 'get_user',
    'user_email': email,
  });
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
  final emailCtrl = TextEditingController();
  final firstNameCtrl = TextEditingController();
  final lastNameCtrl = TextEditingController();
  final partnerCtrl = TextEditingController();
  bool isLoading = false;
  bool isNewUser = false;

  Future<void> login() async {
    final email = emailCtrl.text.trim().toLowerCase();

    if (email.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your email')),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      final userData = await fetchUser(email);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_email', email);
      await prefs.setString('first_name', userData['first_name']?.toString() ?? '');
      await prefs.setString('last_name', userData['last_name']?.toString() ?? '');
      await prefs.setString('partner_1', userData['partner_1']?.toString() ?? '');
      await prefs.setString('partner_2', userData['partner_2']?.toString() ?? '');

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } catch (e) {
      setState(() => isLoading = false);
      // If user not found, show registration fields
      if (e.toString().contains('User not found')) {
        setState(() => isNewUser = true);
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
      debugPrint('Login error: $e');
    }
  }

  Future<void> register() async {
    final email = emailCtrl.text.trim().toLowerCase();
    final first = firstNameCtrl.text.trim();
    final last = lastNameCtrl.text.trim();
    final partner = partnerCtrl.text.trim();

    if (first.isEmpty || last.isEmpty || partner.isEmpty) {
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
        phone: 'N/A',
        partner1: partner,
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_email', email);
      await prefs.setString('first_name', first);
      await prefs.setString('last_name', last);
      await prefs.setString('partner_1', partner);
      await prefs.setString('partner_2', '');

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
      debugPrint('Register error: $e');
    }
  }

  @override
  void dispose() {
    emailCtrl.dispose();
    firstNameCtrl.dispose();
    lastNameCtrl.dispose();
    partnerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(isNewUser ? 'Create Account' : 'Welcome')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(labelText: 'Email'),
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              enabled: !isNewUser,
            ),
            if (isNewUser) ...[
              const SizedBox(height: 16),
              TextField(
                controller: firstNameCtrl,
                decoration: const InputDecoration(labelText: 'First Name'),
              ),
              TextField(
                controller: lastNameCtrl,
                decoration: const InputDecoration(labelText: 'Last Name'),
              ),
              TextField(
                controller: partnerCtrl,
                decoration: const InputDecoration(labelText: "Partner's Name"),
              ),
            ],
            const SizedBox(height: 24),
            isLoading
                ? const SizedBox(
                    height: 48,
                    child: Center(child: CircularProgressIndicator()),
                  )
                : ElevatedButton(
                    onPressed: isNewUser ? register : login,
                    child: Text(isNewUser ? 'Sign Up' : 'Continue'),
                  ),
          ],
        ),
      ),
    );
  }
}

/* ================= HOME SCREEN ================= */

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String firstName = '';
  String partner = '';

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
  }

  Future<void> _loadUserInfo() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      firstName = prefs.getString('first_name') ?? '';
      partner = prefs.getString('partner_1') ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
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
            Text(
              'Welcome $firstName',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            if (partner.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Your partner is $partner',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ],
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
  String? beforePhoto;
  bool uploadingBefore = false;
  bool pomodoroMode = false;
  int pomodoroRounds = 4;
  int pomodoroWorkMin = 25;
  int pomodoroBreakMin = 5;

  @override
  void initState() {
    super.initState();
    _loadPomodoroSettings();
  }

  Future<void> _loadPomodoroSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      pomodoroWorkMin = prefs.getInt('pomo_work_min') ?? 25;
      pomodoroBreakMin = prefs.getInt('pomo_break_min') ?? 5;
    });
  }

  bool get canStart =>
      beforePhoto != null && (pomodoroMode || hours > 0 || minutes > 0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Study Time')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('Custom'),
                  icon: Icon(Icons.timer),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Pomodoro'),
                  icon: Icon(Icons.av_timer),
                ),
              ],
              selected: {pomodoroMode},
              onSelectionChanged: (s) => setState(() => pomodoroMode = s.first),
            ),
            const SizedBox(height: 24),
            if (!pomodoroMode) ...[  
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  DropdownButton<int>(
                    value: hours,
                    items: List.generate(
                      7,
                      (i) => DropdownMenuItem(value: i, child: Text('$i h')),
                    ),
                    onChanged: (v) => setState(() => hours = v!),
                  ),
                  const SizedBox(width: 24),
                  DropdownButton<int>(
                    value: minutes,
                    items: List.generate(
                      60,
                      (i) => DropdownMenuItem(value: i, child: Text('$i m')),
                    ),
                    onChanged: (v) => setState(() => minutes = v!),
                  ),
                ],
              ),
            ] else ...[  
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.work_outline, color: Colors.deepPurple),
                        title: const Text('Work duration'),
                        subtitle: Text('$pomodoroWorkMin minutes'),
                        trailing: SizedBox(
                          width: 140,
                          child: Slider(
                            value: pomodoroWorkMin.toDouble(),
                            min: 5,
                            max: 60,
                            divisions: 11,
                            label: '$pomodoroWorkMin min',
                            onChanged: (v) async {
                              setState(() => pomodoroWorkMin = v.round());
                              final prefs = await SharedPreferences.getInstance();
                              await prefs.setInt('pomo_work_min', pomodoroWorkMin);
                            },
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.coffee_outlined, color: Colors.green),
                        title: const Text('Break duration'),
                        subtitle: Text('$pomodoroBreakMin minutes'),
                        trailing: SizedBox(
                          width: 140,
                          child: Slider(
                            value: pomodoroBreakMin.toDouble(),
                            min: 1,
                            max: 30,
                            divisions: 29,
                            label: '$pomodoroBreakMin min',
                            activeColor: Colors.green,
                            onChanged: (v) async {
                              setState(() => pomodoroBreakMin = v.round());
                              final prefs = await SharedPreferences.getInstance();
                              await prefs.setInt('pomo_break_min', pomodoroBreakMin);
                            },
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('Rounds: ', style: TextStyle(fontSize: 16)),
                          DropdownButton<int>(
                            value: pomodoroRounds,
                            items: List.generate(
                              8,
                              (i) => DropdownMenuItem(
                                value: i + 1,
                                child: Text('${i + 1}'),
                              ),
                            ),
                            onChanged: (v) => setState(() => pomodoroRounds = v!),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: uploadingBefore ? null : () async {
  if (!kIsWeb) {
    final hasPermission = await requestCameraPermission(context);
    if (!hasPermission) return;
  }

  XFile? pickedFile;
  if (kIsWeb) {
    pickedFile = await captureWebPhoto(context);
  } else {
    final picker = ImagePicker();
    pickedFile = await picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.rear,
      imageQuality: 85,
    );
  }

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
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ActiveSessionScreen(
                            totalSeconds: pomodoroMode
                                ? pomodoroRounds *
                                    (pomodoroWorkMin + pomodoroBreakMin) *
                                    60
                                : (hours * 3600) + (minutes * 60),
                            beforePhoto: beforePhoto!,
                            pomodoroMode: pomodoroMode,
                            workSeconds: pomodoroWorkMin * 60,
                            breakSeconds: pomodoroBreakMin * 60,
                            pomodoroRounds: pomodoroRounds,
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
  final bool pomodoroMode;
  final int workSeconds;
  final int breakSeconds;
  final int pomodoroRounds;

  const ActiveSessionScreen({
    super.key,
    required this.totalSeconds,
    required this.beforePhoto,
    this.pomodoroMode = false,
    this.workSeconds = 1500,
    this.breakSeconds = 300,
    this.pomodoroRounds = 4,
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
  int currentRound = 1;
  bool isBreak = false;
  int totalWorkSecondsElapsed = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    remaining = widget.pomodoroMode ? widget.workSeconds : widget.totalSeconds;
    startTimer();
  }

  void startTimer() {
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!paused && remaining > 0) {
        setState(() {
          remaining--;
          if (widget.pomodoroMode && !isBreak) totalWorkSecondsElapsed++;
        });
      }
      if (remaining == 0) {
        timer?.cancel();
        if (widget.pomodoroMode) {
          _handlePomodoroPhaseEnd();
        } else {
          setState(() => burnout = true);
        }
      }
    });
  }

  void _handlePomodoroPhaseEnd() {
    if (!isBreak) {
      if (currentRound >= widget.pomodoroRounds) {
        setState(() => burnout = true);
      } else {
        setState(() {
          isBreak = true;
          remaining = widget.breakSeconds;
        });
        startTimer();
      }
    } else {
      setState(() {
        isBreak = false;
        currentRound++;
        remaining = widget.workSeconds;
      });
      startTimer();
    }
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
    final elapsed = widget.pomodoroMode
        ? totalWorkSecondsElapsed
        : widget.totalSeconds - remaining;
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
            if (widget.pomodoroMode) ...[  
              Text(
                isBreak
                    ? 'Break  •  Round $currentRound/${widget.pomodoroRounds}'
                    : 'Work  •  Round $currentRound/${widget.pomodoroRounds}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: isBreak ? Colors.green : Colors.deepPurple,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              format(remaining),
              style: TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.bold,
                color: widget.pomodoroMode && isBreak ? Colors.green : null,
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

        XFile? pickedFile;
        if (kIsWeb) {
          pickedFile = await captureWebPhoto(context);
        } else {
          final picker = ImagePicker();
          pickedFile = await picker.pickImage(
            source: ImageSource.camera,
            preferredCameraDevice: CameraDevice.rear,
            imageQuality: 85,
          );
        }

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

/* ================= SETTINGS SCREEN ================= */

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Text(
            'SigEp Studs Privacy Policy',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 12),
          Text(
            'Last updated: March 7, 2026',
            style: TextStyle(fontSize: 14, color: Colors.black54),
          ),
          SizedBox(height: 20),
          Text(
            'Information We Collect',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text(
            'We may collect your name, partner name, session details, and before/after study photos you submit in the app.',
          ),
          SizedBox(height: 16),
          Text(
            'How We Use Information',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text(
            'We use this information to log study sessions, support partner accountability, and improve the app experience.',
          ),
          SizedBox(height: 16),
          Text(
            'Storage and Processing',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text(
            'Session data and uploaded photos are processed using connected Google services used by this app.',
          ),
          SizedBox(height: 16),
          Text(
            'Sharing',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text(
            'We do not sell your personal information. Data is shared only as needed to operate core app features.',
          ),
          SizedBox(height: 16),
          Text(
            'Your Choices',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text(
            'You can stop using the app at any time and sign out to clear locally stored app data on your device.',
          ),
          SizedBox(height: 16),
          Text(
            'Contact',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text(
            'If you have privacy questions, contact the app administrator or chapter leadership.',
          ),
          SizedBox(height: 24),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int workMin = 25;
  int breakMin = 5;
  String firstName = '';
  String lastName = '';
  String email = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      workMin = prefs.getInt('pomo_work_min') ?? 25;
      breakMin = prefs.getInt('pomo_break_min') ?? 5;
      firstName = prefs.getString('first_name') ?? '';
      lastName = prefs.getString('last_name') ?? '';
      email = prefs.getString('user_email') ?? '';
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pomo_work_min', workMin);
    await prefs.setInt('pomo_break_min', breakMin);
  }

  Future<void> _signOut(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign Out', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (!context.mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // User card
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.deepPurple,
                child: Text(
                  firstName.isNotEmpty ? firstName[0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
              title: Text('$firstName $lastName',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(email),
            ),
          ),
          const SizedBox(height: 24),

          // Pomodoro section
          Text(
            'POMODORO',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.grey[600],
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.work_outline, color: Colors.deepPurple),
                  title: const Text('Work duration'),
                  subtitle: Text('$workMin minutes'),
                  trailing: SizedBox(
                    width: 150,
                    child: Slider(
                      value: workMin.toDouble(),
                      min: 5,
                      max: 60,
                      divisions: 11,
                      label: '$workMin min',
                      onChanged: (v) {
                        setState(() => workMin = v.round());
                        _save();
                      },
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.coffee_outlined, color: Colors.green),
                  title: const Text('Break duration'),
                  subtitle: Text('$breakMin minutes'),
                  trailing: SizedBox(
                    width: 150,
                    child: Slider(
                      value: breakMin.toDouble(),
                      min: 1,
                      max: 30,
                      divisions: 29,
                      label: '$breakMin min',
                      activeColor: Colors.green,
                      onChanged: (v) {
                        setState(() => breakMin = v.round());
                        _save();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const PrivacyPolicyScreen(),
              ),
            ),
            icon: const Icon(Icons.privacy_tip_outlined),
            label: const Text('Privacy Policy'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 32),

          OutlinedButton.icon(
            onPressed: () => _signOut(context),
            icon: const Icon(Icons.logout, color: Colors.red),
            label: const Text('Sign Out', style: TextStyle(color: Colors.red)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.red),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }
}
