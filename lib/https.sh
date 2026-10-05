#!/usr/bin/env bash
# Config-preserving HTTPS transitions. Sourced after nx.sh's legacy functions.
# Python's tokenizer tracks source offsets so untouched directives remain byte-for-byte.
# Unsupported/ambiguous configurations fail before the transactional apply helper runs.

nx_https_transform() {
  command -v python3 >/dev/null 2>&1 || { error "保留配置的 HTTPS 操作需要 python3。" >&2; return 1; }
  local clean rc=0 http2_syntax
  http2_syntax="$(nginx_http2_syntax)"
  clean="$(mktemp)" || return 1
  nx_conf_query strip-access "$2" > "$clean" || { rm -f "$clean"; return 1; }
  NX_HTTP2_SYNTAX="$http2_syntax" NX_HTTPS_CLEAN_FILE="$clean" NX_HTTPS_CONF_DIR="${CONF_DIR:-}" python3 - "$@" <<'PY' || rc=$?
import re
import sys
import subprocess
import os
import ipaddress

operation, filename, domain, ssl_dir, requested, *preserve_sources = sys.argv[1:]

def fail(message):
    raise ValueError(message)

def port(value):
    if not re.fullmatch(r'[0-9]+', value) or not 1 <= int(value) <= 65535:
        fail('invalid port: ' + value)
    return str(int(value))

try:
    with open(filename, encoding='utf-8', newline='') as source:
        text = source.read()
    original_text = text
    # Access guards are derived from metadata and regenerated in the transaction.
    text = open(os.environ['NX_HTTPS_CLEAN_FILE'], encoding='utf-8', newline='').read()
    def parse_text(text):
        # Quotes, comments, escaped characters, and ${variables} cannot alter nesting.
        tokens = []
        metadata = {}
        depth = 0
        i = 0
        while i < len(text):
            if text[i].isspace():
                i += 1
                continue
            if text[i] == '#':
                end = text.find('\n', i)
                end = len(text) if end < 0 else end + 1
                line_start = text.rfind('\n', 0, i) + 1
                # Setters append metadata after server blocks. Only standalone
                # top-level comments count, never strings or comments in a block.
                if depth == 0 and not text[line_start:i].strip():
                    match = re.fullmatch(r'# ([A-Za-z_][A-Za-z_0-9]*)=([^\r\n]*)(?:\r?\n)?', text[i:end])
                    if match:
                        metadata.setdefault(match[1], []).append((line_start, end, match[2]))
                i = end
                continue
            start = i
            if text[i] in '{};':
                if text[i] == '{':
                    depth += 1
                elif text[i] == '}':
                    depth -= 1
                i += 1
            else:
                quote = None
                while i < len(text):
                    c = text[i]
                    if c == '\\':
                        i += 2
                        continue
                    if quote:
                        if c == quote:
                            quote = None
                        i += 1
                        continue
                    if c in '\"\'':
                        quote = c
                        i += 1
                        continue
                    if text.startswith('${', i):
                        end = text.find('}', i + 2)
                        if end < 0:
                            fail('unterminated variable')
                        i = end + 1
                        continue
                    if c.isspace() or c in '{};#':
                        break
                    i += 1
                if quote or i > len(text):
                    fail('unterminated quote/escape')
            tokens.append((text[start:i], start, i))

        cursor = 0
        def parse(nested=False):
            nonlocal cursor
            nodes = []
            while cursor < len(tokens):
                if tokens[cursor][0] == '}':
                    if not nested:
                        fail('unexpected closing brace')
                    closing = tokens[cursor][2]
                    cursor += 1
                    return nodes, closing
                args = []
                start = tokens[cursor][1]
                while cursor < len(tokens) and tokens[cursor][0] not in '{};':
                    args.append(tokens[cursor][0])
                    cursor += 1
                if not args or cursor >= len(tokens):
                    fail('incomplete directive')
                delimiter, opening, end = tokens[cursor]
                cursor += 1
                children = None
                if delimiter == '{':
                    children, end = parse(True)
                elif delimiter != ';':
                    fail('missing semicolon')
                nodes.append(dict(args=args, start=start, end=end, opening=opening, children=children))
            if nested:
                fail('unclosed block')
            return nodes, len(text)

        nodes, _ = parse()
        return nodes, metadata

    nodes, metadata = parse_text(text)
    servers = [n for n in nodes if n['args'] == ['server'] and n['children'] is not None]
    if not servers or any(n['args'][0] == 'include' for n in nodes):
        fail('expected explicit server blocks without top-level includes')
    def directives(node, name):
        return [n for n in node['children'] if n['args'][0] == name]
    def walk(node):
        for child in node['children'] or []:
            yield child
            yield from walk(child)
    def names(node):
        found = directives(node, 'server_name')
        if len(found) != 1:
            fail('expected one explicit server_name directive')
        result = []
        for token in found[0]['args'][1:]:
            if len(token) > 1 and token[0] == token[-1] and token[0] in '\"\'':
                token = token[1:-1]
            if any(c in token for c in '\\\"\'') or not re.fullmatch(r'[A-Za-z0-9_.-]+', token):
                fail('complex/escaped server_name is unsupported')
            result.append(token)
        return result
    def listener(node):
        args = node['args'][1:]
        if not args or node['children'] is not None:
            fail('invalid listen directive')
        address = args[0]
        match = re.fullmatch(r'(\[[0-9a-fA-F:.]+\]:|(?:[0-9.]+|\*):)?([0-9]+)', address)
        if not match:
            fail('unsupported listen address: ' + address)
        if any(a in ('quic', 'udp') or '$' in a for a in args):
            fail('unsupported listen option')
        return match[1] or '', port(match[2]), args[1:]
    def redirect(node):
        returns = directives(node, 'return')
        redirect_locations = [n for n in node['children'] if n['args'] == ['location', '/'] and n['children'] is not None]
        if not returns and len(redirect_locations) == 1:
            returns = directives(redirect_locations[0], 'return')
        if len(returns) != 1 or not re.fullmatch(r'https://\$host(?::[0-9]+)?\$request_uri', returns[0]['args'][-1]):
            return False
        if returns[0]['args'][1] not in ('301', '308'):
            return False
        for child in node['children']:
            if child in redirect_locations and child['children'] == returns:
                continue
            if child['args'][0] in ('listen', 'server_name', 'return') and child['children'] is None:
                continue
            if child['args'] != ['location', '^~', '/.well-known/acme-challenge/']:
                return False
            # Only the known generated ACME block can be removed with a redirect.
            if child['children'] is None or [n['args'] for n in child['children']] != [
                ['root', '/usr/share/nginx/html'], ['default_type', '"text/plain"'], ['try_files', '$uri', '=404']]:
                return False
        return all(listener(n)[1] == '80' and 'ssl' not in listener(n)[2] for n in directives(node, 'listen'))

    preserved = {}
    if preserve_sources:
        if operation != 'enable' or len(preserve_sources) != 1:
            fail('invalid TLS preservation request')
        old_text = open(preserve_sources[0], encoding='utf-8').read()
        old_nodes, _ = parse_text(old_text)
        old_apps = [n for n in old_nodes if n['args'] == ['server'] and n['children'] is not None
                    and any('ssl' in x['args'][2:] for x in directives(n, 'listen'))]
        if len(old_apps) != 1 or domain not in names(old_apps[0]):
            fail('expected one explicit original TLS application server')
        old_app = old_apps[0]
        if any(n['args'][0] == 'include' for n in walk(old_app)):
            fail('cannot preserve TLS hidden by includes')
        for key in ('ssl_certificate', 'ssl_certificate_key', 'ssl_protocols'):
            found = directives(old_app, key)
            if not found and key == 'ssl_protocols':
                continue
            if len(found) != 1 or found[0]['children'] is not None:
                fail('expected one original ' + key)
            preserved[key] = found[0]
        h2 = directives(old_app, 'http2')
        if len(h2) > 1 or any(n['args'][0] == 'http2' and n not in old_app['children'] for n in walk(old_app)):
            fail('ambiguous original HTTP/2 directives')
        if h2:
            if h2[0]['args'] not in (['http2', 'on'], ['http2', 'off']):
                fail('unsupported original HTTP/2 directive')
            preserved['http2'] = h2[0]
        # The very certificate we will publish must cover all candidate aliases.
        cert_token = preserved['ssl_certificate']['args'][1:]
        if len(cert_token) != 1:
            fail('ambiguous original certificate path')
        preserved_cert = cert_token[0].strip("\"'")
        if not os.path.isabs(preserved_cert) or '$' in preserved_cert or '\\' in preserved_cert:
            fail('unsupported original certificate path')

    if operation in ('challenge', 'challenge-probe'):
        selected = []
        for server in servers:
            if domain not in names(server):
                continue
            plain80 = [n for n in directives(server, 'listen') if listener(n)[1] == '80' and 'ssl' not in listener(n)[2]]
            if plain80:
                selected.append(server)
        if operation == 'challenge-probe':
            sys.stdout.write('yes' if selected else 'no')
            sys.exit(0)
        edits = []
        for server in selected:
            if any(n['args'][0] in ('rewrite', 'if') for n in server['children']):
                fail('server-level rewrite/if precedes HTTP-01; adjust routing manually')
            if any(n['args'][0] == 'include' for n in server['children']):
                fail('cannot safely modify challenge routing hidden by server includes')
            returns = directives(server, 'return')
            if returns:
                if not redirect(server):
                    fail('server-level return precedes HTTP-01; adjust custom redirect manually')
                node = returns[0]
                edits.append((node['start'], node['end'], 'location / { ' + text[node['start']:node['end']] + ' }'))
            challenge = [n for n in server['children'] if n['args'] == ['location', '^~', '/.well-known/acme-challenge/']]
            if challenge:
                expected = [['root', '/usr/share/nginx/html'], ['default_type', '"text/plain"'], ['try_files', '$uri', '=404']]
                if len(challenge) != 1 or challenge[0]['children'] is None or [n['args'] for n in challenge[0]['children']] != expected or any(n['children'] is not None for n in challenge[0]['children']):
                    fail('unknown challenge block requires manual review; business routing left unchanged')
            if not challenge:
                if any('/.well-known/acme-challenge' in ' '.join(n['args']) for n in server['children']):
                    fail('custom challenge location requires manual review')
                edits.append((server['opening'] + 1, server['opening'] + 1, '\n    location ^~ /.well-known/acme-challenge/ { root /usr/share/nginx/html; default_type "text/plain"; try_files $uri =404; }\n'))
        for start, end, replacement in sorted(edits, reverse=True):
            text = text[:start] + replacement + text[end:]
        sys.stdout.write(text)
        sys.exit(0)

    redirects = [s for s in servers if redirect(s)]
    apps = [s for s in servers if s not in redirects]
    if len(apps) != 1 or len(redirects) > 1:
        fail('expected one application server and at most one plain generated redirect')
    app = apps[0]
    aliases = names(app)
    if domain not in aliases:
        fail('requested domain is not an explicit server_name')
    if redirects and names(redirects[0]) != aliases:
        fail('redirect aliases differ from application server')
    if any(n['args'][0] == 'include' for n in walk(app)):
        fail('server includes may hide TLS/listen directives; inline them before changing HTTPS')
    listens = directives(app, 'listen')
    if not listens:
        fail('implicit listen is unsupported')
    parsed = [listener(n) for n in listens]
    if len({p[1] for p in parsed}) != 1 or len({'ssl' in p[2] for p in parsed}) != 1:
        fail('mixed listener ports or protocols are unsupported')
    tls = 'ssl' in parsed[0][2]
    if any((n['args'][0].startswith('ssl_') or n['args'][0] == 'http2') and n not in app['children'] for n in walk(app)):
        fail('nested TLS directives are unsupported')
    def meta(key):
        values = metadata.get(key, [])
        if len(values) > 1:
            fail('duplicate metadata: ' + key)
        return values[0][2] if values else ''
    h2 = directives(app, 'http2')
    if len(h2) > 1 or any(n['args'] not in (['http2', 'on'], ['http2', 'off']) for n in h2):
        fail('ambiguous HTTP/2 directives')
    modern_h2 = os.environ['NX_HTTP2_SYNTAX'] == 'directive'
    edits = []
    # Move explicit managed default selections together with application sockets.
    default_sockets = meta('access_default')
    def socket(address, number):
        host = address[:-1].strip('[]') if address else '0.0.0.0'
        host = str(ipaddress.ip_address('0.0.0.0' if host == '*' else host))
        return ('[' + host + ']' if ':' in host else host) + ':' + port(number)
    def remap_defaults(old_port, new_port, removing_redirect=False):
        if not default_sockets:
            return
        updated = []
        application_sockets = {socket(address, old_port): socket(address, new_port) for address, _, _ in parsed}
        remaining_sockets = set(application_sockets.values())
        removed_sockets = {socket(address, number) for node in redirects for address, number, _ in map(listener, directives(node, 'listen'))}
        # A removed redirect loses its selection unless the application returns
        # to that same socket; the latter can merge two selected defaults.
        for entry in default_sockets.split(','):
            host, number = entry.rsplit(':', 1)
            entry = socket(host + ':', number)
            entry = application_sockets.get(entry, entry)
            if removing_redirect and entry in removed_sockets and entry not in remaining_sockets:
                continue
            if entry not in updated:
                updated.append(entry)
        setmeta('access_default', ','.join(updated))
    def replace(node, value):
        edits.append((node['start'], node['end'], value))
    def setmeta(key, value):
        matches = metadata.get(key, [])
        if len(matches) > 1:
            fail('duplicate metadata: ' + key)
        replacement = '# ' + key + '=' + value + '\n' if value is not None else ''
        if matches:
            edits.append((matches[0][0], matches[0][1], replacement))
        elif replacement:
            edits.append((0, 0, replacement))
    def update_frontend(scheme, number):
        # Only exact destinations produced by our Emby templates are managed.
        if meta('managed_by') != 'Nginx-X' or meta('external_mode') not in ('emby_http', 'emby_https', 'emby_lily'):
            return
        sources = [meta('source_site_url') or meta('upstream_url')]
        streams = (meta('stream_upstream_urls') or meta('stream_upstream_url')).split('|')
        suffixes = {sources[0]: ''}
        suffixes.update({v: '/s' + str(i + 1) for i, v in enumerate(streams) if v})
        origin = scheme + '://' + domain + ('' if (scheme, number) in (('http', '80'), ('https', '443')) else ':' + number)
        for node in walk(app):
            args = node['args']
            if len(args) != 3 or args[0] not in ('proxy_redirect', 'sub_filter'):
                continue
            source, dest = (v.strip("\"'") for v in args[1:])
            if source not in suffixes:
                continue
            match = re.fullmatch(r'https?://' + re.escape(domain) + r'(?::[0-9]+)?(/s[0-9]+/?)?', dest)
            if not match:
                continue
            tail = match[1] or ''
            expected = {suffixes[source] + ('/' if args[0] == 'proxy_redirect' and suffixes[source] else '')}
            if source == sources[0]:
                expected.add('')
            if tail not in expected:
                continue
            value = origin + tail
            replace(node, args[0] + ' ' + args[1] + ' ' + ("'" + value + "'" if args[0] == 'sub_filter' else value) + ';')

    if operation == 'enable':
        # Refuse aliases not covered by the selected certificate; never silently
        # drop names or request additional certificates on the user's behalf.
        certfile = preserved_cert if preserved else ssl_dir.rstrip('/') + '/' + domain + '/fullchain.pem'
        for alias in aliases:
            if not re.fullmatch(r'[A-Za-z0-9.-]+', alias):
                fail('certificate coverage cannot be established for server_name: ' + alias)
            result = subprocess.run(['openssl', 'x509', '-in', certfile, '-noout', '-checkhost', alias], capture_output=True, text=True)
            if result.returncode or 'does match certificate' not in result.stdout:
                fail('certificate does not cover server_name ' + alias + '; install a certificate covering every alias first')
        if tls:
            if requested and port(requested) not in (parsed[0][1], '80' if parsed[0][1] == '443' else parsed[0][1]):
                fail('already enabled; disable HTTPS before changing its port')
            # Repair only known generated server-level redirects: these would
            # otherwise preempt HTTP-01 even when the challenge location exists.
            repaired = original_text
            for server in reversed(redirects):
                for node in reversed(directives(server, 'return')):
                    repaired = repaired[:node['start']] + 'location / { ' + text[node['start']:node['end']] + ' }' + repaired[node['end']:]
            if repaired != original_text and text != original_text:
                fail('repair challenge redirect separately before enabling HTTPS')
            # Only normalize known managed, uniform legacy TLS listeners.
            # Explicit on/off and custom configurations remain untouched.
            if modern_h2 and not h2 and meta('managed_by') == 'Nginx-X' and all('http2' in p[2] for p in parsed):
                if repaired != original_text or text != original_text:
                    fail('repair derived access/redirect configuration separately before HTTP/2 migration')
                for node, (address, number, options) in zip(listens, parsed):
                    replace(node, 'listen ' + ' '.join([address + number] + [o for o in options if o != 'http2']) + ';')
                edits.append((app['opening'] + 1, app['opening'] + 1, '\n    http2 on;\n'))
                for start, end, replacement in sorted(edits, reverse=True):
                    repaired = repaired[:start] + replacement + repaired[end:]
            sys.stdout.write(repaired)
            sys.exit(0)
        if redirects or any(n['args'][0].startswith('ssl_') or n['args'][0] in ('ssl', 'http2') for n in walk(app)):
            fail('existing TLS directives on a plain server are ambiguous')
        original = parsed[0][1]
        target = port(requested or meta('listen_port') or original)
        if target == '80':
            target = '443'
        preserved_h2 = preserved.get('http2')
        legacy_h2 = not modern_h2 and (preserved_h2 is None or preserved_h2['args'][1] == 'on')
        for node, (address, _, options) in zip(listens, parsed):
            replace(node, 'listen ' + ' '.join([address + target] + [o for o in options if o != 'http2'] + ['ssl'] + (['http2'] if legacy_h2 else [])) + ';')
        certpath = ssl_dir.rstrip('/') + '/' + domain
        if re.search(r'[\s;{}\"\'\\$#]', certpath):
            fail('unsupported characters in certificate path')
        certs = '\n    ssl_certificate     ' + certpath + '/fullchain.pem;\n    ssl_certificate_key ' + certpath + '/privkey.pem;\n    ssl_protocols TLSv1.2 TLSv1.3;\n'
        if preserved:
            # http2 is a syntax-bearing protocol switch, not a certificate
            # directive. Translate it across the 1.25.1 boundary rather than
            # copying a directive that the target Nginx cannot parse.
            preserved_certs = [n for key, n in preserved.items()
                               if key != 'http2' or modern_h2]
            certs = '\n    ' + '\n    '.join(old_text[n['start']:n['end']] for n in preserved_certs) + '\n'
        edits.append((app['opening'] + 1, app['opening'] + 1, certs))
        if modern_h2 and 'http2' not in preserved:
            edits.append((app['opening'] + 1, app['opening'] + 1, '\n    http2 on;\n'))
        # Retain exactly the existing listener families and bindings on redirect port 80.
        redirect_listens = []
        for address, _, options in parsed:
            redirect_listens.append('    listen ' + ' '.join([address + '80'] + [o for o in options if o != 'http2']) + ';')
        suffix = '' if target == '443' else ':' + target
        block = 'server {\n' + '\n'.join(redirect_listens) + '\n    server_name ' + ' '.join(aliases) + ';\n'
        block += '    location ^~ /.well-known/acme-challenge/ {\n        root /usr/share/nginx/html;\n        default_type "text/plain";\n        try_files $uri =404;\n    }\n'
        block += '    location / { return 301 https://$host' + suffix + '$request_uri; }\n}\n\n'
        # A certificate-only issuance may have installed a persistent challenge
        # helper. Keep that endpoint rather than generating a duplicate :80 name.
        helper = os.path.join((os.environ.get('NX_HTTPS_CONF_DIR') or os.path.dirname(filename)), 'acme-challenge-' + domain + '.conf')
        if os.path.exists(helper):
            # Accept only our exact persistent helper shape. A file name alone
            # says nothing about its hostname, listener, or challenge routing.
            if os.path.islink(helper):
                fail('existing ACME helper must not be a symlink')
            helper_text = open(helper, encoding='utf-8').read()
            helper_text = re.sub(r'(?ms)^\s*# nx-access-begin\n.*?^\s*# nx-access-end\n', '', helper_text)
            helper_text = re.sub(r' default_server # nx-access-default\n', '', helper_text)
            normalized = re.sub(r'\s+', ' ', re.sub(r'(?m)#.*$', '', helper_text)).strip()
            expected = ('server { listen 80; server_name ' + domain + '; '
                        'location ^~ /.well-known/acme-challenge/ { root /usr/share/nginx/html; '
                        'default_type "text/plain"; try_files $uri =404; } '
                        'location / { return 404; } }')
            if normalized != expected:
                fail('existing ACME helper is not the expected HTTP-01 endpoint; review it before enabling HTTPS')
        edits.append((app['start'], app['start'], block))
        update_frontend('https', target)
        remap_defaults(original, target)
        setmeta('https_original_listen_port', original)
        setmeta('https_enabled', 'true')
        setmeta('listen_port', target)
    elif operation == 'disable':
        if not tls:
            if redirects:
                fail('redirect beside a plain application server is ambiguous')
            sys.stdout.write(original_text)
            sys.exit(0)
        target = port(meta('https_original_listen_port') or meta('listen_port') or '80')
        for node, (address, _, options) in zip(listens, parsed):
            replace(node, 'listen ' + ' '.join([address + target] + [o for o in options if o not in ('ssl', 'http2')]) + ';')
        for node in app['children']:
            if node['args'][0].startswith('ssl_') or node['args'][0] in ('ssl', 'http2'):
                replace(node, '')
        for node in redirects:
            replace(node, '')
        update_frontend('http', target)
        remap_defaults(parsed[0][1], target, removing_redirect=True)
        setmeta('https_enabled', 'false')
        setmeta('listen_port', target)
        setmeta('https_original_listen_port', None)
    else:
        fail('unknown operation')
    for start, end, replacement in sorted(edits, key=lambda e: (e[0], e[1]), reverse=True):
        text = text[:start] + replacement + text[end:]
    sys.stdout.write(text)
except (ValueError, OSError, UnicodeError) as exc:
    print('HTTPS transformation refused: ' + str(exc), file=sys.stderr)
    sys.exit(1)
PY
  rm -f "$clean"
  return "$rc"
}

nx_https_apply() {
  local operation="$1" domain="$2" conf_file="$3" requested="${4:-}" tmp rc=0
  [[ -f "$conf_file" ]] || { error "配置文件不存在：${conf_file}"; return 1; }
  if [[ "$operation" == enable ]] && [[ ! -f "${SSL_DIR}/${domain}/fullchain.pem" || ! -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
    error "未找到证书文件：${SSL_DIR}/${domain}/"
    return 1
  fi
  tmp="$(mktemp /tmp/nginxx-https-preserve-XXXXXX)" || return 1
  if nx_https_transform "$operation" "$conf_file" "$domain" "$SSL_DIR" "$requested" > "$tmp"; then
    if ! cmp -s "$tmp" "$conf_file"; then
      apply_conf_with_rollback "$tmp" "$conf_file" || rc=$?
    fi
  else
    rc=$?
  fi
  rm -f "$tmp"
  if (( rc == 0 )); then
    info "HTTPS ${operation}：$(basename "$conf_file")（保留站点配置）"
  fi
  return "$rc"
}

enable_https_for_conf_file() {
  nx_https_apply enable "$1" "$2" "${3:-}"
}

disable_https_for_conf_file() {
  nx_https_apply disable "$1" "$2"
}
