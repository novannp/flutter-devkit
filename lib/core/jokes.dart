import 'dart:math';

final _rand = Random();

T pick<T>(List<T> items) => items[_rand.nextInt(items.length)];

const breakLines = [
  'Break time 🎮 — the devices will still be here when you get back.',
  'Steam opened. If anyone asks, you\'re "testing performance on another platform".',
  'Rule #1 of QA: a rested tester finds more bugs. Go rest. 😌',
  'Loading break… 100%. Bugs paused (not really).',
  'The build will take 5 minutes anyway. Probably. 🎮',
  'Your devices said they need a break from you too. 📱💤',
];

const noBreakLines = [
  "Steam isn't installed… maybe get a coffee instead ☕",
  'No Steam found. Touch some grass instead 🌱',
  'No games installed. Respect. Coffee break then ☕',
];

const noDeviceLines = [
  'Nobody answered. They might be on a coffee break too ☕',
  'No devices found. Did someone take them home again? 🏠',
  "Zero devices. Either the Wi-Fi is shy or everyone's in a meeting.",
  'The network is quiet… too quiet. 👀',
];

const logoLines = [
  'You are now a developer! …oh wait, you already were 😎',
  'Achievement unlocked: Clicked the logo way too many times 🏆',
  'Stop poking me, I\'m working 😤',
  'Fun fact: this button does nothing. Except this. 🙃',
];

const konamiLine = '↑↑↓↓←→←→BA — +30 lives! The bugs are still there though 🐛';

/// Sidebar tagline: mostly normal, sometimes cheeky depending on the day.
String tagline([DateTime? at]) {
  final now = at ?? DateTime.now();
  if (now.weekday == DateTime.friday && now.hour >= 15) return 'No deploys today 🙏';
  if (now.hour >= 20 || now.hour < 5) return 'Go home, it\'s late 🌙';
  if (now.weekday == DateTime.monday && now.hour < 11) return 'Mondays, huh ☕';
  return pick(const [
    'Testing toolkit',
    'Testing toolkit',
    'Testing toolkit',
    'It works on my machine™',
    'Powered by coffee ☕',
    '99 bugs in the code…',
  ]);
}
