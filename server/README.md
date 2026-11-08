# Neon Ludo multiplayer server

Lightweight Node.js 20+, Express, and Socket.IO server for authoritative Ludo matches. All queue, turn, token, and dice state is held in process memory; this is suitable for a single free-tier instance. Restarting the process clears live matches and queues. Deploy a single instance unless a shared Socket.IO adapter and shared game-state store are added.

## Run locally

```sh
npm install
npm start
```

Set `PORT` to change the listen port. Set `CLIENT_ORIGIN` to a comma-separated list of allowed browser origins in deployment; it defaults to `*` for local development. `GET /health` is available for hosting health checks.

## Socket.IO protocol

Connect with `auth: { userId }`. The identifier is used for room membership and reconnection; this standalone package has no account service and therefore does not authenticate ownership of that identifier. In production, validate the access token with your identity service in the Socket.IO middleware and derive `userId` from the verified token. Entry fees are matchmaking labels only; wallet debits, escrow, and payouts belong in a trusted economy service.

Client events:

- `queue_join` `{ mode, playerCount, entryFee, name, avatar }` — accepted values: `classic|quick`, `2|4`, and `500|2000|10000|50000`.
- `private_create` `{ mode, playerCount, entryFee, name, avatar }` and `private_join` `{ code, name, avatar }` create or join a six-digit private room.
- `quick_chat` `{ phrase }`, `emoji_reaction` `{ emoji }`, and `gift_send` `{ toUserId, giftId }` are validated against server-side presets and broadcast to the match. A gift broadcast contains its sender, recipient, catalog ID, display name, emoji, and coin price.
- `queue_leave`, `rejoin_match`, `roll_dice`, `move_token` `{ tokenId }`, `im_back`.
- `voice_join`, `voice_leave`, `webrtc_offer` / `webrtc_answer` `{ toUserId, description }`, `webrtc_ice_candidate` `{ toUserId, candidate }`, `mic_status_changed` `{ enabled }`.
- `create_voice_room` `{ title, category, isPrivate, password, name, avatar }`, `join_voice_room` `{ roomId, password, name, avatar }`, `leave_voice_room`, `take_mic_seat` `{ seatIndex }`, `release_mic_seat`, `lock_mic_seat` `{ seatIndex, locked }`, `kick_mic_seat` `{ targetUserId }`, `room_mic_status` `{ enabled }`, `send_room_chat` `{ text }`, and `send_luxury_gift` `{ targetUserId, giftId }`.
- `get_voice_rooms`, `get_leaderboard`, `daily_spin`, and `daily_checkin` support lounge discovery and virtual rewards. Room changes broadcast `voice_rooms_list` and `voice_room_state`; chat and gifts broadcast `voice_room_chat` and `room_luxury_gift`.

Mutating requests accept an optional Socket.IO acknowledgement callback and return `{ ok, ... }`. Match events include `queue_joined`, `match_found`, `turn_changed`, `dice_rolled`, `token_moved`, `turn_forfeited`, `player_timeout`, `autoplay_enabled`, `autoplay_disabled`, `sync_state`, and `game_over`. Match social events are `quick_chat_received`, `emoji_received`, and `gift_thrown`. Voice signaling is relayed only between members of the selected match or voice room. WebRTC media travels peer-to-peer; signaling requires this server, and networks that block direct connectivity can require a STUN/TURN service. Voice rooms, reward claims, and leaderboard scores are held in memory and reset when this process restarts.
