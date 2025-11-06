Download
```
wget https://github.com/RafalKiszczyszyn/rb-log-viewer/raw/refs/heads/main/log_viewer.rb
```

Combine mode usage
```
ruby log_viewer.rb combine <source> <output>
source => glob pattern - must be wrapped in quotation marks
output => output filename - stores aggregated and indexed logs

# Example: Aggregate all logs from 2025/11/05
ruby log_viewer.rb combine 'log/us_app/*20251105.log' /tmp/my.log
```

Stream mode usage
```
ruby log_viewer.rb stream <combined_logfile> <after_timestamp> <before_timestamp>
combined_logfile => logfile built with combine mode
after_timestamp => include logs after this timestamp (inclusive)
before_timestamp => include logs before this timestamp (inclusive)

# Example: Show logs between two dates
ruby log_viewer.rb stream /tmp/my.log 2025-11-05T17:43:47 2025-11-05T17:43:48
# Example: Grep search on scoped logs
stream /tmp/my.log 2025-11-05T17:00:00 2025-11-05T18:00:00 | grep --text 'Started GET "/api/v1/milestones"'
```
