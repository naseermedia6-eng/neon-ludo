const http = require('node:http');
const express = require('express');
const { Server } = require('socket.io');
const { Matchmaker } = require('./game/Matchmaker');
const { VoiceRoomManager } = require('./game/VoiceRoomManager');

const PORT = Number(process.env.PORT) || 3000;
const ORIGIN = process.env.CLIENT_ORIGIN || '*';
const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '16kb' }));
app.get('/', (_req, res) => res.json({ service: 'neon-ludo-server', status: 'ok' }));
app.get('/health', (_req, res) => res.status(200).json({ status: 'ok', uptime: Math.floor(process.uptime()) }));

const server = http.createServer(app);
const io = new Server(server, {
  cors: { origin: ORIGIN === '*' ? '*' : ORIGIN.split(',').map(value => value.trim()), methods: ['GET','POST'] },
  transports: ['websocket','polling'],
  pingInterval: 25000,
  pingTimeout: 20000,
  maxHttpBufferSize: 1e6,
});
const voiceRooms = new VoiceRoomManager(io);
const matchmaker = new Matchmaker(io, { fillAfterMs: 8000, onGameOver: game => {
  const winner = game.players.find(player => player.userId === game.winnerId);
  if (winner && !winner.isBot) voiceRooms.recordWin(winner.userId, winner.name, winner.avatar, game.entryFee * game.playerCount);
} });
const QUICK_CHAT = new Set(['Hurry up!','Nice move!','Well played!','Don’t kill me!']);
const REACTIONS = new Set(['😂','😎','😮','😭','👏','🔥','❤️','😡','🎉','🙏']);
const GIFTS = new Map([
  ['rose',{name:'Rose',emoji:'🌹',cost:100}],
  ['coffee',{name:'Coffee',emoji:'☕',cost:250}],
  ['slipper',{name:'Slipper',emoji:'🩴',cost:500}],
  ['bomb',{name:'Bomb',emoji:'💣',cost:1000}],
  ['car',{name:'Sports Car',emoji:'🏎️',cost:5000}],
]);

function validUserId(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_.:@-]{1,80}$/.test(value);
}

io.use((socket, next) => {
  const userId = socket.handshake.auth?.userId;
  if (!validUserId(userId)) return next(new Error('A valid userId is required in Socket.IO auth'));
  socket.data.userId = userId;
  next();
});

function reply(ack, result) { if (typeof ack === 'function') ack(result); }
function requireRoom(socket) {
  const room = matchmaker.roomFor(socket.data.userId);
  return room?.playerFor(socket.data.userId) ? room : null;
}

io.on('connection', socket => {
  const userId = socket.data.userId;
  const cooldowns = new Map();
  socket.emit('voice_rooms_list', voiceRooms.publicList());
  socket.on('get_voice_rooms', ack => reply(ack, { ok:true, rooms:voiceRooms.publicList() }));
  const rateLimit = (event, minimumMs = 150) => {
    const now = Date.now();
    if (now - (cooldowns.get(event) || 0) < minimumMs) return false;
    cooldowns.set(event, now); return true;
  };

  socket.on('queue_join', (data = {}, ack) => {
    if (!rateLimit('queue_join', 500)) return reply(ack, { ok:false, reason:'Please slow down' });
    reply(ack, matchmaker.join(socket, userId, data));
  });
  socket.on('queue_leave', ack => {
    const left = matchmaker.leaveQueue(userId);
    reply(ack, { ok: left });
    if (left) socket.emit('queue_left', {});
  });
  socket.on('private_create', (data = {}, ack) => reply(ack, matchmaker.createPrivate(socket,userId,data)));
  socket.on('private_join', (data = {}, ack) => reply(ack, matchmaker.joinPrivate(socket,userId,data.code,data)));
  socket.on('rejoin_match', ack => {
    const joined = matchmaker.rejoin(socket, userId);
    reply(ack, { ok: joined, reason: joined ? undefined : 'No active match found' });
  });
  socket.on('roll_dice', ack => {
    if (!rateLimit('roll_dice')) return reply(ack, { ok:false, reason:'Please slow down' });
    const room = requireRoom(socket);
    const result = room ? room.roll(userId) : { ok:false, reason:'You are not in an active match' };
    reply(ack, result);
  });
  socket.on('move_token', (data = {}, ack) => {
    if (!rateLimit('move_token')) return reply(ack, { ok:false, reason:'Please slow down' });
    const room = requireRoom(socket);
    const result = room ? room.move(userId, data.tokenId) : { ok:false, reason:'You are not in an active match' };
    reply(ack, result);
  });
  socket.on('im_back', ack => {
    const room = requireRoom(socket);
    const ok = room ? room.playerBack(userId) : false;
    reply(ack, { ok, reason: ok ? undefined : 'No active match found' });
  });
  socket.on('leave_match', ack => reply(ack,{ok:matchmaker.leaveMatch(userId)}));

  socket.on('voice_join', ack => {
    const room = requireRoom(socket);
    if (!room) return reply(ack, { ok:false, reason:'Join a match before starting voice chat' });
    socket.join(`voice:${room.game.id}`);
    socket.to(`voice:${room.game.id}`).emit('voice_peer_joined', { userId });
    reply(ack, { ok:true, roomId:room.game.id, peers:room.game.players.filter(p => p.userId !== userId && p.connected && !p.isBot).map(p => ({ userId:p.userId, name:p.name, micEnabled:p.micEnabled })) });
  });
  socket.on('create_voice_room', (data = {}, ack) => {
    if (!rateLimit('create_voice_room', 1000)) return reply(ack, { ok: false, reason: 'Please slow down' });
    const result = voiceRooms.create(socket, data);
    reply(ack, result);
  });
  socket.on('join_voice_room', (data = {}, ack) => {
    if (!rateLimit('join_voice_room', 500)) return reply(ack, { ok: false, reason: 'Please slow down' });
    reply(ack, voiceRooms.join(socket, data.roomId, data.password, data));
  });
  socket.on('leave_voice_room', ack => reply(ack, voiceRooms.leave(socket, userId)));
  socket.on('take_mic_seat', (data = {}, ack) => reply(ack, voiceRooms.takeSeat(socket, userId, Number(data.seatIndex))));
  socket.on('release_mic_seat', ack => reply(ack, voiceRooms.releaseSeat(socket, userId)));
  socket.on('room_mic_status', (data = {}, ack) => reply(ack, voiceRooms.micStatus(socket, userId, data.enabled)));
  socket.on('lock_mic_seat', (data = {}, ack) => reply(ack, voiceRooms.lockSeat(socket, userId, Number(data.seatIndex), data.locked)));
  socket.on('kick_mic_seat', (data = {}, ack) => reply(ack, voiceRooms.kickSeat(socket, userId, data.targetUserId)));
  socket.on('send_room_chat', (data = {}, ack) => {
    if (!rateLimit('send_room_chat', 500)) return reply(ack, { ok: false, reason: 'Please slow down' });
    reply(ack, voiceRooms.chat(socket, userId, data.text));
  });
  socket.on('send_luxury_gift', (data = {}, ack) => {
    if (!rateLimit('send_luxury_gift', 750)) return reply(ack, { ok: false, reason: 'Please slow down' });
    reply(ack, voiceRooms.sendGift(socket, userId, data.targetUserId, data.giftId));
  });
  socket.on('get_leaderboard', ack => reply(ack, { ok: true, ...voiceRooms.leaderboards() }));
  socket.on('daily_spin', ack => reply(ack, voiceRooms.spin(userId)));
  socket.on('daily_checkin', ack => reply(ack, voiceRooms.checkin(userId)));
  socket.on('voice_leave', ack => {
    const room = requireRoom(socket);
    if (room) {
      const player=room.playerFor(userId);if(player?.micEnabled){player.micEnabled=false;socket.to(`voice:${room.game.id}`).emit('mic_status_changed',{userId,enabled:false});}
      socket.leave(`voice:${room.game.id}`); socket.to(`voice:${room.game.id}`).emit('voice_peer_left', { userId });
    }
    reply(ack, { ok:Boolean(room) });
  });

  const relaySignal = event => socket.on(event, (data = {}, ack) => {
    if (data.voiceRoomId && !data.voiceRoomId.startsWith('match:')) return reply(ack, voiceRooms.signal(socket, userId, event, data));
    const room = requireRoom(socket);
    if (!room || !socket.rooms.has(`voice:${room.game.id}`)) return reply(ack, { ok:false, reason:'Join the match voice room first' });
    if (data.voiceRoomId && data.voiceRoomId !== `match:${room.game.id}`) return reply(ack, { ok:false, reason:'Signaling room does not match the active table' });
    const peer = room.playerFor(data.toUserId);
    if (!peer || peer.userId === userId || !peer.connected) return reply(ack, { ok:false, reason:'Voice peer is unavailable' });
    const target = io.sockets.sockets.get(peer.socketId);
    if (!target || !target.rooms.has(`voice:${room.game.id}`)) return reply(ack, { ok:false, reason:'Voice peer is not in the voice room' });
    const field = event === 'webrtc_ice_candidate' ? 'candidate' : 'description';
    if (!data[field] || typeof data[field] !== 'object') return reply(ack, { ok:false, reason:`${field} payload is required` });
    target.emit(event, { fromUserId:userId, ...(data.voiceRoomId ? { voiceRoomId:data.voiceRoomId } : {}), [field]:data[field] });
    reply(ack, { ok:true });
  });
  relaySignal('webrtc_offer');
  relaySignal('webrtc_answer');
  relaySignal('webrtc_ice_candidate');
  socket.on('mic_status_changed', (data = {}, ack) => {
    const room = requireRoom(socket);
    if (!room || !socket.rooms.has(`voice:${room.game.id}`)) return reply(ack, { ok:false, reason:'Join the match voice room first' });
    if (typeof data.enabled !== 'boolean') return reply(ack, { ok:false, reason:'enabled must be boolean' });
    const player=room.playerFor(userId);if(player)player.micEnabled=data.enabled;
    socket.to(`voice:${room.game.id}`).emit('mic_status_changed', { userId, enabled:data.enabled });
    reply(ack, { ok:true });
  });
  socket.on('quick_chat',(data={},ack)=>{
    if(!rateLimit('quick_chat',700))return reply(ack,{ok:false,reason:'Please slow down'});
    const room=requireRoom(socket);const phrase=data.phrase;
    if(!room||!socket.rooms.has(`match:${room.game.id}`))return reply(ack,{ok:false,reason:'Join a match first'});
    if(!QUICK_CHAT.has(phrase))return reply(ack,{ok:false,reason:'That quick chat phrase is not available'});
    room.broadcast('quick_chat_received',{fromUserId:userId,phrase});reply(ack,{ok:true});
  });
  socket.on('emoji_reaction',(data={},ack)=>{
    if(!rateLimit('emoji_reaction',300))return reply(ack,{ok:false,reason:'Please slow down'});
    const room=requireRoom(socket);const emoji=data.emoji;
    if(!room||!socket.rooms.has(`match:${room.game.id}`))return reply(ack,{ok:false,reason:'Join a match first'});
    if(!REACTIONS.has(emoji))return reply(ack,{ok:false,reason:'That reaction is not available'});
    room.broadcast('emoji_received',{fromUserId:userId,emoji});reply(ack,{ok:true});
  });
  socket.on('gift_send',(data={},ack)=>{
    if(!rateLimit('gift_send',500))return reply(ack,{ok:false,reason:'Please slow down'});
    const room=requireRoom(socket);const toUserId=data.toUserId;const gift=GIFTS.get(data.giftId);
    if(!room||!socket.rooms.has(`match:${room.game.id}`))return reply(ack,{ok:false,reason:'Join a match first'});
    if(typeof toUserId!=='string'||toUserId===userId||!room.playerFor(toUserId))return reply(ack,{ok:false,reason:'Gift recipient is not at your table'});
    if(!gift)return reply(ack,{ok:false,reason:'Gift is not available'});
    room.broadcast('gift_thrown',{fromUserId:userId,toUserId,giftId:data.giftId,giftName:gift.name,emoji:gift.emoji,cost:gift.cost});
    reply(ack,{ok:true,gift:{id:data.giftId,...gift}});
  });

  socket.on('disconnect', () => { matchmaker.disconnect(userId, socket.id); voiceRooms.disconnect(userId, socket.id); });
});

app.use((err, _req, res, _next) => {
  console.error('HTTP request error:', err.message);
  res.status(400).json({ error:'Invalid request' });
});

server.listen(PORT, '0.0.0.0', () => console.log(`Neon Ludo server listening on ${PORT}`));

function shutdown(signal) {
  console.log(`${signal} received; shutting down`);
  for (const room of matchmaker.rooms.values()) room.dispose();
  io.close(() => server.close(() => process.exit(0)));
  setTimeout(() => process.exit(1), 10000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
