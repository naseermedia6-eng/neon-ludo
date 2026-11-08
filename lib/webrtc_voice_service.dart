import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

class WebRtcVoiceService {
  WebRtcVoiceService({required this.socket, required this.userId, required this.onPeerState, required this.onError, this.voiceRoomId});

  final IO.Socket socket;
  final String userId;
  final void Function(String userId, bool connected) onPeerState;
  final void Function(String message) onError;
  final String? voiceRoomId;
  final Map<String, RTCPeerConnection> _connections = {};
  final Map<String, List<MediaStreamTrack>> _remoteTracks = {};
  final Map<String, List<RTCIceCandidate>> _pendingCandidates = {};
  final Set<String> _mutedPeers = {};
  MediaStream? _localStream;
  bool _muted = true;
  bool _speakerMuted = false;
  bool _started = false;
  bool _closed = false;
  bool _publishAudio = true;
  late final Function(dynamic) _offerListener = _onOffer;
  late final Function(dynamic) _answerListener = _onAnswer;
  late final Function(dynamic) _candidateListener = _onCandidate;
  late final Function(dynamic) _peerJoinedListener = _onPeerJoined;
  late final Function(dynamic) _peerLeftListener = _onPeerLeft;

  bool get microphoneMuted => _muted;
  bool get speakerMuted => _speakerMuted;
  Set<String> get mutedPeers => Set.unmodifiable(_mutedPeers);

  static const Map<String, dynamic> _configuration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  Future<void> start({bool publishAudio = true}) async {
    if (_started) return;
    if (_closed) throw StateError('Voice service has been closed');
    try {
      _publishAudio = publishAudio;
      if (publishAudio) {
        _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
        for (final track in _localStream!.getAudioTracks()) {
          track.enabled = !_muted;
        }
      }
      socket.on('webrtc_offer', _offerListener);
      socket.on('webrtc_answer', _answerListener);
      socket.on('webrtc_ice_candidate', _candidateListener);
      socket.on('voice_peer_joined', _peerJoinedListener);
      socket.on('voice_peer_left', _peerLeftListener);
      _started = true;
    } catch (error) {
      await _localStream?.dispose();
      _localStream = null;
      onError('Microphone access could not start: $error');
      rethrow;
    }
  }

  Future<void> connectToExistingPeers(Iterable<String> peerIds) async {
    for (final peerId in peerIds) {
      if (_isValidPeer(peerId) && userId.compareTo(peerId) < 0) {
        await _createOffer(peerId);
      }
    }
  }

  Future<void> syncPeers(Iterable<String> peerIds, {required bool publishAudio}) async {
    if (_closed) return;
    final target = peerIds.where(_isValidPeer).toSet();
    final complete = target.length == _connections.length && target.every(_connections.containsKey);
    if (complete && publishAudio == _publishAudio) return;
    for (final peerId in _connections.keys.toList()) {
      final pc = _connections.remove(peerId);
      await pc?.close();
      await pc?.dispose();
      _remoteTracks.remove(peerId);
      onPeerState(peerId, false);
    }
    _pendingCandidates.clear();
    if (publishAudio != _publishAudio) {
      if (publishAudio) {
        _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
        for (final track in _localStream!.getAudioTracks()) { track.enabled = !_muted; }
      } else {
        for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) { await track.stop(); }
        await _localStream?.dispose();
        _localStream = null;
      }
      _publishAudio = publishAudio;
    }
    await connectToExistingPeers(target);
  }

  bool _isValidPeer(String peerId) => peerId.isNotEmpty && peerId != userId && !peerId.startsWith('bot:');

  Future<RTCPeerConnection> _connection(String peerId) async {
    final existing = _connections[peerId];
    if (existing != null) return existing;
    if (!_started) throw StateError('Voice service has not started');
    final pc = await createPeerConnection(_configuration, {
      'mandatory': <String, dynamic>{},
      'optional': <Map<String, dynamic>>[],
    });
    _connections[peerId] = pc;
    if (_publishAudio && _localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        await pc.addTrack(track, _localStream!);
      }
    } else {
      await pc.addTransceiver(kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));
    }
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      socket.emit('webrtc_ice_candidate', {
        'toUserId': peerId,
        'candidate': candidate.toMap(),
        if (voiceRoomId != null) 'voiceRoomId': voiceRoomId,
      });
    };
    pc.onTrack = (event) {
      if (event.track.kind != 'audio') return;
      final tracks = event.streams.isNotEmpty ? event.streams.first.getAudioTracks() : <MediaStreamTrack>[event.track];
      _remoteTracks[peerId] = tracks;
      _applyPeerMute(peerId);
      onPeerState(peerId, true);
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onPeerState(peerId, true);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        onPeerState(peerId, false);
      }
    };
    return pc;
  }

  Future<void> _createOffer(String peerId) async {
    try {
      final pc = await _connection(peerId);
      if (pc.signalingState != RTCSignalingState.RTCSignalingStateStable) return;
      final offer = await pc.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': false});
      await pc.setLocalDescription(offer);
      socket.emit('webrtc_offer', {'toUserId': peerId, 'description': {'type': offer.type, 'sdp': offer.sdp}, if (voiceRoomId != null) 'voiceRoomId': voiceRoomId});
    } catch (error) {
      onError('Could not connect voice to player: $error');
    }
  }

  Future<void> _onPeerJoined(dynamic data) async {
    if (data is! Map) return;
    if (voiceRoomId != null && !voiceRoomId!.startsWith('match:')) return;
    final peerId = data['userId']?.toString() ?? '';
    if (_isValidPeer(peerId) && userId.compareTo(peerId) < 0) await _createOffer(peerId);
  }

  Future<void> _onOffer(dynamic data) async {
    if (data is! Map) return;
    if (voiceRoomId != null && data['voiceRoomId'] != voiceRoomId) return;
    final peerId = data['fromUserId']?.toString() ?? '';
    final description = data['description'];
    if (!_isValidPeer(peerId) || description is! Map) return;
    try {
      final pc = await _connection(peerId);
      await pc.setRemoteDescription(RTCSessionDescription(description['sdp']?.toString(), description['type']?.toString()));
      await _flushCandidates(peerId, pc);
      final answer = await pc.createAnswer({'offerToReceiveAudio': true, 'offerToReceiveVideo': false});
      await pc.setLocalDescription(answer);
      socket.emit('webrtc_answer', {'toUserId': peerId, 'description': {'type': answer.type, 'sdp': answer.sdp}, if (voiceRoomId != null) 'voiceRoomId': voiceRoomId});
    } catch (error) {
      onError('Could not answer the voice connection: $error');
    }
  }

  Future<void> _onAnswer(dynamic data) async {
    if (data is! Map) return;
    if (voiceRoomId != null && data['voiceRoomId'] != voiceRoomId) return;
    final peerId = data['fromUserId']?.toString() ?? '';
    final description = data['description'];
    if (!_isValidPeer(peerId) || description is! Map) return;
    try {
      final pc = _connections[peerId];
      if (pc == null) return;
      await pc.setRemoteDescription(RTCSessionDescription(description['sdp']?.toString(), description['type']?.toString()));
      await _flushCandidates(peerId, pc);
    } catch (error) {
      onError('Could not finish the voice connection: $error');
    }
  }

  Future<void> _onCandidate(dynamic data) async {
    if (data is! Map) return;
    if (voiceRoomId != null && data['voiceRoomId'] != voiceRoomId) return;
    final peerId = data['fromUserId']?.toString() ?? '';
    final raw = data['candidate'];
    if (!_isValidPeer(peerId) || raw is! Map) return;
    final candidate = RTCIceCandidate(raw['candidate']?.toString(), raw['sdpMid']?.toString(), (raw['sdpMLineIndex'] as num?)?.toInt());
    final pc = _connections[peerId];
    if (pc == null || await pc.getRemoteDescription() == null) {
      _pendingCandidates.putIfAbsent(peerId, () => []).add(candidate);
    } else {
      try { await pc.addCandidate(candidate); } catch (error) { onError('Could not add a voice network candidate: $error'); }
    }
  }

  Future<void> _flushCandidates(String peerId, RTCPeerConnection pc) async {
    final candidates = _pendingCandidates.remove(peerId) ?? [];
    for (final candidate in candidates) {
      await pc.addCandidate(candidate);
    }
  }

  void setMicrophoneMuted(bool muted) {
    _muted = muted;
    for (final track in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  void setSpeakerMuted(bool muted) {
    _speakerMuted = muted;
    for (final peerId in _remoteTracks.keys) {
      _applyPeerMute(peerId);
    }
  }

  void setPeerMuted(String peerId, bool muted) {
    if (muted) { _mutedPeers.add(peerId); } else { _mutedPeers.remove(peerId); }
    _applyPeerMute(peerId);
  }

  bool isPeerMuted(String peerId) => _speakerMuted || _mutedPeers.contains(peerId);

  void _applyPeerMute(String peerId) {
    final enabled = !_speakerMuted && !_mutedPeers.contains(peerId);
    for (final track in _remoteTracks[peerId] ?? <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  Future<void> _onPeerLeft(dynamic data) async {
    if (data is! Map) return;
    if (voiceRoomId != null && !voiceRoomId!.startsWith('match:')) return;
    final peerId = data['userId']?.toString() ?? '';
    if (peerId.isEmpty) return;
    final pc = _connections.remove(peerId);
    _remoteTracks.remove(peerId);
    _pendingCandidates.remove(peerId);
    _mutedPeers.remove(peerId);
    await pc?.close();
    await pc?.dispose();
    onPeerState(peerId, false);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    socket.off('webrtc_offer', _offerListener);
    socket.off('webrtc_answer', _answerListener);
    socket.off('webrtc_ice_candidate', _candidateListener);
    socket.off('voice_peer_joined', _peerJoinedListener);
    socket.off('voice_peer_left', _peerLeftListener);
    for (final pc in _connections.values) {
      await pc.close();
      await pc.dispose();
    }
    _connections.clear();
    _remoteTracks.clear();
    _pendingCandidates.clear();
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _localStream?.dispose();
    _localStream = null;
    _started = false;
  }
}
