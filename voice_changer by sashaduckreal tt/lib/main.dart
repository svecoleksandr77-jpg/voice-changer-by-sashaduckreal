import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Voice Changer',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xFF2EC4B6),
        ),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final key = TextEditingController();
  final voice = TextEditingController();
  final model = TextEditingController(text: 's1');
  final lang = TextEditingController(text: 'ru');
  final rec = AudioRecorder();
  final player = AudioPlayer();
  bool auto = false, recording = false;
  String status = 'Введите ключ и ID голоса';
  String? lastFile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      key.text = p.getString('key') ?? '';
      voice.text = p.getString('voice') ?? '';
      model.text = p.getString('model') ?? 's1';
      lang.text = p.getString('lang') ?? 'ru';
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('key', key.text.trim());
    await p.setString('voice', voice.text.trim());
    await p.setString('model', model.text.trim());
    await p.setString('lang', lang.text.trim());
  }

  Future<String> _tmp(String name) async {
    final d = await getTemporaryDirectory();
    return '${d.path}${Platform.pathSeparator}$name';
  }

  static const _cfg =
      RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1);

  Future<void> _toggle() async {
    if (recording) {
      final p = await rec.stop();
      setState(() => recording = false);
      if (p != null) await _process(p);
      return;
    }
    if (!await rec.hasPermission()) {
      setState(() => status = 'Нет доступа к микрофону. Разрешите его в настройках.');
      return;
    }
    await rec.start(_cfg, path: await _tmp('in.wav'));
    setState(() {
      recording = true;
      status = 'Идёт запись. Нажмите ещё раз, чтобы остановить.';
    });
  }

  Future<void> _setAuto(bool v) async {
    if (v && !await rec.hasPermission()) {
      setState(() => status = 'Нет доступа к микрофону. Разрешите его в настройках.');
      return;
    }
    setState(() => auto = v);
    if (v) _autoLoop();
  }

  Future<void> _autoLoop() async {
    while (auto && mounted) {
      await rec.start(_cfg, path: await _tmp('in.wav'));
      setState(() {
        recording = true;
        status = 'Слушаю...';
      });
      var spoke = false;
      final start = DateTime.now();
      var last = start;
      while (auto) {
        await Future.delayed(const Duration(milliseconds: 100));
        final a = await rec.getAmplitude();
        final now = DateTime.now();
        if (a.current > -35) {
          spoke = true;
          last = now;
        }
        if (spoke && now.difference(last).inMilliseconds > 900) break;
        if (!spoke && now.difference(start).inSeconds > 20) break;
      }
      final p = await rec.stop();
      setState(() => recording = false);
      if (spoke && p != null) await _process(p);
    }
    if (mounted) setState(() => status = 'Авто-режим выключен');
  }

  Future<void> _process(String path) async {
    await _save();
    final auth = {'Authorization': 'Bearer ${key.text.trim()}'};
    try {
      setState(() => status = 'Распознаю речь...');
      final req = http.MultipartRequest(
          'POST', Uri.parse('https://api.fish.audio/v1/asr'))
        ..headers.addAll(auth)
        ..fields['language'] = lang.text.trim()
        ..fields['ignore_timestamps'] = 'true'
        ..files.add(await http.MultipartFile.fromPath('audio', path));
      final r = await http.Response.fromStream(await req.send());
      if (r.statusCode != 200) throw 'Распознавание ${r.statusCode}: ${r.body}';
      final text =
          (jsonDecode(utf8.decode(r.bodyBytes))['text'] ?? '').toString().trim();
      if (text.isEmpty) {
        setState(() => status = 'Речь не распознана');
        return;
      }
      setState(() => status = 'Озвучиваю: $text');
      final t = await http.post(
        Uri.parse('https://api.fish.audio/v1/tts'),
        headers: {
          ...auth,
          'Content-Type': 'application/json',
          'model': model.text.trim(),
        },
        body: jsonEncode({
          'text': text,
          'reference_id': voice.text.trim(),
          'format': 'mp3',
        }),
      );
      if (t.statusCode != 200) throw 'Озвучка ${t.statusCode}: ${t.body}';
      final out = await _tmp('out_${DateTime.now().millisecondsSinceEpoch}.mp3');
      await File(out).writeAsBytes(t.bodyBytes);
      lastFile = out;
      final fin = player.onPlayerComplete.first;
      await player.play(DeviceFileSource(out));
      await fin.timeout(const Duration(minutes: 2), onTimeout: () {});
      setState(() => status = 'Готово: $text');
    } catch (e) {
      setState(() => status = 'Ошибка: $e');
    }
  }

  Widget _field(TextEditingController c, String label,
          {bool secret = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          obscureText: secret,
          onChanged: (_) => _save(),
          decoration:
              InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice Changer')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(padding: const EdgeInsets.all(20), children: [
            _field(key, 'API-ключ Fish Audio', secret: true),
            _field(voice, 'ID голоса (reference_id)'),
            Row(children: [
              Expanded(child: _field(model, 'Модель')),
              const SizedBox(width: 12),
              Expanded(child: _field(lang, 'Язык речи')),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Авто-режим'),
              subtitle: const Text('Сам слушает микрофон и озвучивает фразы'),
              value: auto,
              onChanged: _setAuto,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 64,
              child: FilledButton.icon(
                onPressed: auto ? null : _toggle,
                icon: Icon(recording ? Icons.stop : Icons.mic),
                label: Text(recording ? 'Стоп' : 'Говорить',
                    style: const TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 16),
            Text(status),
            const SizedBox(height: 12),
            if (lastFile != null)
              OutlinedButton.icon(
                onPressed: () => Share.shareXFiles([XFile(lastFile!)]),
                icon: const Icon(Icons.share),
                label: const Text('Отправить последнее аудио'),
              ),
          ]),
        ),
      ),
    );
  }
}
