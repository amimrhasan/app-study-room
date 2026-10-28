import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Color(0xFF07884B),
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const StudyRoomApp());
}

class StudyRoomApp extends StatelessWidget {
  const StudyRoomApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Study Room - Junaid',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF07884B)),
        useMaterial3: true,
      ),
      home: const StudyRoomWebViewScreen(),
    );
  }
}

class StudyRoomWebViewScreen extends StatefulWidget {
  const StudyRoomWebViewScreen({super.key});

  @override
  State<StudyRoomWebViewScreen> createState() => _StudyRoomWebViewScreenState();
}

class _StudyRoomWebViewScreenState extends State<StudyRoomWebViewScreen> {
  late final WebViewController _controller;
  HttpServer? _localVideoServer;
  int _serverPort = 0;
  Directory? _offlineDir;

  final YoutubeExplode _yt = YoutubeExplode();
  final Dio _dio = Dio();
  final Map<String, CancelToken> _cancelTokens = {};
  final Set<String> _cancelledDownloads = {};

  bool _isReady = false;

  @override
  void initState() {
    super.initState();
    _bootstrapApp();
  }

  Future<void> _bootstrapApp() async {
    final docDir = await getApplicationDocumentsDirectory();
    _offlineDir = Directory('${docDir.path}/offline_videos');
    if (!await _offlineDir!.exists()) {
      await _offlineDir!.create(recursive: true);
    }

    await _startLocalVideoStreamingServer();
    await _initWebView();
    if (mounted) {
      setState(() => _isReady = true);
    }
  }

  /// Runs a lightweight local HTTP server on 127.0.0.1 with HTTP 206 Range request support
  /// so the HTML5 <video> player inside WebView can seek (10s skip), change speed (1x-3x),
  /// and play downloaded MP4 files seamlessly with zero internet connection.
  Future<void> _startLocalVideoStreamingServer() async {
    _localVideoServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _serverPort = _localVideoServer!.port;

    _localVideoServer!.listen((HttpRequest req) async {
      req.response.headers.set('Access-Control-Allow-Origin', '*');
      req.response.headers.set('Accept-Ranges', 'bytes');

      final path = req.uri.path;
      if (path.startsWith('/video/')) {
        final rawFileName = Uri.decodeComponent(path.substring('/video/'.length));
        final safeName = rawFileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        final file = File('${_offlineDir!.path}/$safeName');

        if (!await file.exists()) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }

        final length = await file.length();
        final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);

        req.response.headers.contentType = ContentType('video', 'mp4');

        if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
          final parts = rangeHeader.substring(6).split('-');
          final start = int.tryParse(parts[0]) ?? 0;
          final end = (parts.length > 1 && parts[1].isNotEmpty)
              ? (int.tryParse(parts[1]) ?? (length - 1))
              : (length - 1);

          final clampedStart = start.clamp(0, length - 1);
          final clampedEnd = end.clamp(clampedStart, length - 1);
          final chunkLen = (clampedEnd - clampedStart) + 1;

          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $clampedStart-$clampedEnd/$length',
          );
          req.response.contentLength = chunkLen;

          await req.response.addStream(file.openRead(clampedStart, clampedEnd + 1));
          await req.response.close();
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = length;
          await req.response.addStream(file.openRead());
          await req.response.close();
        }
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    });
  }

  Future<void> _initWebView() async {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0A100D))
      ..addJavaScriptChannel(
        'FlutterOfflineBridge',
        onMessageReceived: (JavaScriptMessage msg) {
          _handleBridgeMessage(msg.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _syncExistingOfflineVideosToJs();
          },
        ),
      );

    await _controller.loadFlutterAsset('assets/index.html');
  }

  String _safeFileNameForClass(String classId) {
    final cleaned = classId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return '$cleaned.mp4';
  }

  String _localStreamUrlForClass(String classId) {
    final fileName = _safeFileNameForClass(classId);
    return 'http://127.0.0.1:$_serverPort/video/$fileName';
  }

  Future<void> _syncExistingOfflineVideosToJs() async {
    if (_offlineDir == null || !await _offlineDir!.exists()) return;
    final Map<String, dynamic> items = {};

    await for (final entity in _offlineDir!.list()) {
      if (entity is File && entity.path.endsWith('.mp4')) {
        final name = entity.uri.pathSegments.last;
        final classId = name.substring(0, name.length - 4);
        final stat = await entity.stat();
        items[classId] = {
          'localUrl': _localStreamUrlForClass(classId),
          'sizeBytes': stat.size,
          'downloadedAt': stat.modified.millisecondsSinceEpoch,
        };
      }
    }

    final payloadJson = jsonEncode({
      'port': _serverPort,
      'items': items,
    });
    await _controller.runJavaScript(
      'if(window.__onFlutterOfflineSync) window.__onFlutterOfflineSync(${jsonEncode(payloadJson)});',
    );
  }

  Future<void> _handleBridgeMessage(String rawJson) async {
    try {
      final data = jsonDecode(rawJson) as Map<String, dynamic>;
      final action = (data['action'] ?? '').toString();
      final classId = (data['classId'] ?? '').toString();
      if (classId.isEmpty) return;

      if (action == 'download') {
        final ytId = (data['youtubeId'] ?? '').toString();
        final videoUrl = (data['videoUrl'] ?? '').toString();
        await _downloadVideoForClass(
          classId: classId,
          youtubeId: ytId,
          videoUrl: videoUrl,
        );
      } else if (action == 'cancel') {
        _cancelledDownloads.add(classId);
        _cancelTokens[classId]?.cancel('User cancelled download');
      } else if (action == 'delete') {
        final file = File('${_offlineDir!.path}/${_safeFileNameForClass(classId)}');
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint('Bridge message error: $e');
    }
  }

  Future<void> _downloadVideoForClass({
    required String classId,
    required String youtubeId,
    required String videoUrl,
  }) async {
    _cancelledDownloads.remove(classId);
    final fileName = _safeFileNameForClass(classId);
    final tempFile = File('${_offlineDir!.path}/$fileName.part');
    final finalFile = File('${_offlineDir!.path}/$fileName');

    try {
      if (youtubeId.isNotEmpty) {
        // 1. Download YouTube video directly using youtube_explode_dart (Muxed MP4 stream with audio+video)
        final manifest = await _yt.videos.streamsClient.getManifest(youtubeId);
        final muxedStreams = manifest.muxed.sortByVideoQuality();
        if (muxedStreams.isEmpty) {
          throw Exception('এই YouTube ভিডিওটির ডাউনলোডযোগ্য স্ট্রিম পাওয়া যায়নি।');
        }

        // Pick best muxed MP4 stream (usually 720p or 360p)
        final streamInfo = muxedStreams.last;
        final totalBytes = streamInfo.size.totalBytes;
        final totalMB = totalBytes / (1024 * 1024);

        final stream = _yt.videos.streamsClient.get(streamInfo);
        final sink = tempFile.openWrite();
        int receivedBytes = 0;
        int lastUpdateMs = 0;

        await for (final chunk in stream) {
          if (_cancelledDownloads.contains(classId)) {
            await sink.close();
            if (await tempFile.exists()) await tempFile.delete();
            return;
          }
          sink.add(chunk);
          receivedBytes += chunk.length;

          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - lastUpdateMs > 250) {
            lastUpdateMs = nowMs;
            final pct = totalBytes > 0 ? (receivedBytes / totalBytes) * 100 : 0.0;
            final recMB = receivedBytes / (1024 * 1024);
            await _controller.runJavaScript(
              'if(window.__onFlutterDownloadProgress) window.__onFlutterDownloadProgress(${jsonEncode(classId)}, ${pct.toStringAsFixed(1)}, ${recMB.toStringAsFixed(2)}, ${totalMB.toStringAsFixed(2)});',
            );
          }
        }

        await sink.flush();
        await sink.close();
      } else {
        // 2. Direct MP4 or Google Drive File Download via Dio
        String directUrl = videoUrl;
        final driveMatch = RegExp(r'drive\.google\.com/file/d/([^/?#]+)').firstMatch(videoUrl);
        if (driveMatch != null) {
          final fileId = driveMatch.group(1);
          directUrl = 'https://drive.google.com/uc?export=download&id=$fileId';
        }

        final cancelToken = CancelToken();
        _cancelTokens[classId] = cancelToken;
        int lastUpdateMs = 0;

        await _dio.download(
          directUrl,
          tempFile.path,
          cancelToken: cancelToken,
          onReceiveProgress: (rec, total) {
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            if (nowMs - lastUpdateMs > 250) {
              lastUpdateMs = nowMs;
              final pct = total > 0 ? (rec / total) * 100 : 50.0;
              final recMB = rec / (1024 * 1024);
              final totMB = total > 0 ? total / (1024 * 1024) : 0.0;
              _controller.runJavaScript(
                'if(window.__onFlutterDownloadProgress) window.__onFlutterDownloadProgress(${jsonEncode(classId)}, ${pct.toStringAsFixed(1)}, ${recMB.toStringAsFixed(2)}, ${totMB.toStringAsFixed(2)});',
              );
            }
          },
        );
      }

      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await tempFile.rename(finalFile.path);
      final sizeBytes = await finalFile.length();
      final streamUrl = _localStreamUrlForClass(classId);

      await _controller.runJavaScript(
        'if(window.__onFlutterDownloadComplete) window.__onFlutterDownloadComplete(${jsonEncode(classId)}, ${jsonEncode(streamUrl)}, $sizeBytes);',
      );
    } catch (err) {
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      if (!_cancelledDownloads.contains(classId)) {
        await _controller.runJavaScript(
          'if(window.__onFlutterDownloadError) window.__onFlutterDownloadError(${jsonEncode(classId)}, ${jsonEncode(err.toString())});',
        );
      }
    } finally {
      _cancelTokens.remove(classId);
    }
  }

  @override
  void dispose() {
    _yt.close();
    _localVideoServer?.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A100D),
        body: SafeArea(
          child: _isReady
              ? WebViewWidget(controller: _controller)
              : const Center(
                  child: CircularProgressIndicator(color: Color(0xFF07884B)),
                ),
        ),
      ),
    );
  }
}
