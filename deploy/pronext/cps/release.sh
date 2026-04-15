#!/bin/bash

case "$1" in
  unrelease) STATUS=0 ;;
  test)      STATUS=1 ;;
  release)   STATUS=2 ;;
  *)
    echo "Usage: $0 {unrelease|test|release}"
    exit 1
    ;;
esac

docker exec pronext python manage.py shell -c "
obj = PadApk.objects.last()
obj.status = $STATUS
obj.save()
print(f'Done: id={obj.id}, status={obj.status} ($1)')
"
