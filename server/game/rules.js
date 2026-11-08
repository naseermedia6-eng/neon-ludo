const OUTER_TRACK = [
  [6,1],[6,2],[6,3],[6,4],[6,5],[5,6],[4,6],[3,6],[2,6],[1,6],[0,6],[0,7],
  [0,8],[1,8],[2,8],[3,8],[4,8],[5,8],[6,9],[6,10],[6,11],[6,12],[6,13],[6,14],
  [7,14],[8,14],[8,13],[8,12],[8,11],[8,10],[8,9],[9,8],[10,8],[11,8],[12,8],[13,8],[14,8],[14,7],
  [14,6],[13,6],[12,6],[11,6],[10,6],[9,6],[8,5],[8,4],[8,3],[8,2],[8,1],[8,0],[7,0],[6,0],
].map(([r,c]) => r * 15 + c);
const START = { red: 0, green: 13, yellow: 26, blue: 39 };
const HOME = {
  red: [106,107,108,109,110,111],
  green: [22,37,52,67,82,97],
  yellow: [118,117,116,115,114,113],
  blue: [202,187,172,157,142,127],
};
const SAFE = new Set([0,8,13,21,26,34,39,47]);
const COLORS = { 2: ['red','yellow'], 4: ['red','green','yellow','blue'] };

function createPlayers(seats) {
  return seats.map(seat => ({
    userId: seat.userId,
    socketId: seat.socketId || null,
    name: seat.name,
    avatar: seat.avatar,
    color: seat.color,
    isBot: Boolean(seat.isBot),
    autoPlay: Boolean(seat.isBot),
    afkCount: 0,
    connected: true,
    captures: 0,
    micEnabled: false,
    tokens: Array.from({ length: 4 }, (_, id) => ({ id, progress: -1 })),
  }));
}

function legalMoves(game, player) {
  if (!player || !game.dice) return [];
  return player.tokens.filter(token => {
    if (token.progress === -1) return game.dice === 6;
    if (token.progress === 57 || token.progress + game.dice > 57) return false;
    if (game.mode === 'quick' && token.progress <= 51 && token.progress + game.dice > 51 && player.captures < 1) return false;
    return true;
  }).map(token => token.id);
}

function globalSquare(player, token) {
  return OUTER_TRACK[(START[player.color] + token.progress) % 52];
}

function applyMove(game, player, tokenId) {
  if (!Number.isInteger(tokenId) || tokenId < 0 || tokenId > 3) return { ok: false, reason: 'Invalid token id' };
  if (!legalMoves(game, player).includes(tokenId)) return { ok: false, reason: 'Illegal move' };
  const token = player.tokens[tokenId];
  const roll = game.dice;
  token.progress = token.progress === -1 ? 0 : token.progress + roll;
  const captured = [];
  if (token.progress <= 51) {
    const squareIndex = (START[player.color] + token.progress) % 52;
    if (!SAFE.has(squareIndex)) {
      const square = globalSquare(player, token);
      for (const enemy of game.players) {
        if (enemy === player) continue;
        for (const other of enemy.tokens) {
          if (other.progress >= 0 && other.progress <= 51 && globalSquare(enemy, other) === square) {
            other.progress = -1;
            player.captures += 1;
            captured.push({ userId: enemy.userId, tokenId: other.id });
          }
        }
      }
    }
  }
  const finished = token.progress === 57;
  const won = game.mode === 'quick' ? player.tokens.some(t => t.progress === 57) : player.tokens.every(t => t.progress === 57);
  game.dice = null;
  return { ok: true, tokenId, progress: token.progress, captured, finished, won, extraTurn: roll === 6 || captured.length > 0 || finished };
}

function chooseBotMove(game, player) {
  const ids = legalMoves(game, player);
  const score = id => {
    const token = player.tokens[id];
    if (token.progress === -1) return 30;
    const next = token.progress + game.dice;
    let value = next;
    if (next === 57) value += 1000;
    if (next <= 51) {
      const squareIndex = (START[player.color] + next) % 52;
      const square = OUTER_TRACK[squareIndex];
      if (!SAFE.has(squareIndex) && game.players.some(p => p !== player && p.tokens.some(t => t.progress >= 0 && t.progress <= 51 && globalSquare(p,t) === square))) value += 2000;
      if (SAFE.has(squareIndex)) value += 120;
    }
    if (game.mode === 'quick' && next > 51 && player.captures < 1) value -= 500;
    return value;
  };
  return ids.sort((a,b) => score(b)-score(a))[0] ?? null;
}

function snapshot(game) {
  return {
    matchId: game.id, mode: game.mode, playerCount: game.playerCount, entryFee: game.entryFee,
    players: game.players.map(p => ({ userId:p.userId, name:p.name, avatar:p.avatar, color:p.color, isBot:p.isBot, autoPlay:p.autoPlay, afkCount:p.afkCount, connected:p.connected, captures:p.captures, micEnabled:p.micEnabled, tokens:p.tokens.map(t => ({ id:t.id, progress:t.progress })) })),
    currentPlayer: game.currentPlayer, dice: game.dice, consecutiveSixes: game.consecutiveSixes,
    phase: game.phase, winnerId: game.winnerId, turnDeadline: game.turnDeadline,
  };
}

module.exports = { COLORS, HOME, OUTER_TRACK, SAFE, START, applyMove, chooseBotMove, createPlayers, legalMoves, snapshot };
