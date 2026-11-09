import 'package:audioplayers/audioplayers.dart';

class GameAudio {
  GameAudio._();

  static final AudioPlayer _player = AudioPlayer();

  static Future<void> dice() => _play('dice_roll.mp3');
  static Future<void> tokenMove() => _play('token_move.mp3');
  static Future<void> tokenCapture() => _play('1kills.mp3');
  static Future<void> tripleSix() => _play('threeSix.mp3');
  static Future<void> victory() => _play('cheer.mp3');

  static Future<void> _play(String file) async {
    try {
      await _player.stop();
      await _player.play(AssetSource('audio/$file'));
    } on Object {
      // Sound failures should never interrupt a match or animation.
    }
  }
}
