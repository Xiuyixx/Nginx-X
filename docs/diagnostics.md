# Diagnostics and optional host logs

Opening monitoring is read-only. It does not install a status server, change
logging, rotate logs, or reload nginx. Public/CDN probes and local socket probes
are shown separately. Local probes preserve Host/SNI using curl --resolve,
bypass environment proxies and verify TLS. A CDN origin-only CA will therefore
report certificate failure unless installed in curl's trust store. Local probes
do not follow redirects to avoid accidentally measuring another server.

To opt into per-site statistics, review these snippets and apply them with your
normal configuration backup, `nginx -t`, reload and rollback procedure. This is
an explicit manual option; nx never installs them silently. Use an http-context
log format (not inside a server):

```nginx
log_format nx_host_v1 'nx1 $host $body_bytes_sent $server_port $scheme $server_name';
```

Add this to each managed server whose traffic should be counted:

```nginx
access_log /var/log/nginx/access.host.log nx_host_v1;
```

If a location overrides access_log or turns it off, add the same log there to
include it. The viewer groups exact aliases and listener ports. Wildcard/regex
names are attributed through `$server_name`; configurations sharing the same
name and port cannot be distinguished. HTTP and HTTPS for a site are summed.
`NX_HOST_LOG` can select another file when sourcing nx. Legacy `host bytes`
logs remain supported, with an explicit warning that ports share counts.
Unknown/mixed formats and empty/missing logs show N/A; a valid log with no
matching requests shows zero. Only the latest 5000 lines are sampled, so these
are diagnostic figures, not billing totals.

Use the distribution's existing nginx logrotate rule if its path glob already
includes access.host.log (commonly `/var/log/nginx/*.log`). Do not add an
overlapping rule. Retain its configured owner/group and its existing nginx
reopen hook. nginx must reopen logs after rename (USR1 to the validated nginx
master, or the distribution's supplied reopen command); avoid copytruncate,
which can lose requests. Validate changes with `logrotate -d` before enabling;
for a custom path add it to the existing rule rather than creating duplicate
rotation ownership. The viewer reads only the current log after rotation.

Optional localhost status configuration (choose a free port; the current
viewer expects 8088):

```nginx
server {
    listen 127.0.0.1:8088;
    server_name 127.0.0.1;
    location = /nginx_status {
        stub_status;
        allow 127.0.0.1;
        deny all;
    }
    access_log off;
}
```

Check actual socket ownership first, then test/reload your configuration. The
viewer requires a successful response with the exact stub_status structure;
an existing filename or unrelated service on 8088 is not accepted as evidence.
Requests are bounded by a 1-second connection and 2-second total timeout.
Missing/invalid status and the first rate sample are N/A, not zero.
