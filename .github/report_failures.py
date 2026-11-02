# Turns a `flutter test --file-reporter json:...` file into annotations, so failures show on the run's page.
import json
import sys

names = {}
errors = {}
prints = {}
for line in open(sys.argv[1], encoding='utf8'):
    for event in (lambda e: e if isinstance(e, list) else [e])(json.loads(line)):
        if event.get('type') == 'testStart':
            names[event['test']['id']] = event['test']['name']
        elif event.get('type') == 'error':
            errors.setdefault(event['testID'], event['error'])
        elif event.get('type') == 'print':
            prints[event['testID']] = prints.get(event['testID'], '') + event['message'] + ' '

for test, error in list(errors.items())[:10]:
    # Flutter's "Test failed" only points at the exception it printed just before.
    detail = prints.get(test, error) if error.startswith('Test failed') else error
    message = ' '.join(detail.split())[:4000].replace('%', '%25')
    print(f'::error title={names.get(test, "test").replace(",", ";").replace(":", ";")}::{message}')
