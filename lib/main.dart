import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:wakelock_plus/wakelock_plus.dart';

late CameraController _cameraController;
late List<CameraDescription> _cameras;
late HttpServer _server;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Получаем список камер
  _cameras = await availableCameras();
  _cameraController = CameraController(
    _cameras.first,
    ResolutionPreset.medium,
    enableAudio: false,
  );
  await _cameraController.initialize();

  // Запускаем локальный сервер
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(_router);

  _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, 8523);

  // Не даём телефону заснуть
  WakelockPlus.enable();

  runApp(const MyApp());
}

Future<Response> _router(Request req) async {
  if (req.url.path == 'sendsignal') {
    try {
      await _cameraController.setFlashMode(FlashMode.off);

      final XFile file = await _cameraController.takePicture();
      final bytes = await File(file.path).readAsBytes();

      final uri = Uri.parse("https://openrouter.ai/api/v1/chat/completions");
      final response = await http.post(
        uri,
        headers: {
          "Authorization":
              "Bearer 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",
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "model": "google/gemini-2.5-pro",
          "messages": [
            {
              "role": "user",
              "content": [
                {
                  "type": "text",
                  "text":
                      "Ты видишь вопрос SAT. Ответь только буквой правильного варианта (A, B, C или D). Никаких слов, объяснений или дополнительных символов. Только одна буква. Если же слишком размыто или же очень плохо то тогда ответь E"
                },
                {
                  "type": "image_url",
                  "image_url": {
                    "url": "data:image/jpeg;base64,${base64Encode(bytes)}"
                  }
                }
              ]
            }
          ]
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        String output = "";

        if (data["choices"] != null && data["choices"].isNotEmpty) {
          final choice = data["choices"][0];
          final message = choice["message"];

          if (message != null && message["content"] != null) {
            if (message["content"] is String) {
              output = message["content"];
            } else if (message["content"] is List) {
              final contentList = message["content"] as List;
              for (var c in contentList) {
                if (c is Map && c["type"] == "text") {
                  output += c["text"] ?? "";
                }
              }
            }
          }
        }

        return Response.ok(
          output.isNotEmpty ? output : "⚠️ No content in response",
          headers: {"Content-Type": "text/plain; charset=utf-8"},
        );
      } else {
        return Response.internalServerError(
          body: "Error from OpenRouter: ${response.body}",
          headers: {"Content-Type": "text/plain; charset=utf-8"},
        );
      }
    } catch (e) {
      return Response.internalServerError(
        body: "Error: $e",
        headers: {"Content-Type": "text/plain; charset=utf-8"},
      );
    }
  }
  return Response.notFound("Not Found");
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Future<String> _findLanAddress() async {
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          return "📡 http://${addr.address}:${_server.port}/sendsignal";
        }
      }
    }
    return "IP not found";
  }

  @override
  Widget build(BuildContext context) {
    final preview = (_cameraController.value.isInitialized)
        ? Offstage(offstage: true, child: CameraPreview(_cameraController))
        : const SizedBox.shrink();

    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            const SizedBox.expand(),
            Positioned.fill(child: preview),
            Align(
              alignment: Alignment.bottomCenter,
              child: FutureBuilder<String>(
                future: _findLanAddress(),
                builder: (context, snap) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    snap.data ?? "...",
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
