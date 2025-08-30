# Gunicorn configuration for capmapai.com production deployment
import os
import multiprocessing

# Application module and variable
wsgi_app = "application:application"

# Server socket - bind to localhost only (nginx will proxy)
bind = "0.0.0.0:5000"
backlog = 2048


# Worker processes - scale based on CPU cores
workers = min(4, (multiprocessing.cpu_count() * 2) + 1)
worker_class = "sync"
worker_connections = 1000
timeout = 60  # Increased for AI processing
keepalive = 2


# Restart workers after this many requests, to prevent memory leaks
max_requests = 1000
max_requests_jitter = 50

# Logging for production
accesslog = "-"  # Log to stdout
errorlog = "-"   # Log to stderr
loglevel = "info"
access_log_format = '%(h)s %(l)s %(u)s %(t)s "%(r)s" %(s)s %(b)s "%(f)s" "%(a)s" %(D)s'

# Process naming
proc_name = "capmap-backend"

# Security
limit_request_line = 4094
limit_request_fields = 100
limit_request_field_size = 8190

# Performance
preload_app = True
max_worker_memory = 200  # MB - restart worker if it exceeds this

# Graceful shutdown
graceful_timeout = 30
proc_name = 'wealt-backend'

# Daemonize the Gunicorn process (detach & run in background)
daemon = False  # Set to True if you want it to run as daemon

# User and group to run as (optional, for security)
# user = "www-data"
# group = "www-data"

# Preload application code before forking worker processes
preload_app = True

# Enable automatic worker restarts when code changes (only for development)
reload = False