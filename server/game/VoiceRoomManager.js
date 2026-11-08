const crypto = require('node:crypto');

const ROOM_CATEGORIES = new Set(['Chat', 'Gaming', 'Music', 'Chill']);
const LUXURY_GIFTS = new Map([
  ['ring', { name: 'Diamond Ring', emoji: '💍', diamonds: 500 }],
  ['sports_car', { name: 'Sports Car', emoji: '🏎️', diamonds: 2000 }],
  ['yacht', { name: 'Luxury Yacht', emoji: '🛥️', diamonds: 5000 }],
  ['dragon', { name: 'Flying Dragon', emoji: '🐉', diamonds: 10000 }],
  ['castle', { name: 'Palace Castle', emoji: '🏰', diamonds: 10000 }],
]);

class VoiceRoomManager {
  constructor(io) {
    this.io = io;
    this.rooms = new Map();
    this.userRooms = new Map();
    this.profiles = new Map();
    this.topPlayers = new Map();
    this.topGifters = new Map();
    this.spinClaims = new Map();
    this.checkinClaims = new Map();
  }

  profile(userId, input = {}) {
    const current = this.profiles.get(userId) || { userId, name: 'Player', avatar: '🙂' };
    if (typeof input.name === 'string' && input.name.trim()) current.name = input.name.trim().slice(0, 24);
    if (typeof input.avatar === 'string' && input.avatar) current.avatar = input.avatar.slice(0, 16);
    this.profiles.set(userId, current);
    return current;
  }

  publicList() {
    return [...this.rooms.values()].filter(room => !room.password).map(room => this.summary(room));
  }

  summary(room) {
    const host = this.profile(room.hostId);
    const speakerCount = room.seats.filter(Boolean).length;
    return { roomId: room.id, title: room.title, category: room.category, hostId: room.hostId, hostName: host.name, hostAvatar: host.avatar, listenerCount: room.members.size - speakerCount, speakerCount, hasPassword: Boolean(room.password), charm: room.charm };
  }

  broadcastList() { this.io.emit('voice_rooms_list', this.publicList()); }

  roomSnapshot(room) {
    return { ...this.summary(room), seats: room.seats.map(userId => userId ? { ...this.profile(userId), micEnabled: room.micEnabled?.get(userId) === true } : null), lockedSeats: [...room.lockedSeats], chat: room.chat.slice(-40), members: [...room.members].map(id => ({ ...this.profile(id), speaking: room.seats.includes(id), micEnabled: room.micEnabled?.get(id) === true })) };
  }

  emitState(room) { this.io.to(`voice-room:${room.id}`).emit('voice_room_state', this.roomSnapshot(room)); }

  create(socket, data = {}) {
    const userId = socket.data.userId;
    if (this.userRooms.has(userId)) return { ok: false, reason: 'Leave your current voice room first' };
    const title = typeof data.title === 'string' ? data.title.trim().slice(0, 48) : '';
    const category = ROOM_CATEGORIES.has(data.category) ? data.category : 'Chat';
    if (title.length < 3) return { ok: false, reason: 'Room title must have at least three characters' };
    if (data.isPrivate && (typeof data.password !== 'string' || data.password.length < 4 || data.password.length > 24)) return { ok: false, reason: 'Private room password must be 4 to 24 characters' };
    const room = { id: crypto.randomUUID(), title, category, password: data.isPrivate ? data.password : null, hostId: userId, members: new Set([userId]), seats: Array(9).fill(null), lockedSeats: Array(9).fill(false), micEnabled: new Map(), charm: 0, chat: [], sockets: new Map() };
    room.seats[0] = userId;
    room.sockets.set(userId, socket.id);
    this.rooms.set(room.id, room);
    this.userRooms.set(userId, room.id);
    this.profile(userId, data);
    socket.join(`voice-room:${room.id}`);
    this.broadcastList();
    this.emitState(room);
    return { ok: true, room: this.roomSnapshot(room) };
  }

  join(socket, roomId, password, profile = {}) {
    const userId = socket.data.userId;
    const room = this.rooms.get(roomId);
    if (!room) return { ok: false, reason: 'Voice room not found' };
    if (room.password && room.password !== password) return { ok: false, reason: 'Room password is incorrect' };
    const existingRoom = this.userRooms.get(userId);
    if (existingRoom && existingRoom !== roomId) return { ok: false, reason: 'Leave your current voice room first' };
    room.members.add(userId);
    room.sockets.set(userId, socket.id);
    this.userRooms.set(userId, roomId);
    this.profile(userId, profile);
    socket.join(`voice-room:${room.id}`);
    this.addChat(room, { kind: 'system', text: `${this.profile(userId).name} joined the room`, userId, timestamp: Date.now() });
    this.broadcastList();
    this.emitState(room);
    return { ok: true, room: this.roomSnapshot(room), peers: [...room.members].filter(id => id !== userId).map(id => ({ ...this.profile(id), speaking: room.seats.includes(id) })) };
  }

  addChat(room, message) {
    room.chat.push(message);
    room.chat = room.chat.slice(-100);
    this.io.to(`voice-room:${room.id}`).emit('voice_room_chat', message);
  }

  leave(socket, userId) {
    const roomId = this.userRooms.get(userId);
    const room = roomId && this.rooms.get(roomId);
    if (!room) return { ok: false };
    room.members.delete(userId);
    room.sockets.delete(userId);
    this.userRooms.delete(userId);
    const seat = room.seats.indexOf(userId);
    if (seat >= 0) room.seats[seat] = null;
    room.micEnabled.delete(userId);
    socket.leave(`voice-room:${room.id}`);
    socket.to(`voice-room:${room.id}`).emit('voice_room_peer_left', { userId, voiceRoomId: room.id });
    this.addChat(room, { kind: 'system', text: `${this.profile(userId).name} left the room`, userId, timestamp: Date.now() });
    if (userId === room.hostId && room.members.size) {
      room.hostId = room.members.values().next().value;
      room.seats[0] = room.hostId;
      const formerGuestSeat = room.seats.indexOf(room.hostId, 1);
      if (formerGuestSeat >= 1) room.seats[formerGuestSeat] = null;
      this.addChat(room, { kind: 'system', text: `${this.profile(room.hostId).name} is now the host`, userId: room.hostId, timestamp: Date.now() });
    }
    if (!room.members.size) this.rooms.delete(room.id);
    else this.emitState(room);
    this.broadcastList();
    return { ok: true };
  }

  takeSeat(socket, userId, seatIndex) {
    const room = this.roomFor(socket, userId);
    if (!room) return { ok: false, reason: 'Join a voice room first' };
    if (!Number.isInteger(seatIndex) || seatIndex < 1 || seatIndex > 8) return { ok: false, reason: 'Choose a guest seat from 1 to 8' };
    if (room.lockedSeats[seatIndex]) return { ok: false, reason: 'That microphone seat is locked' };
    if (room.seats.includes(userId)) return { ok: false, reason: 'You already have a microphone seat' };
    if (room.seats[seatIndex]) return { ok: false, reason: 'That microphone seat is occupied' };
    room.seats[seatIndex] = userId;
    room.micEnabled.set(userId, false);
    this.io.to(`voice-room:${room.id}`).emit('voice_room_peer_joined', { userId, voiceRoomId: room.id });
    this.addChat(room, { kind: 'system', text: `${this.profile(userId).name} took seat ${seatIndex}`, userId, timestamp: Date.now() });
    this.emitState(room);
    this.broadcastList();
    return { ok: true, room: this.roomSnapshot(room) };
  }

  releaseSeat(socket, userId) {
    const room = this.roomFor(socket, userId);
    if (!room) return { ok: false, reason: 'Join a voice room first' };
    const index = room.seats.indexOf(userId);
    if (index < 1) return { ok: false, reason: 'You do not hold a guest microphone seat' };
    room.seats[index] = null;
    room.micEnabled.delete(userId);
    this.io.to(`voice-room:${room.id}`).emit('voice_room_peer_left', { userId, voiceRoomId: room.id });
    this.addChat(room, { kind: 'system', text: `${this.profile(userId).name} left the microphone seat`, userId, timestamp: Date.now() });
    this.emitState(room);
    this.broadcastList();
    return { ok: true };
  }

  lockSeat(socket, userId, seatIndex, locked) {
    const room = this.roomFor(socket, userId);
    if (!room || room.hostId !== userId) return { ok: false, reason: 'Only the host can manage microphone seats' };
    if (!Number.isInteger(seatIndex) || seatIndex < 1 || seatIndex > 8 || typeof locked !== 'boolean') return { ok: false, reason: 'Invalid seat lock request' };
    if (room.seats[seatIndex] && locked) return { ok: false, reason: 'Release the microphone before locking the seat' };
    room.lockedSeats[seatIndex] = locked;
    this.emitState(room);
    return { ok: true };
  }

  kickSeat(socket, userId, targetUserId) {
    const room = this.roomFor(socket, userId);
    if (!room || room.hostId !== userId) return { ok: false, reason: 'Only the host can remove a speaker' };
    const seat = room.seats.indexOf(targetUserId);
    if (seat < 1) return { ok: false, reason: 'That player is not a guest speaker' };
    room.seats[seat] = null;
    room.micEnabled.delete(targetUserId);
    this.io.to(`voice-room:${room.id}`).emit('voice_room_peer_left', { userId: targetUserId, voiceRoomId: room.id });
    this.addChat(room, { kind: 'system', text: `${this.profile(targetUserId).name} returned to the audience`, userId, timestamp: Date.now() });
    this.emitState(room);
    this.broadcastList();
    return { ok: true };
  }

  roomFor(socket, userId) {
    const roomId = this.userRooms.get(userId);
    const room = roomId && this.rooms.get(roomId);
    return room && socket.rooms.has(`voice-room:${room.id}`) ? room : null;
  }

  chat(socket, userId, text) {
    const room = this.roomFor(socket, userId);
    if (!room) return { ok: false, reason: 'Join a voice room first' };
    if (typeof text !== 'string' || !text.trim() || text.length > 240) return { ok: false, reason: 'Chat messages must be 1 to 240 characters' };
    const profile = this.profile(userId);
    this.addChat(room, { kind: 'message', userId, name: profile.name, avatar: profile.avatar, text: text.trim(), timestamp: Date.now() });
    return { ok: true };
  }

  micStatus(socket, userId, enabled) {
    const room = this.roomFor(socket, userId);
    if (!room || !room.seats.includes(userId)) return { ok: false, reason: 'Take a microphone seat first' };
    if (typeof enabled !== 'boolean') return { ok: false, reason: 'Mic status must be boolean' };
    room.micEnabled.set(userId, enabled);
    this.emitState(room);
    return { ok: true };
  }

  sendGift(socket, userId, targetUserId, giftId) {
    const room = this.roomFor(socket, userId);
    const gift = LUXURY_GIFTS.get(giftId);
    if (!room) return { ok: false, reason: 'Join a voice room first' };
    if (!gift) return { ok: false, reason: 'That luxury gift is unavailable' };
    if (!room.members.has(targetUserId) || !room.seats.includes(targetUserId)) return { ok: false, reason: 'Choose a seated host or speaker' };
    if (targetUserId === userId) return { ok: false, reason: 'Choose another room member' };
    room.charm += gift.diamonds;
    const sender = this.profile(userId);
    const receiver = this.profile(targetUserId);
    this.topGifters.set(userId, (this.topGifters.get(userId) || 0) + gift.diamonds);
    const event = { voiceRoomId: room.id, senderId: userId, senderName: sender.name, senderAvatar: sender.avatar, receiverId: targetUserId, receiverName: receiver.name, giftId, giftName: gift.name, emoji: gift.emoji, diamonds: gift.diamonds, charm: room.charm, timestamp: Date.now() };
    this.io.to(`voice-room:${room.id}`).emit('room_luxury_gift', event);
    this.addChat(room, { kind: 'gift', userId, name: sender.name, text: `${sender.name} gifted ${gift.name} to ${receiver.name}!`, timestamp: event.timestamp });
    this.emitState(room);
    this.broadcastList();
    return { ok: true, gift: event };
  }

  signal(socket, userId, event, data = {}) {
    const room = this.roomFor(socket, userId);
    if (!room || data.voiceRoomId !== room.id) return { ok: false, reason: 'Join the signaling voice room first' };
    const targetId = data.toUserId;
    if (!room.members.has(targetId) || targetId === userId) return { ok: false, reason: 'Voice peer is unavailable' };
    if (!room.seats.includes(userId) && !room.seats.includes(targetId)) return { ok: false, reason: 'Voice links require at least one seated speaker' };
    const targetSocket = this.io.sockets.sockets.get(room.sockets.get(targetId));
    if (!targetSocket || !targetSocket.rooms.has(`voice-room:${room.id}`)) return { ok: false, reason: 'Voice peer is unavailable' };
    const field = event === 'webrtc_ice_candidate' ? 'candidate' : 'description';
    if (!data[field] || typeof data[field] !== 'object') return { ok: false, reason: `${field} payload is required` };
    targetSocket.emit(event, { fromUserId: userId, voiceRoomId: room.id, [field]: data[field] });
    return { ok: true };
  }

  disconnect(userId, socketId) {
    const roomId = this.userRooms.get(userId);
    const room = roomId && this.rooms.get(roomId);
    if (room?.sockets.get(userId) === socketId) {
      const fakeSocket = { data: { userId }, rooms: new Set([`voice-room:${room.id}`]), leave: () => {}, to: channel => this.io.to(channel) };
      this.leave(fakeSocket, userId);
    }
  }

  leaderboards() {
    const sort = map => [...map.entries()].map(([userId, score]) => ({ ...this.profile(userId), score })).sort((a, b) => b.score - a.score).slice(0, 50);
    return { topPlayers: sort(this.topPlayers), topGifters: sort(this.topGifters) };
  }

  recordWin(userId, name, avatar, coins) {
    this.profile(userId, { name, avatar });
    this.topPlayers.set(userId, (this.topPlayers.get(userId) || 0) + coins);
  }

  spin(userId) {
    const now = Date.now();
    const claimed = this.spinClaims.get(userId) || 0;
    if (now - claimed < 24 * 60 * 60 * 1000) return { ok: false, reason: 'The daily spin is still cooling down', nextSpinAt: claimed + 24 * 60 * 60 * 1000 };
    const rewards = [{ type: 'coins', amount: 200 }, { type: 'coins', amount: 500 }, { type: 'coins', amount: 1000 }, { type: 'coins', amount: 5000 }, { type: 'diamonds', amount: 5 }, { type: 'diamonds', amount: 20 }, { type: 'diamonds', amount: 50 }, { type: 'coins', amount: 20000 }];
    const weights = [24, 22, 18, 10, 10, 7, 5, 4];
    let roll = Math.random() * weights.reduce((sum, weight) => sum + weight, 0);
    let index = weights.findIndex(weight => (roll -= weight) < 0);
    if (index < 0) index = rewards.length - 1;
    this.spinClaims.set(userId, now);
    return { ok: true, index, reward: rewards[index], nextSpinAt: now + 24 * 60 * 60 * 1000 };
  }

  checkin(userId) {
    const now = Date.now();
    const previous = this.checkinClaims.get(userId) || { at: 0, streak: 0 };
    const elapsed = now - previous.at;
    if (elapsed < 24 * 60 * 60 * 1000) return { ok: false, reason: 'Daily check-in already claimed', nextClaimAt: previous.at + 24 * 60 * 60 * 1000, streak: previous.streak };
    const streak = elapsed <= 48 * 60 * 60 * 1000 ? previous.streak % 7 + 1 : 1;
    const rewards = [200, 300, 500, 800, 1200, 2000, 5000];
    this.checkinClaims.set(userId, { at: now, streak });
    return { ok: true, streak, reward: { type: 'coins', amount: rewards[streak - 1] }, nextClaimAt: now + 24 * 60 * 60 * 1000 };
  }
}

module.exports = { VoiceRoomManager, LUXURY_GIFTS, ROOM_CATEGORIES };
