const { GameRoom, BOT_AVATARS, BOT_NAMES } = require('./GameRoom');
const { COLORS } = require('./rules');

const ENTRY_FEES = new Set([500, 2000, 10000, 50000]);

class Matchmaker {
  constructor(io, { fillAfterMs = 8000, onRoomCreated, onGameOver } = {}) {
    this.io = io; this.fillAfterMs = fillAfterMs; this.onRoomCreated = onRoomCreated; this.onGameOver = onGameOver;
    this.queues = new Map(); this.rooms = new Map(); this.userRooms = new Map();
    this.waitingByUser = new Map(); this.privateRooms = new Map();
  }

  validate(options) {
    const mode = options?.mode;
    const playerCount = Number(options?.playerCount);
    const entryFee = Number(options?.entryFee);
    if (!['classic','quick'].includes(mode)) return 'mode must be classic or quick';
    if (![2,4].includes(playerCount)) return 'playerCount must be 2 or 4';
    if (!ENTRY_FEES.has(entryFee)) return 'entryFee must be 500, 2000, 10000, or 50000';
    return { mode, playerCount, entryFee };
  }

  join(socket, userId, options) {
    const parsed = this.validate(options);
    if (typeof parsed === 'string') return { ok: false, reason: parsed };
    if (this.userRooms.has(userId)) return { ok: false, reason: 'Already in an active match' };
    this.leaveQueue(userId);
    const key = `${parsed.mode}:${parsed.playerCount}:${parsed.entryFee}`;
    const queue = this.queues.get(key) || { key, options: parsed, seats: [], timer: null };
    if (queue.seats.some(p => p.userId === userId)) return { ok: true, queued: true };
    queue.seats.push({ userId, socketId: socket.id, name: this.cleanName(options.name, 'Player'), avatar: this.cleanAvatar(options.avatar), color: null, isBot: false });
    socket.data.userId = userId;
    this.waitingByUser.set(userId, key);
    socket.emit('queue_joined', { queueKey: key, playersWaiting: queue.seats.length, playerCount: parsed.playerCount, fillAfterMs: this.fillAfterMs });
    this.queues.set(key, queue);
    if (queue.seats.length >= parsed.playerCount) this.createMatch(queue);
    else if (!queue.timer) queue.timer = setTimeout(() => this.createMatch(queue), this.fillAfterMs);
    return { ok: true, queued: true };
  }

  cleanName(name, fallback) { return typeof name === 'string' ? name.trim().slice(0,24) || fallback : fallback; }
  cleanAvatar(avatar) { return typeof avatar === 'string' ? avatar.slice(0,16) : '🙂'; }
  createPrivate(socket, userId, options) {
    const parsed = this.validate(options);
    if (typeof parsed === 'string') return { ok:false, reason:parsed };
    const code = String(Math.floor(100000 + Math.random() * 900000));
    const room = { code, options:parsed, seats:[{ userId, socketId:socket.id, name:this.cleanName(options.name,'Player'), avatar:this.cleanAvatar(options.avatar), color:null, isBot:false }], timer:setTimeout(() => { this.privateRooms.delete(code); socket.emit('private_room_expired',{code}); }, 10 * 60 * 1000) };
    room.timer.unref?.(); this.privateRooms.set(code,room); socket.data.userId=userId;
    socket.emit('private_room_created',{code,playerCount:parsed.playerCount});
    return {ok:true,code};
  }
  joinPrivate(socket,userId,code,profile={}) {
    if (typeof code!=='string' || !/^\d{6}$/.test(code)) return {ok:false,reason:'Enter a valid six-digit room code'};
    const room=this.privateRooms.get(code);
    if (!room) return {ok:false,reason:'Private room not found or expired'};
    if (room.seats.some(seat=>seat.userId===userId)) return {ok:false,reason:'You are already in this room'};
    if (room.seats.length>=room.options.playerCount) return {ok:false,reason:'Room is full'};
    room.seats.push({userId,socketId:socket.id,name:this.cleanName(profile.name,'Player'),avatar:this.cleanAvatar(profile.avatar),color:null,isBot:false});
    socket.data.userId=userId; socket.emit('private_room_joined',{code,playersWaiting:room.seats.length,playerCount:room.options.playerCount});
    if (room.seats.length>=room.options.playerCount) {
      clearTimeout(room.timer); this.privateRooms.delete(code);
      const queue={key:`private:${code}`,options:room.options,seats:room.seats,timer:null};
      const colors=COLORS[room.options.playerCount]; queue.seats.forEach((seat,index)=>seat.color=colors[index]);
      const match=new GameRoom(this.io,{...queue.options,seats:queue.seats,onFinish:id=>{this.onGameOver?.(match.game);this.finishRoom(id);}});
      this.rooms.set(match.game.id,match); for(const seat of queue.seats)this.userRooms.set(seat.userId,match.game.id);
      match.start();
    }
    return {ok:true,code};
  }
  botSeat(color, index) {
    const suffix = Math.floor(Math.random() * 90) + 10;
    return { userId: `bot:${Date.now()}:${index}`, socketId: null, name: `${BOT_NAMES[Math.floor(Math.random()*BOT_NAMES.length)]}${suffix}`, avatar: BOT_AVATARS[Math.floor(Math.random()*BOT_AVATARS.length)], color, isBot: true };
  }

  createMatch(queue) {
    if (!queue || this.queues.get(queue.key) !== queue) return null;
    clearTimeout(queue.timer); this.queues.delete(queue.key);
    for (const seat of queue.seats) this.waitingByUser.delete(seat.userId);
    const colors = COLORS[queue.options.playerCount];
    const seats = queue.seats.slice(0, queue.options.playerCount);
    while (seats.length < queue.options.playerCount) seats.push(this.botSeat(colors[seats.length], seats.length));
    seats.forEach((seat,index) => seat.color = colors[index]);
    const room = new GameRoom(this.io, { ...queue.options, seats, onFinish: id => { this.onGameOver?.(room.game); this.finishRoom(id); } });
    this.rooms.set(room.game.id, room);
    for (const seat of seats) if (!seat.isBot) this.userRooms.set(seat.userId, room.game.id);
    this.onRoomCreated?.(room);
    room.start();
    return room;
  }

  leaveQueue(userId) {
    const key = this.waitingByUser.get(userId);
    if (!key) return false;
    const queue = this.queues.get(key);
    if (queue) {
      queue.seats = queue.seats.filter(seat => seat.userId !== userId);
      if (!queue.seats.length) { clearTimeout(queue.timer); this.queues.delete(key); }
    }
    this.waitingByUser.delete(userId);
    return true;
  }

  rejoin(socket, userId) {
    const roomId = this.userRooms.get(userId);
    const room = roomId && this.rooms.get(roomId);
    return room ? room.rejoin(userId, socket) : false;
  }

  leaveMatch(userId) {
    const roomId=this.userRooms.get(userId);
    const room=roomId&&this.rooms.get(roomId);
    if(!room)return false;
    const left=room.leave(userId);
    if(left)this.userRooms.delete(userId);
    return left;
  }

  disconnect(userId, socketId) {
    const waitingKey = this.waitingByUser.get(userId);
    const waitingQueue = waitingKey && this.queues.get(waitingKey);
    if (waitingQueue?.seats.some(seat => seat.userId === userId && seat.socketId === socketId)) this.leaveQueue(userId);
    const roomId = this.userRooms.get(userId);
    const room = roomId && this.rooms.get(roomId);
    if (room) room.setConnected(userId, false, null, socketId);
  }

  roomFor(userId) { return this.rooms.get(this.userRooms.get(userId)); }
  finishRoom(roomId) {
    const room = this.rooms.get(roomId);
    if (!room) return;
    setTimeout(() => {
      room.dispose();
      for (const player of room.game.players) this.userRooms.delete(player.userId);
      this.rooms.delete(roomId);
    }, 30000).unref?.();
  }
}

module.exports = { Matchmaker };
