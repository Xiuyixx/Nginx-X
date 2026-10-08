#!/usr/bin/env bash
# Explicit, opt-in backend protection. No work occurs when this module is sourced.
# Initial scope: Linux + nftables + systemd; TCP, literal IPv4 loopback HTTP
# upstreams only. Protected site bytes are immutable until explicitly disabled.
# Guard must run after derived config writes, before nx_transaction reload/commit.
# nx_backend_uninstall_guard is a read-only veto, NOT a firewall uninstaller.

nx_backend_enable() {
  local file="${1:-}" policy
  [[ -n "$file" ]] || return 1
  [[ "$file" == /* ]] || file="${CONF_DIR:?}/$file"
  nx_access_assert_managed_site "$file" || return 1
  policy="$(nx_access_site_policy "$file")" || return 1
  [[ "$policy" == strict ]] || { printf 'backend: strict active site required\n' >&2; return 1; }
  # No noninteractive environment variable can substitute for explicit consent.
  confirm "保护后端会安装 nftables/systemd 规则；本站必须先解除保护才能修改。这将阻断所有共享后端端口使用者的非回环入站（IPv4/IPv6），保留本机 nginx 回环连接；确认启用？" || return 1
  _nx_backend_engine enable "$file" "$policy"
}
nx_backend_disable() {
  local file="${1:-}"
  [[ -n "$file" ]] || return 1
  [[ "$file" == /* ]] || file="${CONF_DIR:?}/$file"
  confirm "确认解除本站后端保护（其他站点共享端口仍受保护）？" || return 1
  _nx_backend_engine disable "$file"
}
nx_backend_status() {
  [[ -d "${NX_BACKEND_STATE_DIR:-/var/lib/nginxx/backend-protection}" ]] || { echo "已关闭（无保护状态）"; return 0; }
  _nx_backend_engine status "${1:-}"
}
nx_backend_guard_snapshot() {
  [[ -d "${NX_BACKEND_STATE_DIR:-/var/lib/nginxx/backend-protection}" ]] || return 0
  _nx_backend_engine guard "${1:?snapshot conf directory required}" "${2:-}"
}
nx_backend_uninstall_guard() {
  [[ -d "${NX_BACKEND_STATE_DIR:-/var/lib/nginxx/backend-protection}" ]] || return 0
  _nx_backend_engine uninstall
}

# The caller deliberately invokes this function inside its transaction subshell.
# shellcheck disable=SC2031
_nx_backend_engine() {
  # Paths are passed as data, never evaluated. Overrides are restricted inside
  # Python to a distinct network namespace (including read-only test fixtures).
  local held=0
  if [[ ${NX_IN_TRANSACTION:-0} == 1 && $EUID == 0 ]]; then held=1; fi
  if (( held )); then
    # shellcheck disable=SC2154 # descriptor dynamically scoped by nx_transaction
    _nx_backend_python "$@" --held "$held" 9<&"$lock_fd"
  else
    _nx_backend_python "$@" --held "$held"
  fi
}

_nx_backend_python() {
  ${SUDO:-} /usr/bin/python3 - "$@" --context \
    "${CONF_DIR:?}" "${NGINX_MAIN_CONF:-/etc/nginx/nginx.conf}" \
    "${NX_BACKEND_STATE_DIR:-/var/lib/nginxx/backend-protection}" \
    "${NX_BACKEND_SYSTEMD_DIR:-/etc/systemd/system}" \
    "${NX_BACKEND_TEST_ISOLATED:-0}" <<'PYBACKEND'
import contextlib, fcntl, hashlib, ipaddress, json, os, pathlib, re
import shutil, signal, socket, stat, subprocess, sys, tempfile, uuid

TABLE = 'nginxx_backend_guard'
UNIT = 'nginxx-backend-guard.service'
MARK = 'Nginx-X backend protection v1'
class Refused(Exception): pass
def need(ok, message):
    if not ok: raise Refused(message)
def run(args, data=None, check=True):
    p = subprocess.run(args, input=data, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, env={'PATH':'/usr/sbin:/usr/bin:/sbin:/bin','LC_ALL':'C'})
    if check: need(p.returncode == 0, 'command failed: ' + args[0] + ': ' + p.stderr.strip())
    return p

def trusted(path, directory=False, missing=False):
    """Reject symlink ancestors, group/world writes, aliases, and non-root owners."""
    path = pathlib.Path(path)
    need(path.is_absolute() and str(path) != '/', 'absolute non-root path required')
    for p in reversed([path, *path.parents][:-1]):
        if not p.exists() and not p.is_symlink():
            if missing: continue
            raise Refused('missing trusted path: ' + str(p))
        s = p.lstat()
        need(not stat.S_ISLNK(s.st_mode) and s.st_uid == 0 and not s.st_mode & 0o022,
             'unsafe ownership/mode/path: ' + str(p))
        if p != path or directory:
            need(stat.S_ISDIR(s.st_mode), 'not a directory: ' + str(p))
        else:
            need(stat.S_ISREG(s.st_mode) and s.st_nlink == 1, 'not an unaliased regular file: ' + str(p))
    return path

def binary(name):
    p = shutil.which(name, path='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin')
    need(p is not None, 'required command unavailable: ' + name)
    # Distribution bin/sbin symlinks are resolved; root ownership is checked.
    p = os.path.realpath(p); trusted(p)
    return p

def tokens(text):
    # Nginx lexical scanner: comments, quotes, escapes, braces and semicolons.
    # No line-based matching: inline and multi-line directives are real targets.
    result=[]; word=''; quote=None; escaped=False; comment=False
    for c in text:
        if comment:
            if c == '\n': comment=False
            continue
        if escaped:
            # Escaped directive/URL syntax is conservatively unsupported.
            word += '\\' + c; escaped=False; continue
        if c == '\\': escaped=True; continue
        if quote:
            if c == quote: quote=None
            else: word += c
            continue
        if c in ('"', "'"): quote=c; continue
        if c == '#':
            if word: result.append(word); word=''
            comment=True; continue
        if c.isspace() or c in '{};':
            if word: result.append(word); word=''
            if c in '{};': result.append(c)
        else: word += c
    need(not quote and not escaped, 'unterminated quote/escape in nginx config')
    if word: result.append(word)
    return result

def directives(text):
    buf=[]; depth=0; out=[]
    for t in tokens(text):
        if t == '{':
            need(bool(buf), 'empty block'); out.append((buf, '{')); buf=[]; depth+=1
        elif t == '}':
            need(not buf and depth > 0, 'unbalanced nginx block'); depth-=1
        elif t == ';':
            need(bool(buf), 'empty directive'); out.append((buf, ';')); buf=[]
        else: buf.append(t)
    need(not buf and depth == 0, 'incomplete nginx config')
    return out

def listens(text):
    ports=set()
    for d,end in directives(text):
        if d[0] != 'listen': continue
        need(end == ';' and len(d) >= 2, 'ambiguous listen')
        addr=d[1]
        # Unix sockets cannot collide with a TCP port.
        if addr.startswith('unix:'): continue
        m=re.fullmatch(r'(?:\[[0-9a-fA-F:]+\]:|(?:[0-9.]+|\*):)?([0-9]+)',addr)
        need(m is not None, 'unsupported listen address: ' + addr)
        if ':' in addr and not addr.startswith('*:'):
            host=addr.rsplit(':',1)[0].strip('[]'); ipaddress.ip_address(host)
        port=int(m[1]); need(1 <= port <= 65535, 'invalid listen port'); ports.add(port)
    return ports

def targets(text):
    ports=set(); servers=0
    for d,end in directives(text):
        if d[0] == 'server' and end == '{': servers+=1
        need(d[0] != 'include', 'site includes cannot be safely inspected')
        if d[0] != 'proxy_pass': continue
        need(end == ';' and len(d) == 2, 'ambiguous proxy_pass')
        m=re.fullmatch(r'http://127\.0\.0\.1:([0-9]+)(/[^\s$\\{};]*)?', d[1])
        need(m is not None, 'every actual proxy_pass must use literal http://127.0.0.1:port')
        p=int(m[1]); need(1 <= p <= 65535 and p != 22, 'invalid/SSH backend port'); ports.add(p)
    need(servers and ports, 'no server or actual proxy_pass found')
    # Strict must be materially rendered: inspect executable nginx tokens, not comments.
    ts=tokens(text); depth=0; server_depth=None; server_has_proxy=False; guards={}; names=[]
    for i,t in enumerate(ts):
        if t == '{':
            depth += 1
            if i and ts[i-1] == 'server':
                need(server_depth is None, 'nested server unsupported')
                server_depth=depth; server_has_proxy=False; guards={}; names=[]
        elif t == '}':
            if server_depth is not None and depth == server_depth:
                if server_has_proxy:
                    need(names and all(re.fullmatch(r'[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*\.?',n) for n in names), 'strict DNS names required')
                    pattern='|'.join(n.lower().rstrip('.').replace('.',r'\.') for n in names)
                    need(guards.get('$http_host') == '^('+pattern+r')\.?(:[0-9]+)?$)' and
                         guards.get('$host') == '^('+pattern+')$)',
                         'actual proxy server lacks exact canonical Host rejection guards')
                server_depth=None
            depth -= 1
        elif server_depth is not None and depth >= server_depth:
            if t == 'proxy_pass': server_has_proxy=True
            if t == 'server_name' and depth == server_depth:
                j=i+1
                while j<len(ts) and ts[j]!=';': names.append(ts[j]); j+=1
            if (depth == server_depth and t == 'if' and i+8 < len(ts) and ts[i+1] in ('($http_host','($host')
                    and ts[i+2] == '!~*' and ts[i+4] == '{' and
                    ts[i+5] == 'return' and ts[i+6] == '444' and ts[i+7] == ';' and ts[i+8] == '}'):
                # The lexical regexp token includes its closing ')'; require an anchored pattern.
                need(ts[i+3].startswith('^(') and ts[i+3].endswith('$)'),
                     'noncanonical Host guard')
                need(ts[i+1][1:] not in guards,'duplicate Host guard')
                guards[ts[i+1][1:]]=ts[i+3]
    need(server_depth is None, 'unbalanced server block')
    return sorted(ports)

def read_site(path, snapshot=False):
    if not snapshot: trusted(path)
    s=path.lstat()
    need(stat.S_ISREG(s.st_mode) and s.st_nlink == 1, 'site must be a regular unaliased file')
    return path.read_bytes()

def digest(data): return hashlib.sha256(data).hexdigest()

# Boot replay contains only standard-library code, data and an absolute nft
# binary. It neither sources nx/lib nor executes mutable repository content.
REPLAY = '''#!/usr/bin/python3
# Nginx-X backend protection v1 -- owned standalone boot replay
import fcntl,json,os,pathlib,stat,subprocess,sys
BASE=pathlib.Path(__file__).parent
TABLE='nginxx_backend_guard'
def safe(p):
 for x in [p,*p.parents][:-1]:
  s=x.lstat()
  if s.st_uid or s.st_mode & 0o022 or stat.S_ISLNK(s.st_mode): raise RuntimeError('unsafe replay path')
 for name in ('manifest.json','owner','lock','replay.py'):
  s=(BASE/name).lstat()
  if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1: raise RuntimeError('unsafe replay file')
def cmd(a,data=None):
 p=subprocess.run(a,input=data,text=True,capture_output=True)
 if p.returncode: raise RuntimeError(p.stderr)
 return p.stdout
safe(BASE/'manifest.json');safe(BASE/'owner');safe(BASE/'lock');safe(BASE/'replay.py')
with (BASE/'lock').open('r') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 m=json.loads((BASE/'manifest.json').read_text());owner=(BASE/'owner').read_text().strip()
 if m['owner']!=owner: raise RuntimeError('ownership mismatch')
 nft=m['nft'];safe(pathlib.Path(nft))
 q=subprocess.run([nft,'-j','list','tables'],text=True,capture_output=True)
 if q.returncode: raise RuntimeError(q.stderr)
 exists=any(x.get('table',{}).get('family')=='inet' and x.get('table',{}).get('name')==TABLE for x in json.loads(q.stdout)['nftables'])
 if exists:
  old=json.loads(cmd([nft,'-j','list','table','inet',TABLE]))
  if ('comment \"'+owner+'\"') not in cmd([nft,'list','table','inet',TABLE]): raise RuntimeError('foreign table')
 ports=sorted({p for s in m['sites'].values() for p in s['ports']})
 if any(type(p)!=int or p<1 or p>65535 or p==22 for p in ports): raise RuntimeError('invalid ports')
 batch=('delete table inet '+TABLE+'\\n') if exists else ''
 if ports:
  batch+='table inet '+TABLE+' {\\n comment "'+owner+'"\\n chain prerouting { type filter hook prerouting priority -110; policy accept;\\n'
  batch+=' iifname != "lo" fib daddr type local tcp dport { '+', '.join(map(str,ports))+' } drop\\n }\\n}\\n'
 if batch:
  cmd([nft,'-c','-f','-'],batch);cmd([nft,'-f','-'],batch)
'''

def atomic(path, data, mode=0o600):
    fd,tmp=tempfile.mkstemp(prefix='.new-',dir=str(path.parent))
    try:
        with os.fdopen(fd,'wb') as f:
            os.fchmod(f.fileno(),mode); f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(tmp,path)
        d=os.open(str(path.parent),os.O_RDONLY|os.O_DIRECTORY)
        try: os.fsync(d)
        finally: os.close(d)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def existing_table(nft, owner):
    tables=json.loads(run([nft,'-j','list','tables']).stdout)['nftables']
    exists=any(x.get('table',{}).get('family')=='inet' and x.get('table',{}).get('name')==TABLE for x in tables)
    if not exists: return None
    data=json.loads(run([nft,'-j','list','table','inet',TABLE]).stdout)['nftables']
    text=run([nft,'list','table','inet',TABLE]).stdout
    need(owner and re.search(r'^\s*comment "'+re.escape(owner)+r'"\s*$',text,re.M),
         'refusing foreign nft table (ownership marker mismatch)')
    return text

def live_matches(nft, manifest):
    data=json.loads(run([nft,'-j','list','table','inet',TABLE]).stdout)['nftables']
    chains=[x['chain'] for x in data if 'chain' in x]
    entries=[x['rule'] for x in data if 'rule' in x]
    ports=sorted({p for s in manifest['sites'].values() for p in s['ports']})
    if len(chains)!=1 or len(entries)!=1: return False
    c=chains[0]; r=entries[0]
    if (c.get('name'),c.get('type'),c.get('hook'),c.get('prio'),c.get('policy')) != ('prerouting','filter','prerouting',-110,'accept'): return False
    expr=r.get('expr',[])
    expected=[{'match':{'op':'!=','left':{'meta':{'key':'iifname'}},'right':'lo'}},
              {'match':{'op':'==','left':{'fib':{'result':'type','flags':['daddr']}},'right':'local'}},
              {'match':{'op':'==','left':{'payload':{'protocol':'tcp','field':'dport'}},'right':{'set':ports}}},
              {'drop':None}]
    # nft may collapse a one-element literal set to its scalar port.
    if len(ports)==1 and len(expr)==4 and expr[2].get('match',{}).get('right')==ports[0]:
        expected[2]['match']['right']=ports[0]
    return r.get('chain')=='prerouting' and expr==expected

def rules(manifest, exists):
    ports=sorted({p for s in manifest['sites'].values() for p in s['ports']})
    batch=('delete table inet '+TABLE+'\n') if exists else ''
    if ports:
        batch+='table inet '+TABLE+' {\n comment "'+manifest['owner']+'"\n'
        batch+=' chain prerouting { type filter hook prerouting priority -110; policy accept;\n'
        batch+=' iifname != "lo" fib daddr type local tcp dport { '+', '.join(map(str,ports))+' } drop\n }\n}\n'
    return batch

def sockets(ss, ports):
    rows=run([ss,'-H','-lntp']).stdout.splitlines()
    for port in ports:
        matched=[]; reachable=False
        for row in rows:
            fields=row.split(); need(len(fields)>=5, 'unrecognized ss output')
            endpoint=fields[3]
            try: p=int(endpoint.rsplit(':',1)[1])
            except (ValueError,IndexError): raise Refused('unrecognized ss endpoint')
            if p != port: continue
            matched.append(row)
            host=endpoint.rsplit(':',1)[0].strip('[]')
            if host in ('*','0.0.0.0','127.0.0.1','::',''): reachable=True
            owners=re.findall(r'\("([^"\n]+)",pid=(\d+),fd=(\d+)\)',row)
            need(owners, 'unknown socket ownership on port '+str(port))
            for name,pid,fd in owners:
                proc=pathlib.Path('/proc')/pid
                try:
                    exe=os.path.basename(os.readlink(proc/'exe'))
                    comm=(proc/'comm').read_text().strip()
                    link=os.readlink(proc/'fd'/fd)
                except OSError: raise Refused('socket process disappeared or is unverifiable')
                need(link.startswith('socket:['), 'ss FD is no longer a socket')
                inode=link.removeprefix('socket:[').removesuffix(']')
                actual=False
                for family in ('tcp','tcp6'):
                    for socketrow in (proc/'net'/family).read_text().splitlines()[1:]:
                        entry=socketrow.split()
                        if len(entry)>9 and entry[9]==inode and entry[3]=='0A':
                            actual=actual or int(entry[1].rsplit(':',1)[1],16)==port
                need(actual, 'ss process FD does not match the actual listening port')
                need(not any('nginx' in x.lower() or 'sshd' in x.lower() for x in (name,exe,comm)),
                     'refusing nginx/sshd backend socket')
                need(exe and '(deleted)' not in exe, 'unknown backend executable')
        need(matched, 'no verifiable TCP listener on port '+str(port)+'; Docker without a host-visible listener is intentionally unsupported')
        try:
            with socket.create_connection(('127.0.0.1',port),timeout=2): pass
        except OSError: raise Refused('backend is not reachable over IPv4 loopback on port '+str(port))

def manager_check(systemctl):
    need(pathlib.Path('/run/systemd/system').is_dir(), 'systemd is not running')
    for service in ('ufw.service','firewalld.service','netfilter-persistent.service','iptables.service','ip6tables.service'):
        p=run([systemctl,'is-active',service],check=False)
        need(p.returncode in (0,3,4), 'cannot determine firewall manager status')
        need(p.returncode != 0 and p.stdout.strip() in ('inactive','failed','unknown'),
             'active or ambiguous competing firewall manager: '+service)
    ufw=shutil.which('ufw',path='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin')
    if ufw:
        p=run([os.path.realpath(ufw),'status'],check=False)
        need(p.returncode==0 and re.search(r'^Status: inactive\s*$',p.stdout,re.M), 'ufw enabled or status unknown')
    # Reject foreign prerouting hooks on/preceding our priority: packet marking,
    # redirects, or an earlier drop make the proposed protection ambiguous.
    nft=binary('nft')
    data=json.loads(run([nft,'-j','list','ruleset']).stdout)['nftables']
    for x in data:
        c=x.get('chain',{})
        if c.get('hook')=='prerouting' and c.get('table') != TABLE:
            priority=c.get('prio')
            need(isinstance(priority,int), 'unknown prerouting hook priority')
            need(priority > -110 or c.get('type')=='filter' and priority == -300,
                 'foreign prerouting hook at/before protection priority')

args=sys.argv[1:]; split=args.index('--context'); action=args[0]
heldpos=args.index('--held'); held=args[heldpos+1]=='1'; operands=args[1:heldpos]
conf,main,statepath,unitdir,test=args[split+1:]
conf=pathlib.Path(conf); main=pathlib.Path(main); base=pathlib.Path(statepath); units=pathlib.Path(unitdir)
try:
    need(os.geteuid()==0,'root privileges required')
    need(action in ('enable','disable','status','guard','uninstall','checkpoint','restore'),'unknown backend action')
    overridden=(str(base)!='/var/lib/nginxx/backend-protection' or str(units)!='/etc/systemd/system')
    if overridden:
        need(test=='1' and os.stat('/proc/self/ns/net').st_ino != os.stat('/proc/1/ns/net').st_ino,
             'backend path overrides require an explicitly isolated network namespace')
        if action in ('enable','disable','restore'):
            need(os.stat('/proc/self/ns/mnt').st_ino != os.stat('/proc/1/ns/mnt').st_ino,
                 'mutating override tests also require an isolated mount namespace')
            for transport in ('/run/systemd/private','/run/dbus/system_bus_socket'):
                host='/proc/1/root'+transport
                if os.path.exists(transport) and os.path.exists(host):
                    need(os.stat(transport).st_ino != os.stat(host).st_ino or
                         os.stat(transport).st_dev != os.stat(host).st_dev,
                         'test systemctl transport still points to host systemd')
    trusted(conf,directory=True); trusted(base,directory=True,missing=True); trusted(units,directory=True)
    need(conf.resolve()==conf and base.resolve()==base and units.resolve()==units,'noncanonical directory')
    # Configuration directory first, firewall state directory second, every time.
    with contextlib.ExitStack() as stack:
        cfd=os.open(str(conf),os.O_RDONLY|os.O_DIRECTORY); stack.callback(os.close,cfd)
        # A transaction already owns this directory flock; taking it again in a
        # separate Python process would deadlock. Guard is called under that lock.
        if held:
            need(os.fstat(9).st_ino == os.fstat(cfd).st_ino and os.fstat(9).st_dev == os.fstat(cfd).st_dev, 'invalid inherited configuration lock')
            fcntl.flock(9,fcntl.LOCK_EX|fcntl.LOCK_NB)
        elif action != 'guard': fcntl.flock(cfd,fcntl.LOCK_EX)
        base_was_missing=not base.exists()
        if not base.exists():
            if action in ('status','guard','uninstall','disable'):
                print('backend protection: disabled'); sys.exit(0)
            base.mkdir(mode=0o700,parents=True); trusted(base,directory=True)
        need(base.stat().st_mode & 0o077 == 0,'backend state directory must be private (0700)')
        lock=base/'lock'
        if lock.is_symlink(): raise Refused('symlink firewall lock')
        if lock.exists(): trusted(lock)
        else:
            need(action in ('enable','checkpoint'), 'missing state lock; recover manually')
            fd=os.open(str(lock),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.close(fd)
        lfd=os.open(str(lock),os.O_RDONLY|os.O_NOFOLLOW); stack.callback(os.close,lfd); fcntl.flock(lfd,fcntl.LOCK_EX)
        ownerpath=base/'owner'; manifestpath=base/'manifest.json'; replay=base/'replay.py'; unit=units/UNIT
        known={'lock','owner','manifest.json','replay.py'}
        unknown={p.name for p in base.iterdir()}-known
        need(not unknown, 'pending backup/unknown state files; manual recovery required: '+str(unknown))
        owner=None; manifest=None
        need(not manifestpath.is_symlink(), 'symlink state manifest')
        if ownerpath.is_symlink(): raise Refused('symlink state owner')
        if ownerpath.exists():
            trusted(ownerpath); owner=ownerpath.read_text().strip()
            need(re.fullmatch(r'nx-backend-v1-[0-9a-f]{32}',owner),'invalid state owner')
            trusted(manifestpath); manifest=json.loads(manifestpath.read_text())
            need(manifest.get('version')==1 and manifest.get('owner')==owner and manifest.get('conf')==str(conf),
                 'state schema/config ownership mismatch')
            need(isinstance(manifest.get('sites'),dict),'invalid sites manifest')
            for path,s in manifest['sites'].items():
                need(pathlib.Path(path).parent==conf and path.endswith('.conf') and
                     re.fullmatch('[0-9a-f]{64}',s['sha256']) and s['ports'] and
                     all(type(p)==int and 1 <= p <= 65535 and p!=22 for p in s['ports']), 'invalid protected site record')
        else:
            need(not manifestpath.exists() and not replay.exists() and not unit.exists(), 'refusing unowned state/unit file')
        if unit.is_symlink(): raise Refused('symlink systemd unit')
        if unit.exists():
            trusted(unit); need(('# '+MARK+' '+str(owner)) in unit.read_text(),'refusing unowned systemd unit')
        if replay.is_symlink(): raise Refused('symlink replay script')
        if replay.exists(): trusted(replay); need(replay.read_text()==REPLAY,'replay script ownership/content mismatch')

        if action in ('checkpoint','restore'):
            need(held, 'combined recovery requires configuration transaction lock')
            backup=pathlib.Path(operands[0])
            # mktemp transaction backups intentionally live under sticky /tmp.
            # Validate the private leaf and its private transaction parent.
            for p in (backup,backup.parent):
                st=p.lstat(); need(stat.S_ISDIR(st.st_mode) and st.st_uid==0 and not st.st_mode & 0o077, 'unsafe combination backup')
            need(backup.parent.parent==pathlib.Path('/tmp') and backup.parent.name.startswith('nginxx-transaction-'), 'unexpected combination backup location')
            nft=binary('nft')
            if action=='checkpoint':
                own=(base/'owner').read_text().strip() if (base/'owner').exists() else None
                table=existing_table(nft,own)
                atomic(backup/'prior-table',(table or '').encode())
                atomic(backup/'absent',b'1' if base_was_missing else b'0')
                shutil.copytree(base,backup/'state',symlinks=False)
                if (units/UNIT).exists(): shutil.copy2(units/UNIT,backup/'unit')
                systemctl=binary('systemctl'); manager_check(systemctl)
                enabled=run([systemctl,'is-enabled',UNIT],check=False).stdout.strip()
                need(enabled in ('enabled','disabled','static','not-found',''), 'unknown unit enable state')
                atomic(backup/'enabled',enabled.encode())
            else:
                own=(base/'owner').read_text().strip() if (base/'owner').exists() else None
                table=existing_table(nft,own)
                batch=('delete table inet '+TABLE+'\n' if table else '')+(backup/'prior-table').read_text()
                if batch: run([nft,'-f','-'],batch)
                systemctl=binary('systemctl')
                for p in base.iterdir():
                    if p.name!='lock': p.unlink()
                for p in (backup/'state').iterdir():
                    st=p.lstat(); need(stat.S_ISREG(st.st_mode) and st.st_uid==0 and st.st_nlink==1 and not st.st_mode & 0o022, 'unsafe recovery file')
                    if p.name!='lock': atomic(base/p.name,p.read_bytes(),stat.S_IMODE(p.stat().st_mode))
                unit=units/UNIT
                # Undo newly added enable links while the owned unit still exists.
                if (backup/'enabled').read_text()!='enabled' and unit.exists():
                    run([systemctl,'disable',UNIT])
                if (backup/'unit').exists(): atomic(unit,(backup/'unit').read_bytes(),0o644)
                elif unit.exists(): unit.unlink()
                run([systemctl,'daemon-reload'])
                if (backup/'enabled').read_text()=='enabled': run([systemctl,'enable',UNIT])
                elif unit.exists() and (backup/'enabled').read_text()=='disabled': run([systemctl,'disable',UNIT])
                if (backup/'absent').read_bytes()==b'1':
                    lock.unlink(); base.rmdir()
            sys.exit(0)

        sites=manifest['sites'] if manifest else {}
        if action=='status':
            file=operands[0] if operands else ''
            if file and not file.startswith('/'): file=str(conf/file)
            selected={k:v for k,v in sites.items() if not file or k==file}
            for path,record in selected.items():
                need(digest(read_site(pathlib.Path(path)))==record['sha256'],'protected site bytes drifted')
                targets(read_site(pathlib.Path(path)).decode())
            print(json.dumps({'sites':selected,'persistence_installed':bool(owner)},sort_keys=True))
            if sites:
                nft=binary('nft'); need(existing_table(nft,owner) is not None and live_matches(nft,manifest),'protection state exists but live nft rules are absent/drifted')
            sys.exit(0)
        if action=='uninstall':
            need(not sites,'disable backend protection for all sites before uninstalling Nginx-X')
            print('backend uninstall guard: no protected references; standalone replay remains installed')
            sys.exit(0)
        if action=='guard':
            snap=pathlib.Path(operands[0]); need(snap.is_dir() and not snap.is_symlink(),'invalid snapshot directory')
            refreshed=json.loads(json.dumps(manifest)) if manifest else None
            for path,s in sites.items():
                p=pathlib.Path(path); before=read_site(snap/p.name, snapshot=True); after=read_site(p)
                combined=held and len(operands)>1 and operands[1]==path
                if combined and digest(after)!=s['sha256']:
                    # Only a locked in-place mutation whose starting bytes match
                    # the manifest may refresh its fingerprint. Keep the same
                    # literal proxy targets and materially strict server guards.
                    need(digest(before)==s['sha256'], 'protected site had pre-existing drift: '+path)
                    need(targets(before.decode())==targets(after.decode())==s['ports'],
                         'protected backend targets changed: '+path)
                    refreshed['sites'][path]['sha256']=digest(after)
                else:
                    need((before==after or combined) and digest(after)==s['sha256'], 'protected site changed/deleted/renamed/disabled: '+path)
            protected={p for s in sites.values() for p in s['ports']}
            if protected:
                nft=binary('nft')
                need(existing_table(nft,owner) is not None and live_matches(nft,manifest),'live backend protection missing/drifted; explicitly re-enable protection first')
                for p in conf.glob('*.conf'):
                    need(not p.is_symlink(),'ambiguous symlink frontend')
                    text=read_site(p).decode(); need(not listens(text)&protected,'frontend occupies protected backend port: '+str(p))
                # Expanded config also catches frontends outside CONF_DIR.
                dump=run([binary('nginx'),'-T','-c',str(main)]).stdout
                need(not listens(dump)&protected,'expanded nginx configuration collides with protected ports')
            if refreshed != manifest:
                atomic(manifestpath,(json.dumps(refreshed,sort_keys=True)+'\n').encode())
            sys.exit(0)
        need(not pathlib.Path('/run/ufw').is_dir(),'ufw runtime state present')
        nft=binary('nft'); systemctl=binary('systemctl'); manager_check(systemctl)
        oldtable=existing_table(nft,owner)
        newowner=owner or 'nx-backend-v1-'+uuid.uuid4().hex
        new=json.loads(json.dumps(manifest)) if manifest else {'version':1,'owner':newowner,'conf':str(conf),'nft':nft,'sites':{}}
        need(new['nft']==nft,'nft executable changed; explicit recovery required')
        file=pathlib.Path(operands[0]); need(file.parent==conf and file.name.endswith('.conf') and file.resolve()==file,
                                            'site must be an immediate canonical active .conf child')
        if action=='enable':
            need(operands[1]=='strict','strict consent check missing')
            text=read_site(file); ports=targets(text.decode())
            dump=run([binary('nginx'),'-T','-c',str(main)]).stdout
            # nginx -T names every actually loaded configuration file.
            need('# configuration file '+str(file)+':' in dump,'site is not loaded by nginx -T')
            need(not listens(dump)&set(ports),'backend port collides with actual nginx frontend')
            sockets(binary('ss'),ports)
            # No existing reference may drift while another is added.
            for path,s in sites.items(): need(digest(read_site(pathlib.Path(path)))==s['sha256'],'existing protected site has drifted')
            record={'ports':ports,'sha256':digest(text)}
            if (str(file) in sites and sites[str(file)] == record and oldtable is not None and live_matches(nft,manifest)):
                print('backend enable: '+str(file)+'; already enabled; ports='+str(ports))
                sys.exit(0)
            new['sites'][str(file)]=record
        else:
            # Unprotect also works after out-of-band deletion; never follows it.
            new['sites'].pop(str(file),None)
        batch=rules(new,oldtable is not None)
        if batch: run([nft,'-c','-f','-'],batch)
        need(not any(c.isspace() or c in '\\%"' for c in str(base)), 'unsupported systemd state path characters')
        unitbytes=('# '+MARK+' '+newowner+'\n[Unit]\nDescription=Nginx-X standalone backend protection\n'
                   'After=local-fs.target nftables.service\nBefore=nginx.service docker.service\n'
                   '[Service]\nType=oneshot\nExecStart=/usr/bin/python3 '+str(replay)+'\nRemainAfterExit=yes\n'
                   '[Install]\nWantedBy=multi-user.target\n').encode()
        paths=[ownerpath,manifestpath,replay,unit]
        backup=base/('backup-'+uuid.uuid4().hex); backup.mkdir(mode=0o700)
        previous={str(p):(p.read_bytes() if p.exists() else None) for p in paths}
        for i,p in enumerate(paths):
            if previous[str(p)] is not None: atomic(backup/str(i),previous[str(p)])
        atomic(backup/'table.nft',(oldtable or '').encode())
        enabled=run([systemctl,'is-enabled',UNIT],check=False)
        need(enabled.stdout.strip() in ('enabled','disabled','static','not-found',''), 'unsupported existing unit enable state')
        was_enabled=enabled.stdout.strip()=='enabled'
        def interrupted(signum,frame): raise Refused('interrupted; rolling back backend transaction')
        for sig in (signal.SIGHUP,signal.SIGINT,signal.SIGTERM): signal.signal(sig,interrupted)
        try:
            atomic(ownerpath,(newowner+'\n').encode())
            atomic(manifestpath,(json.dumps(new,sort_keys=True)+'\n').encode())
            atomic(replay,REPLAY.encode(),0o700); atomic(unit,unitbytes,0o644)
            run([systemctl,'daemon-reload']); run([systemctl,'enable',UNIT])
            if batch: run([nft,'-f','-'],batch)
            if new['sites']: need(live_matches(nft,new),'applied nft rules did not match desired protection')
        except BaseException as original:
            for sig in (signal.SIGHUP,signal.SIGINT,signal.SIGTERM): signal.signal(sig,signal.SIG_IGN)
            try:
                # Restoring only the dedicated owned table, never global rules.
                present=existing_table(nft,newowner)
                restore=('delete table inet '+TABLE+'\n' if present else '')+(oldtable or '')
                if restore: run([nft,'-f','-'],restore)
                if not was_enabled: run([systemctl,'disable',UNIT])
                for p in paths:
                    data=previous[str(p)]
                    if data is None:
                        if p.exists(): p.unlink()
                    else: atomic(p,data,0o700 if p==replay else 0o644 if p==unit else 0o600)
                run([systemctl,'daemon-reload'])
            except BaseException as recovery:
                raise Refused('rollback FAILED; backup retained at '+str(backup)+': '+str(recovery)) from original
            shutil.rmtree(backup)
            raise original
        shutil.rmtree(backup)
        print('backend '+action+': '+str(file)+'; ports='+str(sorted({p for s in new['sites'].values() for p in s['ports']})))
except (Refused,OSError,ValueError,KeyError,TypeError) as e:
    print('backend protection refused: '+str(e),file=sys.stderr); sys.exit(1)
PYBACKEND
}
