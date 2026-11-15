
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:gal/gal.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PhotoMotionApp());
}

class PhotoMotionApp extends StatelessWidget {
  const PhotoMotionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Photo Motion',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF10121B),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF9B7BFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImagePicker _picker = ImagePicker();
  final PageController _pageController = PageController();

  List<XFile> _photos = [];
  int _currentIndex = 0;
  String _transition = 'Dissolve';
  bool _exporting = false;
  double _progress = 0;
  String _status = 'Select 3 to 5 photos to begin';
  String? _videoPath;

  Future<void> _pickPhotos() async {
    try {
      final images = await _picker.pickMultiImage(
        limit: 5,
        imageQuality: 90,
      );

      if (images.isEmpty) return;

      setState(() {
        _photos = images.take(5).toList();
        _currentIndex = 0;
        _videoPath = null;
        _status = '${_photos.length} photos selected';
      });

      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
    } catch (e) {
      _showMessage('Could not open gallery: $e');
    }
  }

  void _removePhoto(int index) {
    setState(() {
      _photos.removeAt(index);
      _currentIndex = 0;
      _videoPath = null;
      _status = '${_photos.length} photos selected';
    });

    if (_pageController.hasClients) {
      _pageController.jumpToPage(0);
    }
  }

  String _quote(String value) {
    return '"${value.replaceAll('"', r'\"')}"';
  }

  Future<String> _createMusicFile(Directory directory) async {
    const sampleRate = 44100;
    const seconds = 20;
    const channels = 2;

    final sampleCount = sampleRate * seconds;
    final bytes = Uint8List(44 + sampleCount * channels * 2);
    final header = ByteData.sublistView(bytes);

    void writeText(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        bytes[offset + i] = text.codeUnitAt(i);
      }
    }

    writeText(0, 'RIFF');
    header.setUint32(4, bytes.length - 8, Endian.little);
    writeText(8, 'WAVE');
    writeText(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * channels * 2, Endian.little);
    header.setUint16(32, channels * 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    writeText(36, 'data');
    header.setUint32(40, sampleCount * channels * 2, Endian.little);

    const chords = [
      [261.63, 329.63, 392.00],
      [220.00, 261.63, 329.63],
      [174.61, 220.00, 261.63],
      [196.00, 246.94, 293.66],
    ];

    for (var i = 0; i < sampleCount; i++) {
      final time = i / sampleRate;
      final chord = chords[(time ~/ 5) % chords.length];

      final fadeIn = min(1.0, time / 1.0);
      final fadeOut = min(1.0, (seconds - time) / 1.0);
      final envelope = min(fadeIn, fadeOut);

      final wave = (
        sin(2 * pi * chord[0] * time) +
        sin(2 * pi * chord[1] * time) +
        sin(2 * pi * chord[2] * time)
      ) / 3;

      final sample = (wave * 0.13 * envelope * 32767)
          .round()
          .clamp(-32768, 32767);

      final offset = 44 + i * channels * 2;
      header.setInt16(offset, sample, Endian.little);
      header.setInt16(offset + 2, sample, Endian.little);
    }

    final file = File('${directory.path}/photo_motion_music.wav');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> _exportVideo() async {
    if (_photos.length < 3 || _photos.length > 5) {
      _showMessage('Please select between 3 and 5 photos.');
      return;
    }

    setState(() {
      _exporting = true;
      _progress = 0;
      _videoPath = null;
      _status = 'Preparing your video...';
    });

    try {
      final directory = await getApplicationDocumentsDirectory();
      final outputPath =
          '${directory.path}/PhotoMotion_${DateTime.now().millisecondsSinceEpoch}.mp4';

      final musicPath = await _createMusicFile(directory);

      final command = StringBuffer();

      for (final photo in _photos) {
        command.write(
          '-loop 1 -framerate 30 -t 4 -i ${_quote(photo.path)} ',
        );
      }

      command.write('-i ${_quote(musicPath)} ');

      final filters = <String>[];

      for (var i = 0; i < _photos.length; i++) {
        filters.add(
          '[$i:v]'
          'scale=1280:720:force_original_aspect_ratio=decrease,'
          'pad=1280:720:(ow-iw)/2:(oh-ih)/2,'
          'setsar=1,fps=30,format=yuv420p[v$i]',
        );
      }

      var previous = 'v0';

      for (var i = 1; i < _photos.length; i++) {
        final output = 'transition$i';
        final offset = 3 * i;

        final transitionName =
            _transition == 'Dissolve' ? 'fade' : 'slideleft';

        filters.add(
          '[$previous][v$i]'
          'xfade=transition=$transitionName:'
          'duration=1:offset=$offset[$output]',
        );

        previous = output;
      }

      final filterGraph = filters.join(';');

      command.write(
        '-filter_complex ${_quote(filterGraph)} '
        '-map "[$previous]" '
        '-map ${_photos.length}:a:0 '
        '-c:v libx264 '
        '-preset ultrafast '
        '-crf 23 '
        '-pix_fmt yuv420p '
        '-c:a aac '
        '-b:a 128k '
        '-shortest '
        '-movflags +faststart '
        '${_quote(outputPath)}',
      );

      setState(() {
        _status = 'Creating video... Please wait';
      });

      final session = await FFmpegKit.execute(command.toString());
      final returnCode = await session.getReturnCode();

      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getOutput();
        throw Exception('Video export failed: ${logs ?? "Unknown error"}');
      }

      final outputFile = File(outputPath);

      if (!await outputFile.exists() || await outputFile.length() == 0) {
        throw Exception('The exported video file is empty.');
      }

      setState(() {
        _progress = 1;
        _status = 'Saving video to your gallery...';
      });

      await Gal.putVideo(outputPath, album: 'Photo Motion');

      if (!mounted) return;

      setState(() {
        _videoPath = outputPath;
        _status = 'Video exported successfully!';
        _exporting = false;
      });

      _showMessage('Your video is saved in your phone gallery!');
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _exporting = false;
        _status = 'Export failed';
      });

      _showMessage('Error: $e');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _sectionTitle(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _photoPreview() {
    if (_photos.isEmpty) {
      return Container(
        height: 220,
        width: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0xFF202333),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white12),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_library_outlined,
                size: 55, color: Color(0xFF9B7BFF)),
            SizedBox(height: 12),
            Text('Your photos will appear here'),
            SizedBox(height: 5),
            Text(
              'Choose 3 to 5 photos',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 230,
        width: double.infinity,
        child: PageView.builder(
          controller: _pageController,
          itemCount: _photos.length,
          onPageChanged: (index) {
            setState(() => _currentIndex = index);
          },
          itemBuilder: (context, index) {
            return Image.file(
              File(_photos[index].path),
              fit: BoxFit.cover,
              width: double.infinity,
            );
          },
        ),
      ),
    );
  }

  Widget _photoThumbnails() {
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _photos.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          return GestureDetector(
            onTap: () => _pageController.animateToPage(
              index,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
            ),
            child: Stack(
              children: [
                Container(
                  width: 82,
                  height: 88,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _currentIndex == index
                          ? const Color(0xFF9B7BFF)
                          : Colors.white12,
                      width: _currentIndex == index ? 2 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Image.file(
                      File(_photos[index].path),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                Positioned(
                  top: 3,
                  right: 3,
                  child: GestureDetector(
                    onTap: () => _removePhoto(index),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: Colors.black87,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, size: 14),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 4,
                  left: 5,
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      shadows: [Shadow(blurRadius: 5)],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _transitionOption(String name, IconData icon) {
    final selected = _transition == name;

    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _transition = name),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF9B7BFF).withOpacity(0.18)
                : const Color(0xFF202333),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? const Color(0xFF9B7BFF)
                  : Colors.white12,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                color: selected ? const Color(0xFFBDA8FF) : Colors.white70,
              ),
              const SizedBox(height: 7),
              Text(
                name,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: selected ? const Color(0xFFBDA8FF) : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF10121B),
        title: const Row(
          children: [
            Icon(Icons.movie_creation_outlined,
                color: Color(0xFFBDA8FF)),
            SizedBox(width: 10),
            Text(
              'Photo Motion',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${_photos.length}/5',
                style: const TextStyle(color: Colors.white60),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF39305C), Color(0xFF202333)],
                  ),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Turn memories into movies',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 7),
                    Text(
                      'Create a beautiful photo slideshow with music and transitions.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 25),
              _sectionTitle('Your photos', 'Select between 3 and 5 pictures'),
              const SizedBox(height: 12),
              _photoPreview(),
              const SizedBox(height: 12),
              _photoThumbnails(),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _exporting ? null : _pickPhotos,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('Choose photos from gallery'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    foregroundColor: const Color(0xFFBDA8FF),
                    side: const BorderSide(color: Color(0xFF9B7BFF)),
                  ),
                ),
              ),
              const SizedBox(height: 27),
              _sectionTitle('Transition style', 'Choose how photos change'),
              const SizedBox(height: 12),
              Row(
                children: [
                  _transitionOption('Dissolve', Icons.blur_on),
                  const SizedBox(width: 12),
                  _transitionOption('Slide', Icons.swipe),
                ],
              ),
              const SizedBox(height: 25),
              _sectionTitle('Background music', 'Original instrumental soundtrack'),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF202333),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: Color(0xFF39305C),
                      child: Icon(Icons.music_note,
                          color: Color(0xFFBDA8FF)),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Dreamy Instrumental',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Soft original background music',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.check_circle, color: Color(0xFF9B7BFF)),
                  ],
                ),
              ),
              const SizedBox(height: 25),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _exporting ? null : _exportVideo,
                  icon: const Icon(Icons.movie_creation),
                  label: Text(
                    _exporting ? 'Creating video...' : 'Create & Export MP4',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF8061D9),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 17),
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_exporting) ...[
                LinearProgressIndicator(value: null),
                const SizedBox(height: 10),
              ],
              Center(
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
              ),
              if (_videoPath != null) ...[
                const SizedBox(height: 14),
                Center(
                  child: TextButton.icon(
                    onPressed: () async {
                      try {
                        await Gal.open();
                      } catch (e) {
                        _showMessage('Could not open gallery: $e');
                      }
                    },
                    icon: const Icon(Icons.video_library),
                    label: const Text('Open phone gallery'),
                  ),
                ),
              ],
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
