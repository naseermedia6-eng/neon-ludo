# Neon Ludo

A dark luxury Ludo game with offline play, Socket.IO matchmaking, a local wallet, and persistent player profile.

## Run

Install the Flutter SDK and Android toolchain, then from this directory run:

```sh
flutter pub get
flutter run
```

The multiplayer client connects to `http://localhost:3000` by default. Override this with `--dart-define=SERVER_URL=https://your-server.example` for deployment. Android emulator users generally need `http://10.0.2.2:3000` to reach a server on the development computer.

The app opens at the lobby with Play Ludo, Voice Rooms, and Profile & Store tabs. Classic and Quick online matches support entry-fee queues, private six-digit rooms, pass and play, and bot matches. Wallet balances and player stats persist locally.

Online matches negotiate audio-only WebRTC mesh connections with Google public STUN servers. The Voice Rooms tab includes public and password-protected lounges, a host stage with eight guest seats, listener-only audio, live chat, and luxury gift celebrations. Home and Profile include a server-limited daily spin, seven-day check-in rewards, and player/gifter leaderboards. The local wallet and cooldown display are saved in shared preferences, while room state and leaderboard totals are held in memory on the server. Restrictive networks can still require a TURN relay.
