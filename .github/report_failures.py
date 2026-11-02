# Turns a `flutter test --file-reporter json:...` file into annotations, so failures show on the run's page.
import json
import sys

names = {}
errors = {}
for line in open(sys.argv[1], encoding='utf8'):
    for event in (lambda e: e if isinstance(e, list) else [e])(json.loads(line)):
        if event.get('type') == 'testStart':
            names[event['test']['id']] = event['test']['name']
        elif event.get('type') == 'error':
            errors.setdefault(event['testID'], event['error'])

for test, error in list(errors.items())[:10]:
    message = ' '.join(error.split())[:600].replace('%', '%25')
    print(f'::error title={names.get(test, "test").replace(",", ";").replace(":", ";")}::{message}')
