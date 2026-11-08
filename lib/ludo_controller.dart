import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'webrtc_voice_service.dart';

enum PlayerColor { red, green, yellow, blue }
enum GameMode { classic, quick }
extension SafeFirst<T> on Iterable<T> { T? get firstOrNull { final it=this.iterator;return it.moveNext()?it.current:null; } }

extension PlayerColorData on PlayerColor {
  String get label => name[0].toUpperCase() + name.substring(1);
  int get start => switch (this) { PlayerColor.red=>0, PlayerColor.green=>13, PlayerColor.yellow=>26, PlayerColor.blue=>39 };
  List<int> get homeCells => switch (this) {
    PlayerColor.red => List.generate(6,(i)=>7*15+1+i),
    PlayerColor.green => List.generate(6,(i)=>(1+i)*15+7),
    PlayerColor.yellow => List.generate(6,(i)=>7*15+13-i),
    PlayerColor.blue => List.generate(6,(i)=>(13-i)*15+7),
  };
}

class Token { final PlayerColor color; final int id; int progress=-1; Token(this.color,this.id); bool get atBase=>progress==-1; bool get finished=>progress==57; }
class LudoPlayer {
  final PlayerColor color; final bool bot; final List<Token> tokens;
  String userId,name,avatar; bool autoPlay=false,connected=true,micEnabled=false,voiceConnected=false; int captures=0,reactionSerial=0;String? lastChat,lastEmoji;
  LudoPlayer(this.color,{this.bot=false,String? userId,String? name,String? avatar}) : userId=userId??'',name=name??color.label,avatar=avatar??'🙂',tokens=List.generate(4,(i)=>Token(color,i));
  int get completed=>tokens.where((t)=>t.finished).length;
}

class LudoController extends ChangeNotifier {
  LudoController(this.prefs) {
    userId=prefs.getString('userId')??'player-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(9999)}';
    prefs.setString('userId',userId);
    displayName=prefs.getString('displayName')??'Player${Random().nextInt(9000)+1000}';
    avatar=prefs.getString('avatar')??'🙂';
    coins=prefs.getInt('coins')??10000; diamonds=prefs.getInt('diamonds')??50;
    gamesPlayed=prefs.getInt('gamesPlayed')??0; wins=prefs.getInt('wins')??0; totalCaptures=prefs.getInt('totalCaptures')??0;
    xp=prefs.getInt('xp')??0;level=prefs.getInt('level')??1;
    spinNextAt=prefs.getInt('dailySpinNextAt')??0;
    checkinNextAt=prefs.getInt('dailyCheckinNextAt')??0;
    checkinStreak=prefs.getInt('dailyCheckinStreak')??0;
    matchId=prefs.getString('activeMatchId');online=matchId!=null;resumePending=online;
  }
  final SharedPreferences prefs;
  final List<LudoPlayer> players=[];
  late String userId,displayName,avatar;
  int coins=10000,diamonds=50,gamesPlayed=0,wins=0,totalCaptures=0,level=1,xp=0;
  int playerCount=4,currentPlayer=0,dice=0,secondsLeft=15,entryFee=500,matchPrize=0;
  GameMode mode=GameMode.classic;
  bool online=false,connected=false,matching=false,rolling=false,gameStarted=false,gameOver=false,autoPlay=false,entryCharged=false,resumePending=false;
  bool voiceJoined=false,micEnabled=false,speakerMuted=false,voiceStarting=false;
  bool roomMicEnabled=false;
  String? voiceError;
  WebRtcVoiceService? _voiceService;
  WebRtcVoiceService? _voiceRoomService;
  bool _rejoinVoiceAfterSocketReconnect=false;
  final List<Map<String,dynamic>> voiceRooms=[];
  final List<Map<String,dynamic>> roomChat=[];
  Map<String,dynamic>? activeVoiceRoom;
  String? activeVoiceRoomId;
  int roomGiftSerial=0;
  Map<String,dynamic>? lastRoomGift;
  String? _roomAudioSignature;
  List<Map<String,dynamic>> topPlayers=[],topGifters=[];
  int spinNextAt=0,checkinNextAt=0,checkinStreak=0;
  final List<Map<String,dynamic>> voicePeers=[];
  int giftSerial=0;GiftEvent? lastGift;
  final Map<String,Timer> _reactionTimers={};
  static const quickChatPhrases=['Hurry up!','Nice move!','Well played!','Don’t kill me!'];
  static const quickEmojis=['😂','😎','😮','😭','👏','🔥','❤️','😡','🎉','🙏'];
  static const gifts=<GiftItem>[GiftItem('rose','Rose','🌹',100),GiftItem('coffee','Coffee','☕',250),GiftItem('slipper','Slipper','🩴',500),GiftItem('bomb','Bomb','💣',1000),GiftItem('car','Sports Car','🏎️',5000)];
  String status='Ready to play',serverUrl=const String.fromEnvironment('SERVER_URL',defaultValue:'http://localhost:3000');
  String? matchId,privateRoomCode,winnerId; bool? didWin;
  IO.Socket? _socket; Timer? _clock; DateTime? _turnDeadline; int _lastAwardedMatch=0;
  VoidCallback? _pendingConnectAction;
  LudoPlayer get active=>players[currentPlayer.clamp(0,max(players.length-1,0)).toInt()];
  static const List<int> track=[91,92,93,94,95,81,66,51,36,21,6,7,8,23,38,53,68,83,99,100,101,102,103,104,119,134,133,132,131,130,129,143,158,173,188,203,218,217,216,201,186,171,156,141,125,124,123,122,121,120,105,90];
  static const Set<int> safeSquares={0,8,13,21,26,34,39,47};

  Future<void> initialize() async {
    _socket=IO.io(serverUrl,IO.OptionBuilder().setTransports(['websocket','polling']).setAuth({'userId':userId}).enableAutoConnect().enableReconnection().build());
    _socket!.onConnect((_) { connected=true; status='Connected'; notifyListeners(); if(matchId!=null) _socket!.emitWithAck('rejoin_match',null,ack:(dynamic result){if(result is Map&&result['ok']==false){matchId=null;online=false;prefs.remove('activeMatchId');status='No match to reconnect';notifyListeners();}else if(_rejoinVoiceAfterSocketReconnect){_rejoinVoiceAfterSocketReconnect=false;joinMatchVoice();}});final pending=_pendingConnectAction;_pendingConnectAction=null;pending?.call(); });
    _socket!.onDisconnect((_) { connected=false;_rejoinVoiceAfterSocketReconnect=voiceJoined;if(voiceJoined)_closeVoiceService();if(activeVoiceRoomId!=null){_voiceRoomService?.close();_voiceRoomService=null;activeVoiceRoomId=null;activeVoiceRoom=null;roomChat.clear();roomMicEnabled=false;_roomAudioSignature=null;}for(final p in players){p.voiceConnected=false;p.micEnabled=false;}if(online)status='Connection lost • reconnecting'; notifyListeners(); });
    _socket!.onConnectError((_) { connected=false; status='Offline • reconnecting'; notifyListeners(); });
    _socket!.on('queue_joined',(data){ matching=true;status='Searching for players';notifyListeners(); });
    _socket!.on('queue_left',(_){ matching=false;status='Search cancelled';notifyListeners(); });
    _socket!.on('match_found',_onMatchFound);
    _socket!.on('dice_rolled',_onDiceRolled);
    _socket!.on('token_moved',_onTokenMoved);
    _socket!.on('turn_changed',_onTurnChanged);
    _socket!.on('turn_forfeited',(data){dice=0;status='Three sixes — turn forfeited';notifyListeners();});
    _socket!.on('autoplay_enabled',(data){if(data is Map&&data['userId']==userId){autoPlay=true;status='Auto-Play Active';notifyListeners();}});
    _socket!.on('autoplay_disabled',(data){if(data is Map&&data['userId']==userId){autoPlay=false;status='Your turn';notifyListeners();}});
    _socket!.on('sync_state',_onSyncState);
    _socket!.on('game_over',_onGameOver);
    _socket!.on('private_room_created',(data){if(data is Map){privateRoomCode='${data['code']}';notifyListeners();}});
    _socket!.on('voice_peer_joined',(data){if(data is Map){final peerId='${data['userId']}';if(!voicePeers.any((p)=>p['userId']==peerId))voicePeers.add(Map<String,dynamic>.from(data));final player=players.where((p)=>p.userId==peerId).firstOrNull;if(player!=null)player.voiceConnected=true;}notifyListeners();});
    _socket!.on('voice_peer_left',(data){if(data is Map){final peerId='${data['userId']}';voicePeers.removeWhere((p)=>p['userId']==peerId);final player=players.where((p)=>p.userId==peerId).firstOrNull;if(player!=null)player.voiceConnected=false;}notifyListeners();});
    _socket!.on('mic_status_changed',(data){if(data is Map){final peerId='${data['userId']}';final enabled=data['enabled']==true;final p=voicePeers.where((p)=>p['userId']==peerId).firstOrNull;if(p!=null)p['micEnabled']=enabled;final player=players.where((p)=>p.userId==peerId).firstOrNull;if(player!=null)player.micEnabled=enabled;}notifyListeners();});
    _socket!.on('quick_chat_received',_onQuickChat);
    _socket!.on('emoji_received',_onEmoji);
    _socket!.on('gift_thrown',_onGiftThrown);
    _socket!.on('voice_rooms_list',(data){if(data is List){voiceRooms..clear()..addAll(data.whereType<Map>().map((room)=>Map<String,dynamic>.from(room)));notifyListeners();}});
    _socket!.on('voice_room_state',_onVoiceRoomState);
    _socket!.on('voice_room_chat',(data){if(data is Map){roomChat.add(Map<String,dynamic>.from(data));if(roomChat.length>100)roomChat.removeAt(0);notifyListeners();}});
    _socket!.on('room_luxury_gift',(data){if(data is Map){lastRoomGift=Map<String,dynamic>.from(data);roomGiftSerial++;notifyListeners();}});
    _socket!.on('voice_room_peer_left',(data){if(data is Map&&data['voiceRoomId']==activeVoiceRoomId)_syncRoomAudio();});
  }

  Future<Map<String,dynamic>> _request(String event,[dynamic data]) async {
    final socket=_socket;
    if(socket==null||!connected)return {'ok':false,'reason':'Connect to the game server first'};
    final result=Completer<Map<String,dynamic>>();
    socket.emitWithAck(event,data,ack:(dynamic response){if(!result.isCompleted)result.complete(response is Map?Map<String,dynamic>.from(response):{'ok':false,'reason':'The server returned an invalid response'});});
    return result.future.timeout(const Duration(seconds:8),onTimeout:()=>{'ok':false,'reason':'The server did not respond'});
  }

  Future<Map<String,dynamic>> createVoiceRoom({required String title,required String category,required bool isPrivate,String password=''}) async {
    final result=await _request('create_voice_room',{'title':title,'category':category,'isPrivate':isPrivate,'password':password,'name':displayName,'avatar':avatar});
    if(result['ok']==true&&result['room'] is Map)await _activateVoiceRoom(Map<String,dynamic>.from(result['room']),publishAudio:true);
    return result;
  }

  Future<void> refreshVoiceRooms() async {final result=await _request('get_voice_rooms');if(result['ok']==true&&result['rooms'] is List){voiceRooms..clear()..addAll((result['rooms'] as List).whereType<Map>().map((room)=>Map<String,dynamic>.from(room)));notifyListeners();}}

  Future<Map<String,dynamic>> joinVoiceRoom(String roomId,{String password=''}) async {
    if(activeVoiceRoomId!=null&&activeVoiceRoomId!=roomId)return {'ok':false,'reason':'Leave your current room first'};
    final result=await _request('join_voice_room',{'roomId':roomId,'password':password,'name':displayName,'avatar':avatar});
    if(result['ok']==true&&result['room'] is Map)await _activateVoiceRoom(Map<String,dynamic>.from(result['room']),publishAudio:false);
    return result;
  }

  bool get _isRoomSpeaker => (activeVoiceRoom?['seats'] as List? ?? []).any((seat)=>seat is Map&&seat['userId']==userId);
  Iterable<String> _roomPeerIds() {
    final speaker=_isRoomSpeaker;
    return (activeVoiceRoom?['members'] as List? ?? []).whereType<Map>().where((member)=>speaker||member['speaking']==true).map((member)=>'${member['userId']}').where((id)=>id!=userId&&!id.startsWith('bot:'));
  }

  Future<void> _activateVoiceRoom(Map<String,dynamic> room,{required bool publishAudio}) async {
    final roomId='${room['roomId']}';
    activeVoiceRoomId=roomId;activeVoiceRoom=room;roomChat..clear()..addAll((room['chat'] as List? ?? []).whereType<Map>().map((message)=>Map<String,dynamic>.from(message)));roomMicEnabled=false;
    final service=WebRtcVoiceService(socket:_socket!,userId:userId,voiceRoomId:roomId,onPeerState:(peerId,isConnected){notifyListeners();},onError:(message){voiceError=message;notifyListeners();});
    _voiceRoomService=service;
    try{await service.start(publishAudio:publishAudio);_roomAudioSignature=null;_syncRoomAudio();}catch(error){voiceError='Voice room audio could not start: $error';await service.close();_voiceRoomService=null;}
    notifyListeners();
  }

  void _syncRoomAudio(){final service=_voiceRoomService;if(service==null)return;final peers=_roomPeerIds().toSet();final speakers=(activeVoiceRoom?['seats'] as List? ?? []).whereType<Map>().map((seat)=>'${seat['userId']}').toList()..sort();final signature='${_isRoomSpeaker}:${speakers.join(',')}:${(peers.toList()..sort()).join(',')}';if(signature==_roomAudioSignature)return;_roomAudioSignature=signature;service.syncPeers(peers,publishAudio:_isRoomSpeaker).catchError((Object error){voiceError='Voice room connection failed: $error';notifyListeners();});}
  void _onVoiceRoomState(dynamic data){
    if(data is! Map)return;final room=Map<String,dynamic>.from(data);final roomId='${room['roomId']}';
    final index=voiceRooms.indexWhere((item)=>item['roomId']==roomId);if(index>=0)voiceRooms[index]=room;else if(room['hasPassword']!=true)voiceRooms.insert(0,room);
    if(activeVoiceRoomId==roomId){activeVoiceRoom=room;roomChat..clear()..addAll((room['chat'] as List? ?? []).whereType<Map>().map((message)=>Map<String,dynamic>.from(message)));final ownSeat=(room['seats'] as List? ?? []).whereType<Map>().where((seat)=>seat['userId']==userId).firstOrNull;roomMicEnabled=ownSeat?['micEnabled']==true;_syncRoomAudio();}
    notifyListeners();
  }

  Future<Map<String,dynamic>> takeMicSeat(int seatIndex) async {final result=await _request('take_mic_seat',{'seatIndex':seatIndex});if(result['ok']==true&&result['room'] is Map)_onVoiceRoomState(result['room']);return result;}
  Future<Map<String,dynamic>> releaseMicSeat() async {final result=await _request('release_mic_seat');if(result['ok']==true)roomMicEnabled=false;return result;}
  Future<Map<String,dynamic>> lockMicSeat(int seatIndex,bool locked) => _request('lock_mic_seat',{'seatIndex':seatIndex,'locked':locked});
  Future<Map<String,dynamic>> kickMicSeat(String targetUserId) => _request('kick_mic_seat',{'targetUserId':targetUserId});
  Future<Map<String,dynamic>> sendRoomChat(String text) => _request('send_room_chat',{'text':text.trim()});
  Future<Map<String,dynamic>> setRoomMicEnabled(bool enabled) async {
    if(!_isRoomSpeaker)return {'ok':false,'reason':'Take a microphone seat first'};
    final result=await _request('room_mic_status',{'enabled':enabled});
    if(result['ok']==true){roomMicEnabled=enabled;_voiceRoomService?.setMicrophoneMuted(!enabled);final seats=activeVoiceRoom?['seats'] as List? ?? [];for(final seat in seats){if(seat is Map&&seat['userId']==userId)seat['micEnabled']=enabled;}notifyListeners();}
    return result;
  }

  static const roomGifts=<RoomGift>[RoomGift('ring','Diamond Ring','💍',500),RoomGift('sports_car','Sports Car','🏎️',2000),RoomGift('yacht','Luxury Yacht','🛥️',5000),RoomGift('dragon','Flying Dragon','🐉',10000),RoomGift('castle','Palace Castle','🏰',10000)];
  Future<Map<String,dynamic>> sendLuxuryGift(String targetUserId,String giftId) async {
    final gift=roomGifts.where((item)=>item.id==giftId).firstOrNull;
    if(gift==null||diamonds<gift.diamonds)return {'ok':false,'reason':'Not enough diamonds'};
    diamonds-=gift.diamonds;await prefs.setInt('diamonds',diamonds);notifyListeners();
    final response=await _request('send_luxury_gift',{'targetUserId':targetUserId,'giftId':giftId});
    if(response['ok']!=true&&response['reason']!='The server did not respond'){diamonds+=gift.diamonds;await prefs.setInt('diamonds',diamonds);notifyListeners();}
    return response;
  }

  Future<void> leaveVoiceRoom() async {
    final service=_voiceRoomService;_voiceRoomService=null;
    if(activeVoiceRoomId!=null)await _request('leave_voice_room');
    await service?.close();activeVoiceRoomId=null;activeVoiceRoom=null;roomChat.clear();roomMicEnabled=false;_roomAudioSignature=null;notifyListeners();
  }

  Future<Map<String,dynamic>> loadLeaderboards() async {
    final result=await _request('get_leaderboard');
    if(result['ok']==true){topPlayers=(result['topPlayers'] as List? ?? []).whereType<Map>().map((entry)=>Map<String,dynamic>.from(entry)).toList();topGifters=(result['topGifters'] as List? ?? []).whereType<Map>().map((entry)=>Map<String,dynamic>.from(entry)).toList();notifyListeners();}
    return result;
  }

  static const spinRewards=<SpinReward>[SpinReward('coins',200),SpinReward('coins',500),SpinReward('coins',1000),SpinReward('coins',5000),SpinReward('diamonds',5),SpinReward('diamonds',20),SpinReward('diamonds',50),SpinReward('coins',20000)];
  Future<Map<String,dynamic>> spinDailyReward() async {
    if(DateTime.now().millisecondsSinceEpoch<spinNextAt)return {'ok':false,'reason':'Come back when your daily spin is ready','nextSpinAt':spinNextAt};
    final result=await _request('daily_spin');
    if(result['ok']==true){final reward=Map<String,dynamic>.from(result['reward']);final amount=(reward['amount'] as num).toInt();if(reward['type']=='diamonds'){diamonds+=amount;await prefs.setInt('diamonds',diamonds);}else{coins+=amount;await prefs.setInt('coins',coins);}spinNextAt=(result['nextSpinAt'] as num).toInt();await prefs.setInt('dailySpinNextAt',spinNextAt);notifyListeners();}
    return result;
  }
  Future<Map<String,dynamic>> claimDailyCheckin() async {
    final result=await _request('daily_checkin');
    if(result['ok']==true){final reward=Map<String,dynamic>.from(result['reward']);final amount=(reward['amount'] as num).toInt();if(reward['type']=='diamonds'){diamonds+=amount;await prefs.setInt('diamonds',diamonds);}else{coins+=amount;await prefs.setInt('coins',coins);}checkinStreak=(result['streak'] as num).toInt();checkinNextAt=(result['nextClaimAt'] as num).toInt();await prefs.setInt('dailyCheckinStreak',checkinStreak);await prefs.setInt('dailyCheckinNextAt',checkinNextAt);notifyListeners();}
    return result;
  }

  Future<void> _saveWallet() async { await prefs.setInt('coins',coins);await prefs.setInt('diamonds',diamonds);await prefs.setInt('gamesPlayed',gamesPlayed);await prefs.setInt('wins',wins);await prefs.setInt('totalCaptures',totalCaptures);await prefs.setInt('xp',xp);await prefs.setInt('level',level);notifyListeners(); }
  Future<void> updateProfile({String? name,String? newAvatar}) async { if(name!=null){displayName=name.trim().isEmpty?displayName:name.trim().substring(0,min(name.trim().length,24).toInt());await prefs.setString('displayName',displayName);}if(newAvatar!=null){avatar=newAvatar;await prefs.setString('avatar',avatar);}notifyListeners(); }
  Future<void> grantCoins(int amount) async { if(amount>0){coins+=amount;await _saveWallet();} }
  Future<void> startOffline({required GameMode selectedMode,required int count,required bool againstBot}) async {
    online=false;matching=false;mode=selectedMode;playerCount=count;gameStarted=true;gameOver=false;dice=0;currentPlayer=0;autoPlay=false;matchId=null;prefs.remove('activeMatchId');winnerId=null;didWin=null;_cancelClock();
    final colors=count==2?[PlayerColor.red,PlayerColor.yellow]:PlayerColor.values;
    players..clear()..addAll(colors.asMap().entries.map((e)=>LudoPlayer(e.value,bot:againstBot&&e.key>0,userId:e.key==0?userId:'offline-bot-${e.key}',name:e.key==0?displayName:'${e.value.label} Bot',avatar:e.key==0?avatar:'🤖')));
    status='${active.color.label} to roll';_startLocalClock();notifyListeners();
  }
  void joinQueue({required GameMode selectedMode,required int count,required int fee}) {
    if(!connected){mode=selectedMode;playerCount=count;entryFee=fee;online=true;matching=true;entryCharged=false;status='Connecting to game server…';_pendingConnectAction=()=>joinQueue(selectedMode:selectedMode,count:count,fee:fee);_socket?.connect();notifyListeners();return;}
    if(coins<fee){status='Not enough coins';notifyListeners();return;}
    mode=selectedMode;playerCount=count;entryFee=fee;online=true;matching=true;gameStarted=false;entryCharged=false;status='Finding players';notifyListeners();
    _socket!.emitWithAck('queue_join',{'mode':mode.name,'playerCount':count,'entryFee':fee,'name':displayName,'avatar':avatar},ack:(dynamic response){if(response is Map&&response['ok']==false){matching=false;status='${response['reason']??'Unable to join match'}';notifyListeners();}});
  }
  void cancelQueue(){_socket?.emit('queue_leave');matching=false;status='Search cancelled';notifyListeners();}
  void createPrivateRoom({required GameMode selectedMode,required int count,required int fee}) {
    if(!connected){if(coins<fee){status='Not enough coins';notifyListeners();return;}mode=selectedMode;playerCount=count;entryFee=fee;online=true;matching=true;entryCharged=false;status='Connecting to game server…';_pendingConnectAction=()=>createPrivateRoom(selectedMode:selectedMode,count:count,fee:fee);_socket?.connect();notifyListeners();return;}
    if(coins<fee){status='Not enough coins';notifyListeners();return;}mode=selectedMode;playerCount=count;entryFee=fee;online=true;matching=true;entryCharged=false;status='Creating private room';notifyListeners();
    _socket!.emitWithAck('private_create',{'mode':mode.name,'playerCount':count,'entryFee':fee,'name':displayName,'avatar':avatar},ack:(dynamic r){if(r is Map&&r['ok']==false){matching=false;status='${r['reason']??'Could not create room'}';notifyListeners();}});
  }
  void joinPrivateRoom(String code) { if(!connected){online=true;matching=true;status='Connecting to game server…';_pendingConnectAction=()=>joinPrivateRoom(code);_socket?.connect();notifyListeners();return;}online=true;matching=true;entryCharged=false;_socket!.emitWithAck('private_join',{'code':code.trim(),'name':displayName,'avatar':avatar},ack:(dynamic r){if(r is Map&&r['ok']==false){matching=false;status='${r['reason']??'Could not join room'}';notifyListeners();}});notifyListeners(); }
  void resumeAutoPlay(){_socket?.emit('im_back');autoPlay=false;status='Your turn';notifyListeners();}
  Future<void> joinMatchVoice() async {
    if(!connected||!online||voiceJoined||voiceStarting)return;
    voiceStarting=true;voiceError=null;notifyListeners();
    final service=WebRtcVoiceService(socket:_socket!,userId:userId,voiceRoomId:'match:$matchId',onPeerState:(peerId,isConnected){final player=players.where((p)=>p.userId==peerId).firstOrNull;if(player!=null){player.voiceConnected=isConnected;notifyListeners();}},onError:(message){voiceError=message;notifyListeners();});
    _voiceService=service;
    try {
      await service.start();
      service.setSpeakerMuted(speakerMuted);
      _socket!.emitWithAck('voice_join',null,ack:(dynamic response) async {
        if(response is Map&&response['ok']==true){
          voiceJoined=true;voiceStarting=false;
          final peers=(response['peers'] as List? ?? []).whereType<Map>().map((p)=>Map<String,dynamic>.from(p)).where((p)=>!('${p['userId']}').startsWith('bot:')).toList();
          voicePeers..clear()..addAll(peers);
          for(final peer in peers){final player=players.where((p)=>p.userId==peer['userId']).firstOrNull;if(player!=null){player.voiceConnected=true;player.micEnabled=peer['micEnabled']==true;}}
          notifyListeners();
          await service.connectToExistingPeers(peers.map((p)=>'${p['userId']}'));
        } else {
          voiceStarting=false;voiceError='${response is Map?response['reason']??'Unable to join voice room':'Unable to join voice room'}';
          await service.close();_voiceService=null;notifyListeners();
        }
      });
    } catch(error){voiceStarting=false;voiceError='$error';await service.close();_voiceService=null;notifyListeners();}
  }
  void _closeVoiceService(){final service=_voiceService;_voiceService=null;voiceJoined=false;voiceStarting=false;micEnabled=false;for(final p in players){p.voiceConnected=false;p.micEnabled=false;}service?.close();notifyListeners();}
  void leaveMatchVoice(){if(voiceJoined){if(micEnabled){_socket?.emit('mic_status_changed',{'enabled':false});} _socket?.emit('voice_leave');}_closeVoiceService();voicePeers.clear();}
  void setMicEnabled(bool enabled){micEnabled=enabled;_voiceService?.setMicrophoneMuted(!enabled);final self=players.where((p)=>p.userId==userId).firstOrNull;if(self!=null)self.micEnabled=enabled;_socket?.emit('mic_status_changed',{'enabled':enabled});notifyListeners();}
  void setSpeakerMuted(bool muted){speakerMuted=muted;_voiceService?.setSpeakerMuted(muted);notifyListeners();}
  void togglePeerMute(String peerId){final service=_voiceService;if(service==null)return;service.setPeerMuted(peerId,!service.mutedPeers.contains(peerId));notifyListeners();}
  bool isPeerMuted(String peerId)=>_voiceService?.isPeerMuted(peerId)??speakerMuted;
  void sendQuickChat(String phrase){if(!quickChatPhrases.contains(phrase)||!online)return;_socket?.emitWithAck('quick_chat',{'phrase':phrase},ack:(dynamic r){if(r is Map&&r['ok']==false){status='${r['reason']??'Chat could not be sent'}';notifyListeners();}});}
  void sendEmoji(String emoji){if(!quickEmojis.contains(emoji)||!online)return;_socket?.emitWithAck('emoji_reaction',{'emoji':emoji},ack:(dynamic r){if(r is Map&&r['ok']==false){status='${r['reason']??'Reaction could not be sent'}';notifyListeners();}});}
  Future<bool> sendGift(String targetUserId,String giftId) async {
    final gift=gifts.where((item)=>item.id==giftId).firstOrNull;
    if(gift==null||!online||targetUserId==userId||coins<gift.price)return false;
    coins-=gift.price;await prefs.setInt('coins',coins);notifyListeners();
    final completer=Completer<bool>();
    _socket?.emitWithAck('gift_send',{'toUserId':targetUserId,'giftId':gift.id},ack:(dynamic response){final ok=response is Map&&response['ok']==true;if(!ok){coins+=gift.price;prefs.setInt('coins',coins);status='${response is Map?response['reason']??'Gift could not be sent':'Gift could not be sent'}';notifyListeners();}completer.complete(ok);});
    return completer.future.timeout(const Duration(seconds:5),onTimeout:(){status='Gift delivery confirmation is delayed';notifyListeners();return true;});
  }
  void _onQuickChat(dynamic data){if(data is! Map)return;final id='${data['fromUserId']}';final player=players.where((p)=>p.userId==id).firstOrNull;if(player==null)return;player.lastEmoji=null;player.lastChat=data['phrase']?.toString();player.reactionSerial++;_clearReactionLater(id);notifyListeners();}
  void _onEmoji(dynamic data){if(data is! Map)return;final id='${data['fromUserId']}';final player=players.where((p)=>p.userId==id).firstOrNull;if(player==null)return;player.lastChat=null;player.lastEmoji=data['emoji']?.toString();player.reactionSerial++;_clearReactionLater(id);notifyListeners();}
  void _clearReactionLater(String id){_reactionTimers.remove(id)?.cancel();_reactionTimers[id]=Timer(const Duration(seconds:3),(){final player=players.where((p)=>p.userId==id).firstOrNull;player?.lastChat=null;player?.lastEmoji=null;_reactionTimers.remove(id);notifyListeners();});}
  void _onGiftThrown(dynamic data){if(data is! Map)return;final gift=gifts.where((g)=>g.id==data['giftId']).firstOrNull;if(gift==null)return;lastGift=GiftEvent(++giftSerial,'${data['fromUserId']}','${data['toUserId']}',gift);notifyListeners();}
  void consumeResumeNavigation(){resumePending=false;}

  void _onMatchFound(dynamic data) {
    if(data is! Map)return;
    matching=false;gameStarted=true;gameOver=false;online=true;matchId='${data['matchId']}';prefs.setString('activeMatchId',matchId!);mode=data['mode']=='quick'?GameMode.quick:GameMode.classic;playerCount=(data['playerCount'] as num?)?.toInt()??2;entryFee=(data['entryFee'] as num?)?.toInt()??entryFee;matchPrize=entryFee*playerCount;
    _applyPlayers(data['players']);dice=0;status='Match found';notifyListeners();
  }
  void _onSyncState(dynamic data) { if(data is! Map)return;_onMatchFound(data);_applySnapshot(data); }
  void _applySnapshot(Map data) {
    final list=data['players'];if(list is List){for(final item in list){if(item is! Map)continue;final p=players.where((p)=>p.userId=='${item['userId']}').firstOrNull;if(p==null)continue;p.captures=(item['captures'] as num?)?.toInt()??0;p.autoPlay=item['autoPlay']==true;p.connected=item['connected']==true;p.micEnabled=item['micEnabled']==true;final ts=item['tokens'];if(ts is List){for(final t in ts){if(t is Map){final i=(t['id'] as num?)?.toInt()??-1;if(i>=0&&i<4)p.tokens[i].progress=(t['progress'] as num?)?.toInt()??-1;}}}}}
    currentPlayer=(data['currentPlayer'] as num?)?.toInt()??0;dice=(data['dice'] as num?)?.toInt()??0;winnerId=data['winnerId']?.toString();gameOver=data['phase']=='finished';final ms=(data['turnDeadline'] as num?)?.toInt();_setDeadline(ms==null?null:DateTime.fromMillisecondsSinceEpoch(ms));if(gameOver&&winnerId!=null)_onGameOver({'winnerId':winnerId});notifyListeners();
  }
  void _applyPlayers(dynamic source) {
    if(source is! List)return;
    players..clear()..addAll(source.whereType<Map>().map((item){final color=PlayerColor.values.firstWhere((e)=>e.name==item['color'],orElse:()=>PlayerColor.red);final p=LudoPlayer(color,bot:item['isBot']==true,userId:'${item['userId']}',name:'${item['name']??color.label}',avatar:'${item['avatar']??'🙂'}')..autoPlay=item['autoPlay']==true..connected=item['connected']==true..captures=((item['captures'] as num?)?.toInt()??0)..micEnabled=item['micEnabled']==true;final ts=item['tokens'];if(ts is List)for(final t in ts){if(t is Map){final id=(t['id'] as num?)?.toInt()??-1;if(id>=0&&id<4)p.tokens[id].progress=(t['progress'] as num?)?.toInt()??-1;}}return p;}));
    currentPlayer=(source.isNotEmpty?0:0);_setDeadline(null);
  }
  void _onDiceRolled(dynamic data){if(data is! Map)return;dice=(data['value'] as num?)?.toInt()??0;rolling=false;status='${data['color']??'Player'} rolled $dice';notifyListeners();}
  void _onTokenMoved(dynamic data){if(data is! Map)return;final p=players.where((p)=>p.userId=='${data['userId']}').firstOrNull;final tokenId=(data['tokenId'] as num?)?.toInt()??-1;if(p!=null&&tokenId>=0&&tokenId<4){p.tokens[tokenId].progress=(data['progress'] as num?)?.toInt()??p.tokens[tokenId].progress;final captured=data['captured'];if(captured is List)for(final cap in captured){if(cap is Map){final victim=players.where((p)=>p.userId=='${cap['userId']}').firstOrNull;final id=(cap['tokenId'] as num?)?.toInt()??-1;if(victim!=null&&id>=0&&id<4)victim.tokens[id].progress=-1;}}p.captures+=captured is List?captured.length:0;totalCaptures+=captured is List?captured.length:0;}
    dice=0;status=data['captured'] is List&&(data['captured'] as List).isNotEmpty?'Token captured!':'Token moved';notifyListeners();
  }
  void _onTurnChanged(dynamic data){if(data is! Map)return;currentPlayer=(data['currentPlayer'] as num?)?.toInt()??0;final deadline=(data['deadline'] as num?)?.toInt();_setDeadline(deadline==null?null:DateTime.fromMillisecondsSinceEpoch(deadline));if(currentPlayer>=0&&currentPlayer<players.length)status=players[currentPlayer].userId==userId?'Your turn':'${players[currentPlayer].name} to play';notifyListeners();}
  void _onGameOver(dynamic data) async {if(data is! Map)return;gameOver=true;gameStarted=false;winnerId='${data['winnerId']}';didWin=winnerId==userId;_cancelClock();leaveMatchVoice();prefs.remove('activeMatchId');final matchHash=matchId?.hashCode??0;if(_lastAwardedMatch==matchHash)return;_lastAwardedMatch=matchHash;gamesPlayed++;xp+=didWin==true?100:25;level=1+xp~/500;if(online&&!entryCharged){coins=max(0,coins-entryFee).toInt();entryCharged=true;}if(didWin==true){wins++;coins+=matchPrize;}status=didWin==true?'Victory!':'Match complete';await _saveWallet();notifyListeners();}
  void _setDeadline(DateTime? deadline){_turnDeadline=deadline;_clock?.cancel();if(deadline==null){secondsLeft=15;return;}void update(){secondsLeft=max(0,deadline.difference(DateTime.now()).inSeconds).toInt();if(secondsLeft==0)_clock?.cancel();notifyListeners();}update();_clock=Timer.periodic(const Duration(milliseconds:250),(_)=>update());}
  void _startLocalClock(){_setDeadline(DateTime.now().add(const Duration(seconds:15)));}
  void _cancelClock(){_clock?.cancel();_clock=null;_turnDeadline=null;}
  List<Token> get legalTokens {if(dice==0||players.isEmpty)return [];return active.tokens.where((t){if(t.atBase)return dice==6;if(t.finished||t.progress+dice>57)return false;if(mode==GameMode.quick&&t.progress<=51&&t.progress+dice>51&&active.captures<1)return false;return true;}).toList();}
  Future<void> rollDice() async {
    if(!gameStarted||gameOver||rolling||dice!=0)return;
    if(online){if(active.userId!=userId||autoPlay)return;rolling=true;notifyListeners();_socket?.emitWithAck('roll_dice',null,ack:(dynamic response){if(response is Map&&response['ok']==false){rolling=false;status='${response['reason']??'Roll rejected'}';notifyListeners();}});return;}
    rolling=true;notifyListeners();final random=Random();for(var i=0;i<10;i++){dice=random.nextInt(6)+1;notifyListeners();await Future.delayed(const Duration(milliseconds:65));}dice=random.nextInt(6)+1;rolling=false;
    if(dice==6)consecutiveSixes++;else consecutiveSixes=0;status='${active.color.label} rolled $dice';
    if(consecutiveSixes>=3){dice=0;consecutiveSixes=0;status='Three sixes — turn forfeited';_advance();return;}if(legalTokens.isEmpty){final six=dice==6;dice=0;status='No legal moves';if(!six)_advance();}notifyListeners();
  }
  int consecutiveSixes=0;
  void move(Token token){if(online){if(active.userId==userId&&!autoPlay)_socket?.emitWithAck('move_token',{'tokenId':token.id},ack:(dynamic response){if(response is Map&&response['ok']==false){status='${response['reason']??'Move rejected'}';notifyListeners();}});return;}if(gameOver||!legalTokens.contains(token))return;final roll=dice;token.progress=token.atBase?0:token.progress+roll;var killed=false;if(token.progress<=51){final square=(token.color.start+token.progress)%52;if(!safeSquares.contains(square))for(final p in players.where((p)=>p!=active))for(final enemy in p.tokens.where((t)=>!t.atBase&&t.progress<=51)){if((p.color.start+enemy.progress)%52==square){enemy.progress=-1;active.captures++;totalCaptures++;killed=true;}}}dice=0;if(mode==GameMode.quick&&active.completed>=1||active.completed==4){_finishOffline(active);return;}if(roll==6||killed||token.finished){status=token.finished?'Home! Bonus roll':killed?'Token captured! Bonus roll':'Roll again';_startLocalClock();notifyListeners();_scheduleOfflineBot();}else _advance();}
  void _finishOffline(LudoPlayer winner){gameOver=true;gameStarted=false;winnerId=winner.userId;didWin=winner.userId==userId;gamesPlayed++;if(didWin==true)wins++;status='${winner.name} wins!';_cancelClock();_saveWallet();}
  void _advance(){if(!gameStarted||gameOver)return;currentPlayer=(currentPlayer+1)%players.length;dice=0;consecutiveSixes=0;status='${active.color.label} to roll';_startLocalClock();notifyListeners();_scheduleOfflineBot();}
  void _scheduleOfflineBot(){if(active.bot)Future.delayed(const Duration(milliseconds:650),()async{if(gameOver||!active.bot)return;if(dice==0)await rollDice();if(dice!=0&&legalTokens.isNotEmpty){final moves=legalTokens..sort((a,b)=>_offlineScore(b).compareTo(_offlineScore(a)));move(moves.first);}});}
  int _offlineScore(Token t){if(t.atBase)return dice==6?30:-100;final next=t.progress+dice;if(next==57)return 1000;var score=next;if(next<=51){final sq=(t.color.start+next)%52;if(players.where((p)=>p!=active).expand((p)=>p.tokens).any((e)=>!e.atBase&&e.progress<=51&&(e.color.start+e.progress)%52==sq&&!safeSquares.contains(sq)))score+=2000;if(safeSquares.contains(sq))score+=120;}return score;}
  void reset(){if(online&&matchId!=null&&!gameOver)_socket?.emit('leave_match');leaveMatchVoice();_cancelClock();for(final timer in _reactionTimers.values){timer.cancel();}_reactionTimers.clear();players.clear();gameStarted=false;gameOver=false;matching=false;online=false;matchId=null;prefs.remove('activeMatchId');dice=0;status='Ready to play';notifyListeners();}
  @override void dispose(){_cancelClock();for(final timer in _reactionTimers.values){timer.cancel();}_voiceService?.close();_voiceRoomService?.close();_socket?.dispose();super.dispose();}
}

class GiftItem { const GiftItem(this.id,this.name,this.emoji,this.price);final String id,name,emoji;final int price; }
class GiftEvent { const GiftEvent(this.serial,this.fromUserId,this.toUserId,this.gift);final int serial;final String fromUserId,toUserId;final GiftItem gift; }
class RoomGift { const RoomGift(this.id,this.name,this.emoji,this.diamonds);final String id,name,emoji;final int diamonds; }
class SpinReward { const SpinReward(this.type,this.amount);final String type;final int amount; }
