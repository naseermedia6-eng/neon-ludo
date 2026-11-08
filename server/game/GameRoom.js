const crypto = require('node:crypto');
const { applyMove, chooseBotMove, createPlayers, legalMoves, snapshot } = require('./rules');

const BOT_NAMES = ['Mira','Rafi','Ayla','Zayn','Luna','Kai','Nora','Arman','Ivy','Samir','Noor','Leo','Zara','Omar','Milo','Ari'];
const BOT_AVATARS = ['🦊','🐼','🐯','🐸','🦄','🐨','🐙','🐻','🦁','🐵','🐧','🐰'];

class GameRoom {
  constructor(io, { mode, playerCount, entryFee, seats, turnSeconds = 15, onFinish }) {
    this.io = io;
    this.game = { id: crypto.randomUUID(), mode, playerCount, entryFee, players: createPlayers(seats), currentPlayer: 0, dice: null, consecutiveSixes: 0, phase: 'playing', winnerId: null, turnDeadline: null };
    this.turnSeconds = turnSeconds;
    this.onFinish = onFinish;
    this.turnTimer = null;
    this.botTimer = null;
    this.disconnectedTimers = new Map();
    this.disposed = false;
    this.roomId = `match:${this.game.id}`;
  }

  start() {
    for (const player of this.game.players) if (!player.isBot && player.socketId) this.io.sockets.sockets.get(player.socketId)?.join(this.roomId);
    this.broadcast('match_found', snapshot(this.game));
    this.beginTurn();
    return this.game.id;
  }

  get player() { return this.game.players[this.game.currentPlayer]; }
  playerFor(userId) { return this.game.players.find(p => p.userId === userId); }
  broadcast(event, payload) { if (!this.disposed) this.io.to(this.roomId).emit(event, payload); }

  beginTurn() {
    if (this.disposed || this.game.phase !== 'playing') return;
    clearTimeout(this.turnTimer); clearTimeout(this.botTimer);
    this.game.dice = null;
    this.game.turnDeadline = Date.now() + this.turnSeconds * 1000;
    this.broadcast('turn_changed', { currentPlayer: this.game.currentPlayer, userId: this.player.userId, color: this.player.color, deadline: this.game.turnDeadline });
    if (this.player.isBot || this.player.autoPlay) this.scheduleBot(900);
    else this.turnTimer = setTimeout(() => this.onTimeout(), this.turnSeconds * 1000);
  }

  roll(userId) {
    if (!this.isCurrent(userId) || this.game.dice !== null) return { ok: false, reason: 'Not your turn or dice already rolled' };
    const player = this.player;
    const value = Math.floor(Math.random() * 6) + 1;
    this.game.dice = value;
    this.game.consecutiveSixes = value === 6 ? this.game.consecutiveSixes + 1 : 0;
    this.broadcast('dice_rolled', { userId: player.userId, color: player.color, value });
    if (this.game.consecutiveSixes >= 3) {
      this.game.consecutiveSixes = 0;
      this.game.dice = null;
      this.broadcast('turn_forfeited', { userId, reason: 'three_consecutive_sixes' });
      this.game.currentPlayer = (this.game.currentPlayer + 1) % this.game.players.length;
      this.beginTurn();
      return { ok: true, value, forfeited: true };
    }
    if (legalMoves(this.game, player).length === 0) {
      const extra = value === 6;
      this.game.dice = null;
      if (extra) this.beginTurn();
      else { this.game.currentPlayer = (this.game.currentPlayer + 1) % this.game.players.length; this.beginTurn(); }
    } else {
      if (player.isBot || player.autoPlay) this.scheduleBot(700);
    }
    return { ok: true, value };
  }

  move(userId, tokenId, automatic = false) {
    if (!this.isCurrent(userId) || this.game.dice === null) return { ok: false, reason: 'Not your turn or roll the dice first' };
    const player = this.player;
    const result = applyMove(this.game, player, tokenId);
    if (!result.ok) return result;
    if (!automatic && !player.isBot && !player.autoPlay) player.afkCount = 0;
    this.broadcast('token_moved', { userId, color: player.color, ...result });
    if (result.won) {
      this.game.phase = 'finished'; this.game.winnerId = userId; this.game.turnDeadline = null;
      clearTimeout(this.turnTimer); clearTimeout(this.botTimer);
      this.broadcast('game_over', { matchId: this.game.id, winnerId: userId, winnerName: player.name, mode: this.game.mode });
      this.onFinish?.(this.game.id);
      return { ok: true, ...result };
    }
    if (result.extraTurn) this.beginTurn();
    else { this.game.consecutiveSixes = 0; this.game.currentPlayer = (this.game.currentPlayer + 1) % this.game.players.length; this.beginTurn(); }
    return { ok: true, ...result };
  }

  isCurrent(userId) { return this.game.phase === 'playing' && this.player.userId === userId; }

  onTimeout() {
    if (this.disposed || this.game.phase !== 'playing') return;
    const player = this.player;
    player.afkCount += 1;
    if (player.afkCount >= 3 && !player.isBot) {
      player.autoPlay = true;
      this.broadcast('autoplay_enabled', { userId: player.userId, afkCount: player.afkCount });
    }
    this.broadcast('player_timeout', { userId: player.userId, afkCount: player.afkCount, autoPlay: player.autoPlay });
    if (this.game.dice === null) {
      const value = Math.floor(Math.random() * 6) + 1;
      this.game.dice = value;
      this.game.consecutiveSixes = value === 6 ? this.game.consecutiveSixes + 1 : 0;
      this.broadcast('dice_rolled', { userId: player.userId, color: player.color, value, automatic: true });
    }
    if (this.game.consecutiveSixes >= 3) {
      this.game.consecutiveSixes = 0; this.game.dice = null;
      this.broadcast('turn_forfeited', { userId: player.userId, reason: 'three_consecutive_sixes' });
      this.game.currentPlayer = (this.game.currentPlayer + 1) % this.game.players.length; this.beginTurn(); return;
    }
    const tokenId = chooseBotMove(this.game, player);
    if (tokenId === null) {
      const extra = this.game.dice === 6;
      this.game.dice = null;
      if (!extra) this.game.currentPlayer = (this.game.currentPlayer + 1) % this.game.players.length;
      this.beginTurn(); return;
    }
    this.move(player.userId, tokenId, true);
  }

  scheduleBot(delay) {
    clearTimeout(this.botTimer);
    this.botTimer = setTimeout(() => {
      if (this.disposed || this.game.phase !== 'playing') return;
      const player = this.player;
      if (this.game.dice === null) { this.roll(player.userId); return; }
      const tokenId = chooseBotMove(this.game, player);
      if (tokenId !== null) this.move(player.userId, tokenId, true);
    }, delay);
  }

  setConnected(userId, connected, socket, disconnectedSocketId) {
    const player = this.playerFor(userId);
    if (!player) return false;
    if (!connected && disconnectedSocketId && player.socketId !== disconnectedSocketId) return false;
    player.connected = connected;
    if (connected) {
      clearTimeout(this.disconnectedTimers.get(userId)); this.disconnectedTimers.delete(userId);
      if (socket) { player.socketId = socket.id; socket.join(this.roomId); }
      if (!player.isBot) player.autoPlay = false;
      return true;
    }
    if (player.socketId) this.io.sockets.sockets.get(player.socketId)?.leave(this.roomId);
    player.micEnabled=false;
    this.io.to(`voice:${this.game.id}`).emit('mic_status_changed',{userId,enabled:false});
    this.io.to(`voice:${this.game.id}`).emit('voice_peer_left',{userId});
    player.socketId = null;
    if (!player.isBot) {
      const timer = setTimeout(() => {
        if (!player.connected && this.game.phase === 'playing') { player.autoPlay = true; this.broadcast('autoplay_enabled', { userId, reason: 'disconnected' }); if (this.player === player) this.scheduleBot(0); }
      }, 10000);
      this.disconnectedTimers.set(userId, timer);
    }
    return true;
  }

  rejoin(userId, socket) {
    if (!this.setConnected(userId, true, socket)) return false;
    socket.emit('sync_state', snapshot(this.game));
    return true;
  }

  playerBack(userId) {
    const player = this.playerFor(userId);
    if (!player || player.isBot) return false;
    player.autoPlay = false; player.afkCount = 0;
    clearTimeout(this.botTimer);
    this.broadcast('autoplay_disabled', { userId });
    if (this.player === player) {
      if (this.game.dice === null) this.beginTurn();
      else {
        clearTimeout(this.turnTimer);
        this.game.turnDeadline = Date.now() + this.turnSeconds * 1000;
        this.turnTimer = setTimeout(() => this.onTimeout(), this.turnSeconds * 1000);
        this.broadcast('turn_changed', { currentPlayer: this.game.currentPlayer, userId: player.userId, color: player.color, deadline: this.game.turnDeadline });
      }
    }
    return true;
  }

  leave(userId) {
    const player = this.playerFor(userId);
    if (!player || this.game.phase !== 'playing') return false;
    player.connected = false;
    player.autoPlay = true;
    player.micEnabled = false;
    const socket = player.socketId && this.io.sockets.sockets.get(player.socketId);
    socket?.leave(this.roomId);
    socket?.leave(`voice:${this.game.id}`);
    this.io.to(`voice:${this.game.id}`).emit('mic_status_changed',{userId,enabled:false});
    this.io.to(`voice:${this.game.id}`).emit('voice_peer_left',{userId});
    this.broadcast('autoplay_enabled', { userId, reason: 'player_left_match' });
    if (this.player === player) this.scheduleBot(0);
    return true;
  }

  dispose() {
    this.disposed = true; clearTimeout(this.turnTimer); clearTimeout(this.botTimer);
    for (const timer of this.disconnectedTimers.values()) clearTimeout(timer);
    this.disconnectedTimers.clear();
  }
}

module.exports = { GameRoom, BOT_AVATARS, BOT_NAMES };
