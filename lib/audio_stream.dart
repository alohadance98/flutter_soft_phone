import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native/baresip_bindings.dart';

/// Một frame âm thanh = 20 ms PCM 16-bit mono 8 kHz = 160 mẫu = 320 byte.
const int kAudioFrameBytes = 320;
const Duration kAudioFrameDuration = Duration(milliseconds: 20);

/// Đọc âm thanh **từ cuộc gọi về Dart** (để nhận dạng giọng nói, VAD, ghi file...).
///
/// Mỗi 20 ms lấy một frame từ ring buffer RX của DLL và phát qua [frames].
/// Có thể có nhiều listener (broadcast).
class AudioRxStream {
  AudioRxStream(this._native) : _ring = _native.rxRingBuffer();

  final BaresipBindings _native;
  final Pointer<Void> _ring;
  final StreamController<Uint8List> _frames = StreamController.broadcast();
  Timer? _timer;

  Stream<Uint8List> get frames => _frames.stream;

  bool get isReading => _timer != null;

  void start() {
    _timer ??= Timer.periodic(kAudioFrameDuration, (_) => _pumpOneFrame());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _native.rxReset(_ring);
  }

  void dispose() {
    stop();
    _frames.close();
  }

  void _pumpOneFrame() {
    final ptr = _native.rxPeek(_ring);
    if (ptr == nullptr) return; // buffer rỗng
    // Phải copy ra trước khi consume, vì native sẽ ghi đè vùng nhớ này.
    final frame = Uint8List.fromList(ptr.asTypedList(kAudioFrameBytes));
    _native.rxConsume(_ring);
    _frames.add(frame);
  }
}

/// Ghi âm thanh **từ Dart ra cuộc gọi** (phát câu trả lời tự động, nhạc chờ...).
class AudioTxStream {
  AudioTxStream(this._native) : _ring = _native.txRingBuffer();

  final BaresipBindings _native;
  final Pointer<Void> _ring;

  /// Đẩy một frame PCM vào ring buffer TX. Frame nên đúng [kAudioFrameBytes].
  void pushFrame(Uint8List frame) {
    if (frame.isEmpty) return;
    final buffer = malloc.allocate<Uint8>(frame.length);
    try {
      buffer.asTypedList(frame.length).setAll(0, frame);
      _native.txPush(_ring, buffer.cast<Void>());
    } finally {
      malloc.free(buffer);
    }
  }

  /// Xoá dữ liệu đang chờ trong buffer TX.
  void reset() => _native.txReset(_ring);

  /// Phát một đoạn PCM thô theo thời gian thực (20 ms / frame).
  /// Future hoàn thành khi đã đẩy hết dữ liệu.
  Future<void> playPcm(Uint8List pcm) {
    final done = Completer<void>();
    var offset = 0;
    Timer.periodic(kAudioFrameDuration, (timer) {
      if (offset >= pcm.length) {
        timer.cancel();
        done.complete();
        return;
      }
      final end = (offset + kAudioFrameBytes).clamp(0, pcm.length);
      pushFrame(pcm.sublist(offset, end));
      offset = end;
    });
    return done.future;
  }

  /// Phát file WAV (PCM 16-bit mono 8 kHz, header chuẩn 44 byte).
  Future<void> playWav(Uint8List wavBytes) {
    const headerSize = 44;
    if (wavBytes.length <= headerSize) return Future.value();
    return playPcm(wavBytes.sublist(headerSize));
  }
}
