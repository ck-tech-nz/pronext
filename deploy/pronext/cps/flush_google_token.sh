#!/bin/bash

docker exec -i pronext python manage.py shell <<EOF
from pronext.calendar.options import flush_google_token
flush_google_token(all=True)
EOF
