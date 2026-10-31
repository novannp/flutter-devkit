"""Fake DevKit chat peer for testing Chat on a single PC.

    python tool/chat_bot.py                 # echoes every message sent to it or to Everyone
    python tool/chat_bot.py --ping 20       # also messages you every 20 s (to test notifications)
    python tool/chat_bot.py --name "QA Bot"

Stdlib only. Speaks the same protocol as lib/modules/chat/chat_service.dart:
UDP broadcast beacons on 47232, newline-delimited JSON over TCP.
"""
import argparse
import json
import socket
import threading
import time
import uuid

BEACON_PORT = 47232
peers = {}  # id -> (ip, port, name)


def now_iso():
    return time.strftime('%Y-%m-%dT%H:%M:%S')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--name', default='Test Bot 🤖')
    ap.add_argument('--ping', type=int, default=0, help='send a direct message every N seconds')
    args = ap.parse_args()

    me = 'bot-' + uuid.uuid4().hex[:8]

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(('0.0.0.0', 0))
    server.listen()
    port = server.getsockname()[1]

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    udp.bind(('', BEACON_PORT))

    def beacon(kind='hello'):
        data = json.dumps({'app': 'ravo-devkit', 'type': kind, 'id': me, 'name': args.name,
                           'host': socket.gethostname(), 'port': port}).encode()
        for target in ('255.255.255.255', '<broadcast>'):
            try:
                udp.sendto(data, (target, BEACON_PORT))
            except OSError:
                pass

    def send(to_peer, conversation, text):
        ip, p, _ = peers[to_peer]
        msg = {'type': 'msg', 'id': f'{me}-{time.time_ns()}', 'from': me, 'fromName': args.name,
               'to': conversation, 'text': text, 'time': now_iso()}
        try:
            with socket.create_connection((ip, p), timeout=3) as s:
                s.sendall((json.dumps(msg) + '\n').encode())
        except OSError as e:
            print(f'  ! could not reach {ip}:{p}: {e}')

    def listen_udp():
        while True:
            data, (ip, _) = udp.recvfrom(4096)
            try:
                j = json.loads(data)
            except ValueError:
                continue
            if j.get('app') != 'ravo-devkit' or j.get('id') == me:
                continue
            if j['id'] not in peers:
                print(f'+ found {j.get("name")} ({ip}:{j.get("port")})')
                beacon()
            peers[j['id']] = (ip, j['port'], j.get('name', '?'))

    def handle(conn):
        with conn:
            for line in conn.makefile(encoding='utf-8'):
                j = json.loads(line)
                if j.get('type') != 'msg':
                    continue
                print(f'< {j["fromName"]} → {"Everyone" if j["to"] == "all" else "bot"}: {j["text"]}')
                if j['from'] in peers:
                    time.sleep(0.8)
                    reply_to = 'all' if j['to'] == 'all' else j['from']
                    send(j['from'], reply_to, f'Echo: {j["text"]}')

    def accept():
        while True:
            conn, _ = server.accept()
            threading.Thread(target=handle, args=(conn,), daemon=True).start()

    threading.Thread(target=listen_udp, daemon=True).start()
    threading.Thread(target=accept, daemon=True).start()
    print(f'{args.name} online (id {me}, port {port}). Ctrl+C to stop.')

    last_ping = time.time()
    try:
        while True:
            beacon()
            if args.ping and time.time() - last_ping >= args.ping:
                last_ping = time.time()
                for pid in list(peers):
                    send(pid, pid, f'Ping {time.strftime("%H:%M:%S")} — minimize DevKit to see the notification')
            time.sleep(4)
    except KeyboardInterrupt:
        beacon('bye')


if __name__ == '__main__':
    main()
